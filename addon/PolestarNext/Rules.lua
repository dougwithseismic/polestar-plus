-- The tests a rule can ask about a moment, and AND / OR / NOT over them.
--
-- A condition is a table: { "and", c, c, ... }, { "or", c, ... },
-- { "not", c }, { "maybe", c }, or a test { name, argument, argument }.
-- Every test answers true, false or nil: nil is "the client will not say"
-- (a secret value in combat, a missing call). Unknown stays unknown through
-- AND, OR and NOT, and a rule whose condition is unknown does not fire;
-- { "maybe", c } reads an unknown as true where guessing yes is the better
-- mistake.
--
-- The moment is usually now. While the engine plans ahead (Rules.Ahead) it is
-- a few seconds from now, in a future where the plan's own earlier steps have
-- happened: their effects are on, their cooldowns running, their rage spent.
-- The tests about effects, cooldowns, rage and combat answer for that moment.

local _, ns = ...
local num, call, tri, fn = ns.num, ns.call, ns.tri, ns.fn

local Rules = { tests = {} }
ns.Rules = Rules
local tests = Rules.tests

-- The future being planned, or nil for now:
-- { ahead = seconds from now, effects = { ["target:rend"] = { ends, stacks } },
--   power = rage by then (nil when not known), combat = in a fight by then,
--   sim = { enemies, stance, form, dies, melee } when it is not this moment carried
--   forward but a fight on paper: an enemy targeted and in reach that starts
--   at full health and dies after `dies` seconds, nothing of the player's on
--   it yet, the player unhurt and standing still }
local plan

-- The fight on paper being planned, if that is what the plan is.
local function paper()
	return plan and plan.sim or nil
end

function Rules.Ahead(future)
	plan = future
end

local function clock()
	return GetTime() + (plan and plan.ahead or 0)
end

---------------------------------------------------------------------------
-- What the add-on has seen the player do: their casts, and from those the
-- global cooldown where the game does not report it.
---------------------------------------------------------------------------

local casts = {} -- lower-case spell name -> { at = GetTime(), guid = target then, count = casts in a row on it }
Rules.casts = casts

-- How long a run of casts on one target may pause and still be one run.
local RUN = 30
-- The pause between abilities, where the game does not say how long it is.
local GLOBAL = 1.5

local lastCast, lastGlobal = nil, GLOBAL

function Rules.SawCast(spellID)
	local id = ns.num(spellID)
	local name = ns.SpellNameOf(id)
	if not name then return end
	local guid = ns.str((call(UnitGUID, "target")))
	local before = casts[name:lower()]
	local count = 1
	if before and before.guid == guid and GetTime() - before.at < RUN then count = (before.count or 1) + 1 end
	casts[name:lower()] = { at = GetTime(), guid = guid, count = count }
	-- Abilities off the global cooldown do not start it.
	local _, pause = call(GetSpellBaseCooldown, id)
	if num(pause) ~= 0 then lastCast = GetTime() end
end

-- The global cooldown: the seconds of it left, and how long it runs. The
-- game's own answer where it gives one, else reckoned from the last cast.
function Rules.Global()
	local info = call(fn("C_Spell", "GetSpellCooldown"), 61304)
	local start, long = num(ns.field(info, "startTime")), num(ns.field(info, "duration"))
	if start and long then
		if long > 0 then
			lastGlobal = long
			return math.max(0, start + long - GetTime()), long
		end
		return 0, lastGlobal
	end
	if lastCast then return math.max(0, lastCast + GLOBAL - GetTime()), GLOBAL end
	return 0, GLOBAL
end

-- What holds the next press up right now: the seconds left of it, and how
-- long it runs in all. The global cooldown, or a cast in progress where that
-- has longer to go.
function Rules.Busy()
	local left, total = Rules.Global()
	local ok, casting, _, _, starts, ends = pcall(UnitCastingInfo or error, "player")
	starts, ends = ok and casting and num(starts) or nil, ok and casting and num(ends) or nil
	if starts and ends and ends > starts then
		local cast = ends / 1000 - GetTime()
		if cast > left then return cast, (ends - starts) / 1000 end
	end
	return left, total
