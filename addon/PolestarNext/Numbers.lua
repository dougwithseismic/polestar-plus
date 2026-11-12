-- The game's own numbers for a spell, and the order they put the damage
-- abilities in.
--
-- For each spell the client is asked for its cost, cooldown and cast time,
-- and its description is read for the damage it says it does: "15 damage
-- over 9 sec", "38 to 44 Frost damage", "weapon damage plus 85", "increases
-- melee damage by 11". With the character's weapon damage that gives the
-- damage one use does, and from it:
--
--   damage per point of rage or energy   for classes that fight on those
--   damage per second spent casting      for classes that fight on mana
--
-- Rules marked `rank` in a class's list are then sorted by that figure, so
-- the order follows the character's real spells, ranks, talents and weapon
-- wherever the description reflects them. What this is not: a simulation.
-- Chance effects, resists and armour are not modelled, and a description in
-- a language other than English is not understood, in which case the
-- class's own order stands.

local _, ns = ...
local num, str, call, field, fn = ns.num, ns.str, ns.call, ns.field, ns.fn

local Numbers = {}
ns.Numbers = Numbers

-- Nothing is cast faster than this, so an instant costs this much time.
local GLOBAL = 1.5

local function number(text)
	return text and tonumber((text:gsub(",", ""))) or nil
end

-- What a description says a spell does:
--   direct     damage on use (the middle of a range)
--   dot, over  damage over time and its seconds
--   weapon     percent of weapon damage it deals (100 for "weapon damage")
--   plus       damage added to a weapon hit
--   onSwing    it rides the next swing instead of being a hit of its own
--   lasts      seconds an effect it applies stays ("Lasts 30 sec", "Lasts 2 min")
function Numbers.Parse(text)
	local out = {}
	if type(text) ~= "string" or text == "" then return out end
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("%s+", " ")
	local lower = text:lower()

	-- Damage over time first, and out of the way of the direct damage.
	local from, to, dot, over = lower:find("(%d[%d,]*) [%a ]-damage over (%d+) sec")
	if not from then
		from, to, dot, over = lower:find("(%d[%d,]*) [%a ]-damage every %d+ sec[%a .]- for (%d+) sec")
	end
	if from then
		out.dot, out.over = number(dot), number(over)
		lower = lower:sub(1, from - 1) .. lower:sub(to + 1)
	end

	-- Rage or energy an ability gives at once ("Generates 10 rage at the cost of health...").
	out.gain = number(lower:match("generat%a* (%d+) rage") or lower:match("generat%a* (%d+) energy") or lower:match("restor%a* (%d+) energy")
		or lower:match("into (%d[%d,]*) mana"))

	local seconds, minutes = lower:match("lasts (%d+) sec"), lower:match("lasts (%d+) min")
	if seconds then out.lasts = number(seconds) elseif minutes then out.lasts = number(minutes) * 60 end

	if lower:find("weapon damage") then
		out.weapon = number(lower:match("(%d+)%% [%a ]-weapon damage")) or 100
		out.plus = number(lower:match("weapon damage plus (%d[%d,]*)")) or number(lower:match("plus (%d[%d,]*)"))
	end
	local added = lower:match("increases [%a ]-damage by (%d[%d,]*)") or lower:match("damage increased by (%d[%d,]*)")
	if added and (lower:find("next melee") or lower:find("next attack") or lower:find("strong attack") or lower:find("next swing")) then
		out.onSwing, out.plus = true, number(added)
	end

	if not out.weapon and not out.onSwing then
		local low, high = lower:match("(%d[%d,]*) to (%d[%d,]*) [%a ]-damage")
		if low then
			out.direct = (number(low) + number(high)) / 2
		else
			out.direct = number(lower:match("(%d[%d,]*) [%a ]-damage"))
		end
	end
	return out
end

local function description(id)
	local text = str((call(fn("C_Spell", "GetSpellDescription"), id)))
	if text then return text end
	-- Not loaded yet: ask, and the next rebuild will have it.
	call(fn("C_Spell", "RequestLoadSpellData"), id)
	return nil
end

local function cost(id)
	local costs = ns.plain((call(fn("C_Spell", "GetSpellPowerCost"), id)))
	if type(costs) ~= "table" then return nil end
	for _, entry in ipairs(costs) do
		local amount = num(field(entry, "cost")) or num(field(entry, "minCost"))
		if amount and amount > 0 then return amount, num(field(entry, "type")) end
	end
	return 0
