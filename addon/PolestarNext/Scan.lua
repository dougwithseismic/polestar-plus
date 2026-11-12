-- What the character has: class and level, spellbook, action bars and the
-- keys bound to them, talents, and gear. Read on login and whenever one of
-- them changes; everything else works from this.

local _, ns = ...
local plain, num, str, call, field, fn = ns.plain, ns.num, ns.str, ns.call, ns.field, ns.fn

local Scan = {
	class = nil, -- "WARRIOR"
	level = 1,
	spells = {}, -- lower-case name -> { id = highest known rank, name, passive }
	bars = {}, -- lower-case name -> { slot, id, name, key, button }
	talents = {}, -- lower-case name or spell ID -> ranks taken
	points = { 0, 0, 0 }, -- points in each of the class's three trees
	spec = nil, -- 1..3: the tree with the most points, nil before any
	stance = 0, -- the stance or form's place on its bar (a warrior's 1, 2, 3), 0 for none
	stances = {}, -- place on the bar -> the stance or form's name
	form = 0, -- the client's form number (1 cat, 5 bear, ...), 0 for none
	gear = {},
	problems = {}, -- what could not be read, for /pnext scan
}
ns.Scan = Scan

local function problem(text)
	Scan.problems[#Scan.problems + 1] = text
end

---------------------------------------------------------------------------
-- Spellbook
---------------------------------------------------------------------------

local function addSpell(id, passive)
	local name = ns.SpellNameOf(id)
	if not name then return end
	-- Ranks are listed lowest first, so the last one seen is the highest.
	Scan.spells[name:lower()] = { id = id, name = name, passive = passive or false }
end

local function scanSpells()
	ns.wipe(Scan.spells)
	local B = C_SpellBook
	if B and B.GetNumSpellBookSkillLines and B.GetSpellBookSkillLineInfo and B.GetSpellBookItemInfo then
		local types = Enum and Enum.SpellBookItemType
		local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
		for line = 1, num((call(B.GetNumSpellBookSkillLines))) or 0 do
			local info = call(B.GetSpellBookSkillLineInfo, line)
			local offset, count = num(field(info, "itemIndexOffset")), num(field(info, "numSpellBookItems"))
			if offset and count and field(info, "isGuild") ~= true then
				for index = offset + 1, offset + count do
					local item = call(B.GetSpellBookItemInfo, index, bank)
					local kind = field(item, "itemType")
					local id = num(field(item, "spellID")) or num(field(item, "actionID"))
					-- Not yet learned, and menus of spells, are not spells to use.
					local skip = types and (kind == types.FutureSpell or kind == types.Flyout or kind == types.PetAction)
					if id and not skip then addSpell(id, field(item, "isPassive") == true) end
				end
			end
		end
	elseif GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo then
		for tab = 1, num((call(GetNumSpellTabs))) or 0 do
			local _, _, offset, count = call(GetSpellTabInfo, tab)
			offset, count = num(offset), num(count)
			for index = (offset or 0) + 1, (offset or 0) + (count or 0) do
				local kind, id = call(GetSpellBookItemInfo, index, "spell")
				if str(kind) == "SPELL" and num(id) then addSpell(id) end
			end
		end
	else
		problem("the spellbook could not be read")
	end
end

-- Whether the character has the spell: in the spellbook by name, or known
-- by ID where the spellbook does not list it (the Attack every class has).
function Scan.Knows(ref)
	local name = ns.SpellName(ref)
	if name and (Scan.spells[name:lower()] or Scan.bars[name:lower()]) then return true end
	local id = type(ref) == "table" and ref[1] or (type(ref) == "number" and ref) or nil
	if not id then return false end
	return ns.tri(IsPlayerSpell, id) == true or ns.tri(fn("C_SpellBook", "IsSpellKnown"), id) == true
end

---------------------------------------------------------------------------
-- Action bars and their keys
---------------------------------------------------------------------------

-- The client's button frames, and the binding each bar's buttons answer to.
local BARS = {
	{ "ActionButton", "ACTIONBUTTON" },
	{ "MultiBarBottomLeftButton", "MULTIACTIONBAR1BUTTON" },
	{ "MultiBarBottomRightButton", "MULTIACTIONBAR2BUTTON" },
	{ "MultiBarRightButton", "MULTIACTIONBAR3BUTTON" },
	{ "MultiBarLeftButton", "MULTIACTIONBAR4BUTTON" },
	{ "MultiBar5Button", "MULTIACTIONBAR5BUTTON" },
	{ "MultiBar6Button", "MULTIACTIONBAR6BUTTON" },
	{ "MultiBar7Button", "MULTIACTIONBAR7BUTTON" },
}

-- The slot the main bar's button n shows: its page, or the stance's or
-- form's own bar while on page one.
local function mainSlot(n)
	local page = num((call(fn("C_ActionBar", "GetActionBarPage")))) or 1
	local bonus = num((call(fn("C_ActionBar", "GetBonusBarOffset")))) or 0
	if page == 1 and bonus > 0 then return (5 + bonus) * 12 + n end
	return (page - 1) * 12 + n
end

local function scanBars()
	ns.wipe(Scan.bars)
	for _, bar in ipairs(BARS) do
		for n = 1, 12 do
			local button = _G[bar[1] .. n]
			local slot = type(button) == "table" and num(button.action) or nil
			if not slot and bar[2] == "ACTIONBUTTON" then slot = mainSlot(n) end
			if slot then
				local kind, id = call(GetActionInfo, slot)
				kind, id = str(kind), num(id)
				local spell
				if kind == "spell" then
					spell = id
				elseif kind == "macro" and id then
					spell = num((call(GetMacroSpell, id)))
				end
				local name = spell and ns.SpellNameOf(spell)
				if name then
					local key = str((call(GetBindingKey, bar[2] .. n)))
					local had = Scan.bars[name:lower()]
					-- The same spell on two buttons: the one with a key wins.
					if not had or (key and not had.key) then
						-- The button's frame is kept only to draw a glow round it.
						Scan.bars[name:lower()] = { slot = slot, id = spell, name = name, key = key, button = type(button) == "table" and button or nil }
					end
				end
			end
		end
	end
end

-- "SHIFT-2" as it fits on an icon: "S2".
function Scan.ShortKey(key)
	if not key then return nil end
	key = key:gsub("SHIFT%-", "S"):gsub("CTRL%-", "C"):gsub("ALT%-", "A")
	key = key:gsub("NUMPAD", "N"):gsub("MOUSEWHEELUP", "WU"):gsub("MOUSEWHEELDOWN", "WD"):gsub("BUTTON", "M")
	return key
end

---------------------------------------------------------------------------
-- Talents
---------------------------------------------------------------------------

local function talent(name, id, rank)
	if rank and rank > 0 then
		if name then Scan.talents[name:lower()] = rank end
		if id then Scan.talents[id] = rank end
	end
end

-- Points per tree from Polestar's map of the class's tree, when Polestar is
-- loaded: it knows which of the three columns every talent is in. A talent
-- is looked up by its node, then its spell, then its name.
local function pointsFromPolestar(taken)
	local data = call(field(field(_G.Polestar, "Talents"), "Data"), Scan.class)
	local nodes = field(data, "nodes")
	if type(nodes) ~= "table" then return false end
	local bySpell, byName = {}, {}
	for _, n in pairs(nodes) do
		if type(n) == "table" then
			if n.spell then bySpell[n.spell] = n.spec end
			if type(n.name) == "string" then byName[n.name:lower()] = n.spec end
		end
	end
	local found = false
	for _, t in ipairs(taken) do
		local n = nodes[t.node]
		local column = num((type(n) == "table" and n.spec) or (t.spell and bySpell[t.spell]) or (t.name and byName[t.name:lower()]))
		if column and column >= 1 and column <= 3 then
			Scan.points[column] = Scan.points[column] + t.rank
			found = true
		end
	end
	return found
end

-- Points per tree from where the talents sit: the tree is drawn as three
-- columns side by side, so the two widest gaps between talent positions
-- divide it into the three trees, left to right.
local function pointsFromPosition(taken, xs)
	table.sort(xs)
	local gaps = {}
	for i = 2, #xs do
		if xs[i] > xs[i - 1] then gaps[#gaps + 1] = { xs[i] - xs[i - 1], (xs[i] + xs[i - 1]) / 2 } end
	end
	if #gaps < 2 then return false end
	table.sort(gaps, function(a, b) return a[1] > b[1] end)
	local first, second = gaps[1][2], gaps[2][2]
	if first > second then first, second = second, first end
	local found = false
	for _, t in ipairs(taken) do
		if t.x then
			local column = t.x < first and 1 or (t.x < second and 2 or 3)
			Scan.points[column] = Scan.points[column] + t.rank
			found = true
		end
	end
	return found
end

local function scanTalents()
	ns.wipe(Scan.talents)
	Scan.points[1], Scan.points[2], Scan.points[3] = 0, 0, 0
	Scan.spec, Scan.pointsFrom = nil, nil
	local taken, xs = {}, {} -- the talents with ranks, and every talent's place across the tree

	-- Forever: one C_Traits tree a class, three spec columns.
	local config = num((call(fn("C_ClassTalents", "GetActiveConfigID"))))
	local T = C_Traits
	Scan.config, Scan.tree, Scan.nodes = config, nil, {}
	if config and T and T.GetConfigInfo and T.GetTreeNodes and T.GetNodeInfo then
		local trees = field(call(T.GetConfigInfo, config), "treeIDs")
		for _, tree in ipairs(type(trees) == "table" and trees or {}) do
			Scan.tree = Scan.tree or num(tree)
			local nodes = plain((call(T.GetTreeNodes, tree)))
			for _, node in ipairs(type(nodes) == "table" and nodes or {}) do
				Scan.nodes[#Scan.nodes + 1] = node
				local info = call(T.GetNodeInfo, config, node)
				local rank = num(field(info, "activeRank")) or 0
				local x = num(field(info, "posX"))
				if x then xs[#xs + 1] = x end
				if rank > 0 then
					local entry = field(field(info, "activeEntry"), "entryID") or field(field(info, "entryIDs"), 1)
					local definition = entry and field(call(T.GetEntryInfo, config, entry), "definitionID")
					local def = definition and call(T.GetDefinitionInfo, definition)
					local id = num(field(def, "spellID"))
					local name = str(field(def, "overrideName")) or (id and ns.SpellNameOf(id))
					talent(name, id, rank)
					taken[#taken + 1] = { node = node, spell = id, name = name, rank = rank, x = x }
				end
			end
		end
	elseif GetNumTalentTabs and GetNumTalents and GetTalentInfo then
		-- The older talent calls: name, icon, tier, column, rank.
		for tab = 1, num((call(GetNumTalentTabs))) or 0 do
			local spent = 0
			for index = 1, num((call(GetNumTalents, tab))) or 0 do
				local name, _, _, _, rank = call(GetTalentInfo, tab, index)
				rank = num(rank) or 0
				talent(str(name), nil, rank)
				spent = spent + rank
			end
			if tab <= 3 then Scan.points[tab] = spent end
			if spent > 0 then Scan.pointsFrom = "the talent tabs" end
		end
	else
		problem("talents could not be read")
	end

	-- Points in each tree. The character sheet's count where the game gives
	-- one (it gave none on Forever 1.60.1: one "Warrior" entry with 0); else
	-- Polestar's map of the tree; else where the talents sit.
	local S = C_SpecializationInfo
	if #taken > 0 and S and S.GetSpecializationInfo then
		local counted = { 0, 0, 0 }
		for tree = 1, 3 do
			local ok, _, _, _, _, _, _, points = pcall(S.GetSpecializationInfo, tree)
			counted[tree] = ok and num(points) or 0
		end
		if counted[1] + counted[2] + counted[3] > 0 then
			Scan.points[1], Scan.points[2], Scan.points[3] = counted[1], counted[2], counted[3]
			Scan.pointsFrom = "the game's count"
		end
	end
	if #taken > 0 and not Scan.pointsFrom then
		if pointsFromPolestar(taken) then
			Scan.pointsFrom = "Polestar's map of the tree"
		else
			Scan.points[1], Scan.points[2], Scan.points[3] = 0, 0, 0
			if pointsFromPosition(taken, xs) then Scan.pointsFrom = "where the talents sit in the tree" end
		end
		if not Scan.pointsFrom then problem("talents were found, but not which tree each is in") end
	end
	local most = 0
	for tree = 1, 3 do
		if Scan.points[tree] > most then most, Scan.spec = Scan.points[tree], tree end
	end
	-- A primary tree the player chose outranks the count.
	if S and S.GetSpecialization then
		local chosen = num((call(S.GetSpecialization)))
		if chosen and chosen >= 1 and chosen <= 3 and most > 0 and Scan.points[chosen] == most then Scan.spec = chosen end
	end
end

-- Ranks taken in a talent, by English name or spell ID; 0 when none.
function Scan.Talent(name)
	if type(name) == "string" then name = name:lower() end
	return Scan.talents[name] or 0
end

---------------------------------------------------------------------------
-- Gear
---------------------------------------------------------------------------

local WEAPON, ARMOR = 2, 4
local SUB = { bow = 2, gun = 3, dagger = 15, thrown = 16, crossbow = 18, wand = 19, shield = 6 }

local function item(slot)
	local id = num((call(GetInventoryItemID, "player", slot)))
	if not id then return nil end
	local _, _, _, loc, _, class, sub = call(fn("C_Item", "GetItemInfoInstant"), id)
	return { id = id, loc = str(loc), class = num(class), sub = num(sub) }
end

local function scanGear()
	local main, off, ranged = item(16), item(17), item(18)
	local g = ns.wipe(Scan.gear)
	g.main, g.off, g.ranged = main, off, ranged
	g.twoHand = main ~= nil and main.loc == "INVTYPE_2HWEAPON"
	g.shield = off ~= nil and (off.loc == "INVTYPE_SHIELD" or (off.class == ARMOR and off.sub == SUB.shield))
	g.dualWield = off ~= nil and off.class == WEAPON
	g.dagger = main ~= nil and main.class == WEAPON and main.sub == SUB.dagger
	local function is(it, ...)
		if not (it and it.class == WEAPON) then return false end
		for i = 1, select("#", ...) do
			if it.sub == select(i, ...) then return true end
		end
		return false
	end
	-- Classic keeps wands and bows in the ranged slot, later clients in the main hand.
	g.wand = is(ranged, SUB.wand) or is(main, SUB.wand)
	g.rangedWeapon = is(ranged, SUB.bow, SUB.gun, SUB.crossbow, SUB.thrown) or is(main, SUB.bow, SUB.gun, SUB.crossbow)
	g.speed = num((call(UnitAttackSpeed, "player")))
end

---------------------------------------------------------------------------

-- Points spent on the talent tree, as the tree's own currency counts them.
local function spent()
	local T = C_Traits
	if not (Scan.config and Scan.tree and T and T.GetTreeCurrencyInfo) then return nil end
	local list = ns.plain((call(T.GetTreeCurrencyInfo, Scan.config, Scan.tree, false)))
	if type(list) ~= "table" then return nil end
	local total = 0
	for _, currency in ipairs(list) do total = total + (num(field(currency, "spent")) or 0) end
	return total
end
Scan.Spent = spent

-- The ranks taken across the tree, folded into one number: a respec that
-- spends the same points elsewhere changes it.
local function talentHash()
	local T = C_Traits
	if not (Scan.config and Scan.nodes and T and T.GetNodeInfo) then return -1 end
	local hash = 0
	for i, node in ipairs(Scan.nodes) do
		local rank = num(field(call(T.GetNodeInfo, Scan.config, node), "activeRank")) or 0
		hash = (hash + rank * (i * 31 + 7)) % 1000003
	end
	return hash
end

local function spellCount()
	local B, total = C_SpellBook, 0
	if not (B and B.GetNumSpellBookSkillLines and B.GetSpellBookSkillLineInfo) then return 0 end
	for line = 1, num((call(B.GetNumSpellBookSkillLines))) or 0 do
		total = total + (num(field(call(B.GetSpellBookSkillLineInfo, line), "numSpellBookItems")) or 0)
	end
	return total
end

-- A cheap fingerprint of everything the list is built from: level, each
-- talent's ranks, spellbook size, weapons, stance or form. Checked once a second, so
-- a change the game announced with an event this add-on does not know still
-- rebuilds the list (respeccing from Arms to Protection, say).
function Scan.Signature()
	local parts = { num((call(UnitLevel, "player"))) or 0, spellCount(), spent() or -1, talentHash(),
		num((call(fn("C_ClassTalents", "GetActiveConfigID")))) or 0 }
	local S = C_SpecializationInfo
	for tree = 1, 3 do
		local points
		if S and S.GetSpecializationInfo then
			local ok, _, _, _, _, _, _, p = pcall(S.GetSpecializationInfo, tree)
			points = ok and num(p)
		end
		parts[#parts + 1] = points or -1
	end
	for slot = 16, 18 do parts[#parts + 1] = num((call(GetInventoryItemID, "player", slot))) or 0 end
	parts[#parts + 1] = num((call(GetShapeshiftForm))) or 0
	return table.concat(parts, ":")
end

function Scan.All()
	ns.wipe(Scan.problems)
	Scan.stance = num((call(GetShapeshiftForm))) or 0
	Scan.form = num((call(GetShapeshiftFormID))) or 0
	ns.wipe(Scan.stances)
	for place = 1, num((call(GetNumShapeshiftForms))) or 0 do
		-- icon, active, castable, spell
		local _, _, _, spell = call(GetShapeshiftFormInfo, place)
		Scan.stances[place] = ns.SpellNameOf(num(spell)) or ("stance " .. place)
	end
	local _, class = call(UnitClass, "player")
	Scan.class = str(class)
	Scan.level = num((call(UnitLevel, "player"))) or 1
	if not Scan.class then problem("the class could not be read") end
	scanSpells()
	scanBars()
	scanTalents()
	scanGear()
end

-- Only the bars: what a stance or form change swaps.
function Scan.Bars()
	scanBars()
end