end

-- The player's last cast of `name`, when it was on the current target (or
-- on themselves, for anything else).
local function castOn(unit, name)
	local cast = casts[name:lower()]
	if not cast then return nil end
	if unit == "target" and cast.guid then
		local guid = ns.str((call(UnitGUID, "target")))
		if guid and guid ~= cast.guid then return nil end
	end
	return cast
end

---------------------------------------------------------------------------
-- Rage, energy or mana, and how fast it is coming in: gains over the last
-- few seconds, so the plan can tell what there will be rage for.
---------------------------------------------------------------------------

local WINDOW = 8
local gains, lastPower = {}, nil
Rules.rate = 0

function Rules.SamplePower()
	local now, power = GetTime(), num((call(UnitPower, "player")))
	if not power then
		lastPower = nil
		return
	end
	if lastPower and power > lastPower then gains[#gains + 1] = { at = now, amount = power - lastPower } end
	lastPower = power
	local total, kept = 0, {}
	for _, gain in ipairs(gains) do
		if now - gain.at <= WINDOW then
			kept[#kept + 1] = gain
			total = total + gain.amount
		end
	end
	gains = kept
	Rules.rate = total / WINDOW
end

-- What the bar holds at the moment in question; nil when the game hides it.
local function powerNow()
	if plan then return plan.power end
	return num((call(UnitPower, "player")))
end

-- Forever hides the bar from add-ons in a fight. What it still says, ability
-- by ability, is whether there is enough for it, and that pins the bar down
-- from both sides: an ability costing 15 that can be used means at least 15;
-- one costing 20 that cannot, for want of rage, means under 20. `top` is the
-- dearest ability the character has: past it nothing can be proved.
local provedAt, atLeast, under, top = nil, 0, nil, 0

local function proved()
	local now = GetTime()
	if provedAt == now then return atLeast, under, top end
	provedAt, atLeast, under, top = now, 0, nil, 0
	for _, spell in pairs(ns.Scan.spells) do
		local cost = ns.Engine.Cost(spell.id)
		if cost and cost > 0 then
			if cost > top then top = cost end
			local s = ns.Engine.State({ spell.id, spell.name })
			if s.short == true then
				if not under or cost < under then under = cost end
			elseif s.usable == true and cost > atLeast then
				atLeast = cost
			end
		end
	end
	return atLeast, under, top
end

-- "The bar holds at least n" (op ">=") or "less than n" ("<"), from the bar
-- itself where the game shows it, else from what has been proved. Only for
-- the present: nothing is proved about a moment that has not come.
local function power(op, n)
	local known = powerNow()
	if known then
		if op == "<" then return known < n end
		return known >= n
	end
	if type(n) ~= "number" or (plan and not plan.present) then return nil end
	local low, high, dearest = proved()
	local enough -- true, false, or nil when it cannot be told
	if low >= n then
		enough = true
	elseif high and high <= n then
		enough = false
	elseif dearest > 0 and n > dearest and low >= dearest then
		-- Asked for more than anything costs, and everything is affordable:
		-- as much as can be told, there is enough.
		enough = true
	end
	if enough == nil then return nil end
	if op == "<" then return not enough end
	return enough
end

---------------------------------------------------------------------------
-- Effects: one way to ask about a buff or debuff, with how long it has left
-- and how many times it is stacked. Best source first:
--   1. while planning, what the plan has already put on;
--   2. the game's own record of it, with its timer and stacks;
--   3. where the game will not show it (its own restriction, in combat), the
--      player's last cast of it and how long the effect is known to last.
-- How long an effect lasts is learned from the game whenever it shows one,
-- else read from the spell's description, else the rule's own figure.
---------------------------------------------------------------------------

local durations = {} -- lower-case name -> seconds, as the game showed it
local described = {} -- lower-case name -> seconds from the description, or false
Rules.durations = durations

local function lasting(ref, name, fallback)
	local lower = name:lower()
	if durations[lower] then return durations[lower] end
	if described[lower] == nil then
		described[lower] = false
		local id = ns.Engine.State(ref).id
		local text = id and ns.str((call(fn("C_Spell", "GetSpellDescription"), id)))
		if text then
			local parsed = ns.Numbers.Parse(text)
			described[lower] = parsed.over or parsed.lasts or false
		end
	end
	return described[lower] or fallback
end

-- A new description may be along (a new rank): read them again.
function Rules.Forget()
	described = {}
end

-- Is the effect up at the moment in question, when does it end (seconds on
-- the game's clock, nil when not known), how many times is it stacked, and is
-- the end the game's own figure rather than an estimate?
local function effect(unit, ref, filter, lasts)
	local name = ns.SpellName(ref)
	if not name then return nil end
	local lower, now = name:lower(), clock()
	if plan then
		local put = plan.effects[unit .. ":" .. lower]
		if put then return put.ends > now, put.ends, put.stacks, put.sure end
		-- On paper the enemy is a new one: only what the plan put on it is there.
		if plan.sim and unit == "target" then return false end
	end

	local seen, stacks -- what the game says: true, false, or nil when it will not
	local find = fn("C_UnitAuras", "GetAuraDataBySpellName")
	if find then
		local ok, data = pcall(find, unit, name, filter)
		if ok and not ns.secret(data) then
			seen = data ~= nil
			if data then
				local ends, long = num(ns.field(data, "expirationTime")), num(ns.field(data, "duration"))
				stacks = num(ns.field(data, "applications"))
				if stacks then stacks = math.max(1, stacks) end
				if long and long > 0 then durations[lower] = long end
				if ends and ends > 0 then return ends > now, ends, stacks, true end
			end
		end
	elseif AuraUtil and AuraUtil.FindAuraByName then
		local ok, found = pcall(AuraUtil.FindAuraByName, name, unit, filter)
		if ok and not ns.secret(found) then seen = found ~= nil end
	end

	-- No timer from the game: the player's own cast gives one.
	local cast = castOn(unit, name)
	local long = lasting(ref, name, lasts)
	if cast and long and cast.at + long > GetTime() then
		return cast.at + long > now, cast.at + long, stacks or cast.count or 1, false
	end
	if seen == true then return true, nil, stacks, true end -- up, for all the game will say
	if seen == false then return false end
	-- The game will not say. Where the rule gives a duration to go by, not
	-- having cast it lately means it is not up; without one there is nothing
	-- to go by.
	if lasts then return false end
	return nil
end

-- For the panel: is the effect up now, when does it end, how many stacks,
-- and is that the game's own figure.
function Rules.Effect(unit, ref, lasts)
	return effect(unit, ref, unit == "player" and "HELPFUL" or "HARMFUL", lasts)
end

-- The rage, energy or mana there is now; nil when the game hides it.
function Rules.Power()
	return num((call(UnitPower, "player")))
end

-- What the game's own answers prove about a hidden bar: at least, under
-- (nil when nothing says), and the dearest ability there is to go by.
function Rules.Proved()
	return proved()
end

-- A damaging effect is put back in the last moment before it would drop,
-- rather than after: this close to its end it counts as already down.
local REFRESH = 1.0

-- What casting `ref` does to the effect it applies, in the future being
-- planned: puts it on (again) for its full time, one stack higher up to `cap`.
-- `delay` is the cast it takes to land. Returns what it put: { ends, stacks }.
function Rules.PutOn(unit, ref, lasts, cap, delay)
	local name = ns.SpellName(ref)
	if not (plan and name) then return end
	local up, _, stacks = effect(unit, ref, unit == "player" and "HELPFUL" or "HARMFUL", lasts)
	local long = lasting(ref, name, lasts) or 0
	local put = { ends = clock() + (delay or 0) + long, stacks = math.min(cap or 1, (up and stacks or 0) + 1), sure = false }
	plan.effects[unit .. ":" .. name:lower()] = put
	return put
end

-- An effect the plan's own step uses up (a paladin's seal, by Judgement):
-- gone from the moment reached.
function Rules.TakeOff(unit, ref)
	local name = ns.SpellName(ref)
	if not (plan and name) then return end
	plan.effects[unit .. ":" .. name:lower()] = { ends = clock(), stacks = 0, sure = false }
end

---------------------------------------------------------------------------
-- Numbers
---------------------------------------------------------------------------

local function percent(current, maximum)
	current, maximum = num(current), num(maximum)
	if not current or not maximum or maximum <= 0 then return nil end
	return current / maximum * 100
end

local function compare(value, op, n)
	if value == nil then return nil end
	if op == "<" then return value < n end
	return value >= n
end

local MANA = 0

-- What the game would not say while fighting, by test: kept with the scan
-- report, to see from outside what this client hides in combat.
Rules.hidden = {}
Rules.fighting = false

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

function tests.combat()
	if plan and plan.combat then return true end
	return tri(UnitAffectingCombat, "player")
end

-- Something alive that can be attacked is targeted.
function tests.target()
	if paper() then return true end
	local exists = tri(UnitExists, "target")
	if exists ~= true then return exists end
	local attackable, dead = tri(UnitCanAttack, "player", "target"), tri(UnitIsDeadOrGhost, "target")
	if attackable == false or dead == true then return false end
	if attackable == nil or dead == nil then return nil end
	return true
end

function tests.elite()
	if paper() then return false end
	local kind = ns.str((call(UnitClassification, "target")))
	if not kind then return nil end
	return kind == "elite" or kind == "rareelite" or kind == "worldboss"
end

function tests.buff(ref, lasts)
	return (effect("player", ref, "HELPFUL", lasts))
end

-- The player's own effect on the target, with time enough left on it that
-- it need not be put back yet.
function tests.debuff(ref, lasts)
	local up, ends = effect("target", ref, "HARMFUL|PLAYER", lasts)
	if up and ends and ends - clock() <= REFRESH then return false end
	return up
end

-- An effect of the player's own that comes in stacks or as a proc (Maelstrom
-- Weapon, Heating Up, Fingers of Frost): `n` or more of it. A proc cannot be
-- planned for: on paper there is none.
tests["charges>="] = function(ref, n)
	if paper() then return false end
	local up, _, stacks = effect("player", ref, "HELPFUL")
	if up == nil then return nil end
	if not up then return false end
	return (stacks or 1) >= (type(n) == "number" and n or 1)
end

-- The game is lighting the spell's button up: its own sign that a proc has
-- made the spell worth pressing. nil where the client has no such call.
function tests.lit(ref)
	if paper() then return false end
	local id = ns.Engine.State(ref).id
	local check = fn("C_SpellActivationOverlay", "IsSpellOverlayed") or IsSpellOverlayed
	if not id or type(check) ~= "function" then return nil end
	local ok, on = pcall(check, id)
	if not ok or ns.secret(on) then return nil end
	return on == true
end

-- A harmful effect on the player (a priest's Weakened Soul).
function tests.selfdebuff(ref, lasts)
	return (effect("player", ref, "HARMFUL", lasts))
end

-- The effect is stacked on the target fewer than `n` times (Sunder Armor
-- goes to five). The game's count where it shows one; else the run of casts
-- the add-on saw the player make on this target.
tests["stacks<"] = function(ref, n, lasts)
	if type(n) ~= "number" then return nil end
	local up, _, stacks = effect("target", ref, "HARMFUL", lasts or RUN)
	if up == nil then return nil end
	if not up then return true end
	return (stacks or 1) < n
end

-- The effect is on the target with less than `within` seconds left: time to
-- put it back before it fades. The game's own timer where it shows one; else
-- reckoned from the player's last cast, with a margin for the guesswork.
function tests.fading(ref, within, lasts)
	if type(within) ~= "number" then return nil end
	local up, ends, _, sure = effect("target", ref, "HARMFUL", lasts)
	if not (up and ends) then return false end
	return ends - clock() < within + (sure and 0 or 1.5)
end

---------------------------------------------------------------------------
-- Enemies in reach. An add-on cannot see the world, but it can ask about
-- every unit that has a nameplate up: this counts the ones that can be
-- attacked, are alive, and are close: in range of one of the class's melee
-- abilities where it has one, else on the player's threat list.
-- Needs enemy nameplates switched on in the game.
---------------------------------------------------------------------------

Rules.reach = {} -- spells whose range stands for "in reach", set with the rotation
Rules.mostEnemies = 0

local function close(unit)
	local check = fn("C_Spell", "IsSpellInRange")
	if check then
		for _, ref in ipairs(Rules.reach) do
			local id = ns.Engine.State(ref).id
			if id then
				local ok, v = pcall(check, id, unit)
				if ok and v ~= nil and not ns.secret(v) then return v == true or v == 1 end
			end
		end
	end
	if UnitThreatSituation then
		local ok, standing = pcall(UnitThreatSituation, "player", unit)
		if ok and not ns.secret(standing) then return standing ~= nil end
	end
	return tri(UnitAffectingCombat, unit) == true
end

-- The target is within reach of a melee swing: in range of one of the
-- class's melee abilities. nil when there is none to ask about.
function tests.melee()
	if paper() then return paper().melee ~= false end
	if tri(UnitExists, "target") ~= true then return nil end
	local check = fn("C_Spell", "IsSpellInRange")
	if not check then return nil end
	for _, ref in ipairs(Rules.reach) do
		local id = ns.Engine.State(ref).id
		if id then
			local ok, v = pcall(check, id, "target")
			if ok and v ~= nil and not ns.secret(v) then return v == true or v == 1 end
		end
	end
	return nil
end

local counted, countedAt = nil, nil

-- Nameplates are asked about by their unit names, "nameplate1" upwards: the
-- list of nameplate frames gave nothing on Forever 1.60.1.
local PLATES = 40
Rules.mostPlates = 0

-- How many enemies are in reach. Counted once a moment however many rules
-- ask. With no nameplates up a target still counts as one.
function Rules.Enemies()
	local now = GetTime()
	if countedAt == now then return counted end
	countedAt = now
	local n, plates = 0, 0
	for i = 1, PLATES do
		local unit = "nameplate" .. i
		if tri(UnitExists, unit) == true then
			plates = plates + 1
			if tri(UnitCanAttack, "player", unit) == true and tri(UnitIsDeadOrGhost, unit) ~= true and close(unit) then n = n + 1 end
		end
	end
	if n == 0 and tests.target() == true then n = 1 end
	counted = n
	if plates > Rules.mostPlates then Rules.mostPlates = plates end
	if n > Rules.mostEnemies then Rules.mostEnemies = n end
	return n
end

-- Forgets the count and what has been proved about the bar, for a new
-- moment within the same game tick (the tests).
function Rules.Recount()
	countedAt, provedAt = nil, nil
	ns.Engine.Fresh()
end

tests["enemies>="] = function(n)
	local count = paper() and (paper().enemies or 1) or Rules.Enemies()
	if count == nil or type(n) ~= "number" then return nil end
	return count >= n
end

-- Rage, energy, mana: whatever the class's bar is.
tests["power>="] = function(n) return power(">=", n) end
tests["power<"] = function(n) return power("<", n) end
-- Mana as a share of the bar. For a moment to come, the plan's own sum; for
-- now the bar itself; and where the game hides the bar, what its "usable"
-- answers prove: a spell costing 300 that can be cast means at least 300.
local function mana(op, n)
	if type(n) ~= "number" then return nil end
	if plan and plan.mana and plan.power and (plan.ceiling or 0) > 0 and not plan.present then
		return compare(plan.power / plan.ceiling * 100, op, n)
	end
	local share = percent((call(UnitPower, "player", MANA)), (call(UnitPowerMax, "player", MANA)))
	if share then return compare(share, op, n) end
	if (plan and not plan.present) or num((call(UnitPowerType, "player"))) ~= MANA then return nil end
	local most = num((call(UnitPowerMax, "player", MANA)))
	if not most or most <= 0 then return nil end
	local low, high = proved()
	local enough
	if low / most * 100 >= n then
		enough = true
	elseif high and high / most * 100 <= n then
		enough = false
	end
	if enough == nil then return nil end
	if op == "<" then return not enough end
	return enough
end
tests["mana%>="] = function(n) return mana(">=", n) end
tests["mana%<"] = function(n) return mana("<", n) end
-- Health as a percentage. On paper the player is unhurt, and the enemy goes
-- down steadily to die when the fight ends, so that what waits for a dying
-- target (Execute, a finisher) has its moment.
local function life(unit)
	local sim = paper()
	if sim then
		if unit == "target" and (sim.dies or 0) > 0 then return math.max(0, 100 * (1 - plan.ahead / sim.dies)) end
		return 100
	end
	return percent((call(UnitHealth, unit)), (call(UnitHealthMax, unit)))
end
tests["health%>="] = function(n) return compare(life("player"), ">=", n) end
tests["health%<"] = function(n) return compare(life("player"), "<", n) end
tests["target%>="] = function(n) return compare(life("target"), ">=", n) end
tests["target%<"] = function(n) return compare(life("target"), "<", n) end
tests["pet%<"] = function(n) return compare(percent((call(UnitHealth, "pet")), (call(UnitHealthMax, "pet"))), "<", n) end

tests["combo>="] = function(n)
	-- The plan counts its own builders and finishers.
	if plan and plan.combo ~= nil then return compare(plan.combo, ">=", n) end
	local points = num((call(GetComboPoints, "player", "target")))
	if points == nil then points = num((call(UnitPower, "player", 4))) end
	return compare(points, ">=", n)
end

function tests.stealth()
	return tri(IsStealthed)
end

-- The shapeshift form by the client's form number: 1 cat, 5 bear, 8 dire
-- bear, 31 moonkin; 0 for none.
function tests.form(id)
	-- On paper a druid is in the form the rotation is for.
	if paper() and paper().form then return paper().form == id end
	local ok, form = pcall(GetShapeshiftFormID or error)
	if not ok or ns.secret(form) then return nil end
	return (form or 0) == id
end

-- The stance or form by its place on the stance bar: a warrior's Battle 1,
-- Defensive 2, Berserker 3; 0 for none.
function tests.stance(n)
	-- On paper the character stands in the stance the rotation is for.
	if paper() and paper().stance then return paper().stance == n end
	local ok, index = pcall(GetShapeshiftForm or error)
	if not ok or ns.secret(index) then return nil end
	return (index or 0) == n
end

function tests.pet()
	local exists = tri(UnitExists, "pet")
	if exists ~= true then return exists end
	local dead = tri(UnitIsDeadOrGhost, "pet")
	if dead == nil then return nil end
	return not dead
end

function tests.moving()
	if paper() then return false end
	return compare(num((call(GetUnitSpeed, "player"))), ">=", 0.01)
end

-- A temporary enchant (a shaman's weapon imbue, a poison) on the main hand.
function tests.imbue()
	return tri(GetWeaponEnchantInfo)
end

-- The target is casting something that can be interrupted.
function tests.targetcasting()
	if paper() then return false end
	local ok, name, _, _, _, _, _, _, shielded = pcall(UnitCastingInfo or error, "target")
	if not ok or ns.secret(name) or ns.secret(shielded) then return nil end
	return name ~= nil and shielded ~= true
end

-- About a spell: whether the character has it, could use it now, has it off
-- cooldown at the moment in question, or has it switched on (an attack that
-- repeats, a strike queued for the next swing). The engine answers these.
function tests.known(ref) return ns.Engine.State(ref).known end
function tests.usable(ref)
	if paper() then return true end
	return ns.Engine.State(ref).usable
end
function tests.active(ref)
	if paper() then return false end
	return ns.Engine.State(ref).active
end
function tests.ready(ref)
	if plan then return ns.Engine.ReadyIn(ref, plan) <= plan.ahead + 0.05 end
	return ns.Engine.State(ref).ready
end

---------------------------------------------------------------------------
-- Conditions
---------------------------------------------------------------------------

-- true, false or nil for condition `c`; a missing condition is true.
function Rules.Check(c)
	if c == nil then return true end
	local op = c[1]
	if op == "and" then
		local unknown = false
		for i = 2, #c do
			local v = Rules.Check(c[i])
			if v == false then return false end
			if v == nil then unknown = true end
		end
		if unknown then return nil end
		return true
	elseif op == "or" then
		local unknown = false
		for i = 2, #c do
			local v = Rules.Check(c[i])
			if v == true then return true end
			if v == nil then unknown = true end
		end
		if unknown then return nil end
		return false
	elseif op == "not" then
		local v = Rules.Check(c[2])
		if v == nil then return nil end
		return not v
	elseif op == "maybe" then
		local v = Rules.Check(c[2])
		if v == nil then return true end
		return v
	end
	local test = tests[op]
	if not test then return nil end
	local answer = test(c[2], c[3], c[4])
	-- Counted for the present only: a plan asks the same thing many times over.
	if answer == nil and Rules.fighting and not plan then Rules.hidden[op] = (Rules.hidden[op] or 0) + 1 end
	return answer
end

-- What is wrong with condition `c` as data, or nil: the editor and the
-- tests check lists with this before they are used.
function Rules.Lint(c)
	if c == nil then return nil end
	if type(c) ~= "table" or type(c[1]) ~= "string" then return "a condition must be a table starting with a name" end
	local op = c[1]
	if op == "and" or op == "or" then
		if #c < 2 then return op .. " needs at least one condition" end
		for i = 2, #c do
			local bad = Rules.Lint(c[i])
			if bad then return bad end
		end
		return nil
	elseif op == "not" or op == "maybe" then
		if #c ~= 2 then return op .. " takes exactly one condition" end
		return Rules.Lint(c[2])
	end
	if not tests[op] then return "unknown test \"" .. op .. "\"" end
	return nil
end

-- The effects a rule's own spell puts on, read off its condition: a rule for
-- Rend that asks whether Rend is on the target is a rule that puts Rend on.
-- Each is { unit, lasts, cap }: who it lands on, the rule's figure for how
-- long it lasts, and how high it stacks.
local ON = { buff = "player", debuff = "target", selfdebuff = "player", ["stacks<"] = "target", fading = "target" }
function Rules.Applies(rule)
	local own = ns.SpellName(rule.spell)
	local found
	local function walk(c)
		if type(c) ~= "table" then return end
		local op = c[1]
		if op == "and" or op == "or" or op == "not" or op == "maybe" then
			for i = 2, #c do walk(c[i]) end
		elseif ON[op] and own and ns.SpellName(c[2]) == own then
			found = found or { unit = ON[op], cap = 1 }
			if op == "stacks<" then
				found.cap, found.lasts = math.max(found.cap, c[3] or 1), found.lasts or c[4]
			elseif op == "fading" then
				found.lasts = found.lasts or c[4]
			else
				found.lasts = found.lasts or c[3]
			end
		end
	end
	walk(rule.when)
	return found
end

-- A condition in words, for /pnext list and the tooltip.
function Rules.Describe(c)
	if c == nil then return "always" end
	local op = c[1]
	if op == "and" or op == "or" then
		local parts = {}
		for i = 2, #c do
			local part = Rules.Describe(c[i])
			local inner = c[i][1]
			if (inner == "and" or inner == "or") and inner ~= op then part = "(" .. part .. ")" end
			parts[#parts + 1] = part
		end
		return table.concat(parts, op == "and" and " and " or " or ")
	elseif op == "not" then
		return "not " .. Rules.Describe(c[2])
	elseif op == "maybe" then
		return Rules.Describe(c[2]) .. " (or unknown)"
	end
	local argument = c[2]
	if type(argument) == "table" then argument = ns.SpellName(argument) or "?" end
	if argument == nil then return op end
	-- A test about a spell with a number of its own: "Sunder Armor stacks<5".
	if type(c[2]) == "table" and type(c[3]) == "number" and op:find("[<>]") then return argument .. " " .. op .. c[3] end
	if op:find("[<>]") then return op .. argument end
	return op .. " " .. tostring(argument)
end