end

local function castTime(id)
	local info = C_Spell and call(C_Spell.GetSpellInfo, id)
	local ms = num(field(info, "castTime"))
	if ms == nil then
		local _, _, _, old = call(GetSpellInfo, id)
		ms = num(old)
	end
	return ms and ms / 1000 or nil
end

-- The middle of the main hand's damage range, as the character sheet shows it.
local function weaponDamage()
	local low, high = call(UnitDamage, "player")
	low, high = num(low), num(high)
	if not (low and high) then return nil end
	return (low + high) / 2
end

-- The numbers for the spell a rule names, or nil when the character does not
-- have it or the client gives nothing to go by.
function Numbers.Of(ref)
	local state = ns.Engine.State(ref)
	local id = state.known and state.id
	if not id then return nil end
	local parsed = Numbers.Parse(description(id))
	local n = { id = id, cast = castTime(id) or 0 }
	n.cost, n.costType = cost(id)
	local base = num((call(GetSpellBaseCooldown, id)))
	n.cooldown = base and base / 1000 or 0

	local hit
	if parsed.onSwing then
		-- Only what it adds counts: the swing would have happened anyway.
		hit = parsed.plus
	elseif parsed.weapon then
		local weapon = weaponDamage()
		hit = weapon and (weapon * parsed.weapon / 100 + (parsed.plus or 0)) or nil
	else
		hit = parsed.direct
	end
	n.onSwing, n.hit, n.dot, n.over = parsed.onSwing or false, hit, parsed.dot, parsed.over
	if not hit and not parsed.dot then return n end

	n.damage = (hit or 0) + (parsed.dot or 0)
	n.perSecond = n.damage / math.max(n.cast, GLOBAL)
	if n.cost and n.cost > 0 then n.perCost = n.damage / n.cost end
	return n
end

-- The figure a class fights by: damage per second for mana, damage per
-- point for rage and energy. A free ability is worth its whole damage.
local MANA = 0
function Numbers.Score(n, powerType)
	if not (n and n.damage) then return nil end
	if powerType == MANA then return n.perSecond end
	return n.perCost or n.damage
end

function Numbers.Text(n, powerType)
	if not (n and n.damage) then return nil end
	local parts = { ("%.0f damage"):format(n.damage) }
	if n.dot and n.over then parts[#parts + 1] = ("%.0f of it over %ds"):format(n.dot, n.over) end
	if powerType == MANA then
		parts[#parts + 1] = ("%.0f a second"):format(n.perSecond)
		if n.perCost then parts[#parts + 1] = ("%.1f per mana"):format(n.perCost) end
	elseif n.perCost then
		parts[#parts + 1] = ("%.1f per point"):format(n.perCost)
	end
	return table.concat(parts, ", ")
end

-- Sorts each run of consecutive `rank` rules in `list` by score, best first.
-- A rule whose numbers could not be read keeps its place, and so does a run
-- with fewer than two readable rules. Each ranked rule gets `figures`, its
-- numbers in words. Returns how many rules were given a number and how many
-- wanted one.
function Numbers.Order(list)
	local powerType = num((call(UnitPowerType, "player"))) or MANA
	local scored, wanted = 0, 0
	local i = 1
	while i <= #list do
		if list[i].rank then
			local j = i
			while j < #list and list[j + 1].rank do j = j + 1 end
			-- Slots i..j: the readable rules are sorted among the slots they hold.
			local slots, rules = {}, {}
			for k = i, j do
				-- A spell the character does not have wants no number.
				if ns.Engine.State(list[k].spell).known then wanted = wanted + 1 end
				local n = Numbers.Of(list[k].spell)
				local score = Numbers.Score(n, powerType)
				list[k].figures = Numbers.Text(n, powerType)
				if score then
					scored = scored + 1
					slots[#slots + 1] = k
					rules[#rules + 1] = { rule = list[k], score = score, at = k }
				end
			end
			if #rules >= 2 then
				table.sort(rules, function(a, b)
					if a.score ~= b.score then return a.score > b.score end
					return a.at < b.at
				end)
				for s, k in ipairs(slots) do list[k] = rules[s].rule end
			end
			i = j + 1
		else
			i = i + 1
		end
	end
	return scored, wanted
end
