-- The rotation editor (/pnext edit): pick a rotation, reorder, add and
-- remove abilities, and edit each one's AND / OR / NOT condition.
--
-- There is a rotation for each talent tree and stance or form. The editor
-- opens on the one in use and can be turned to any other. Looking changes
-- nothing; the first edit to a rotation copies the built one into the
-- character's saved settings, and from then on that copy is that rotation
-- (used as it is: neither the game's numbers nor a respec reorder it).
-- "Use the built one" throws the copy away.
--
-- The top half of this file is the editing itself, on plain tables, so the
-- tests can drive it without a window; the bottom half is the window.

local _, ns = ...
local Scan, Engine, Rules, UI = ns.Scan, ns.Engine, ns.Rules, ns.UI

local Edit = { spec = nil, stance = nil }
ns.Edit = Edit

---------------------------------------------------------------------------
-- The tests a condition can use, as the menu lists them.
-- { name, what it takes ("spell", "number" or nothing), how it reads, the
-- number a new one starts with, the numbers that follow a spell }
---------------------------------------------------------------------------

Edit.TESTS = {
	{ "target", nil, "I have something to attack targeted" },
	{ "combat", nil, "I am in combat" },
	{ "debuff", "spell", "the target has my effect" },
	{ "buff", "spell", "I have the effect" },
	{ "stacks<", "spell", "fewer than five stacks on the target of", nil, { 5, 28 } },
	{ "fading", "spell", "is about to fade from the target:", nil, { 4.5, 30 } },
	{ "enemies>=", "number", "enemies in reach are at least", 2 },
	{ "power>=", "number", "rage / energy / mana is at least", 30 },
	{ "power<", "number", "rage / energy / mana is below", 30 },
	{ "mana%>=", "number", "mana % is at least", 40 },
	{ "mana%<", "number", "mana % is below", 40 },
	{ "health%<", "number", "my health % is below", 40 },
	{ "health%>=", "number", "my health % is at least", 40 },
	{ "target%<", "number", "the target's health % is below", 20 },
	{ "target%>=", "number", "the target's health % is at least", 20 },
	{ "combo>=", "number", "combo points are at least", 5 },
	{ "elite", nil, "the target is elite" },
	{ "melee", nil, "the target is in melee reach" },
	{ "targetcasting", nil, "the target is casting" },
	{ "moving", nil, "I am moving" },
	{ "stealth", nil, "I am stealthed" },
	{ "stance", "number", "my stance (1, 2, 3) is", 1 },
	{ "form", "number", "my form number is", 1 },
	{ "pet", nil, "my pet is out" },
	{ "pet%<", "number", "my pet's health % is below", 40 },
	{ "imbue", nil, "my weapon has a temporary enchant" },
	{ "selfdebuff", "spell", "I have the harmful effect" },
	{ "charges>=", "spell", "I have a stack or more of", nil, { 1 } },
	{ "lit", "spell", "the game lights up the button of" },
	{ "known", "spell", "I know the spell" },
	{ "usable", "spell", "the game says I can use" },
	{ "ready", "spell", "it is off cooldown:" },
	{ "active", "spell", "it is switched on:" },
}
local testIndex = {}
for i, entry in ipairs(Edit.TESTS) do testIndex[entry[1]] = i end

local function grouping(node)
	return type(node) == "table" and (node[1] == "and" or node[1] == "or")
end
local function wrapping(node)
	return type(node) == "table" and (node[1] == "not" or node[1] == "maybe")
end

local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in pairs(value) do out[k] = copy(v) end
	return out
end

---------------------------------------------------------------------------
-- Which rotation
---------------------------------------------------------------------------

-- Turns the editor to the rotation for a tree (0: before any talents) and
-- stance (0: none); without arguments, back to the one in use.
function Edit.Pick(spec, stance)
	Edit.spec, Edit.stance = spec, stance
end

function Edit.Key()
	return Engine.Key(Edit.spec, Edit.stance)
end

-- The editor is on the rotation the character is using right now.
function Edit.InUse()
	return Edit.Key() == Engine.key
end

local built = {} -- key -> { list, notes, signature }: built rotations other than the one in use

-- The built rotation the editor is on, and why it came out as it did.
function Edit.Built()
	local key = Edit.Key()
	if key == Engine.key and not Engine.custom then return Engine.list, Engine.notes end
	local kept = built[key]
	if not kept or kept.signature ~= Engine.signature then
		local notes = {}
		kept = { list = Engine.Build(notes, Edit.spec, Edit.stance), notes = notes, signature = Engine.signature }
		built[key] = kept
	end
	return kept.list, kept.notes
end

-- The rotation to show: the player's own version when they have one, else
-- the built one. Looking does not make a copy; only an edit does (Edit.List).
function Edit.Current()
	return Engine.Own(Edit.Key()) or (Edit.Built())
end

-- The player's own version of the rotation the editor is on, made from the
-- built one on first use.
function Edit.List()
	local db = ns.db
	if not (db and Scan.class) then return nil end
	local key = Edit.Key()
	db.lists = db.lists or {}
	if not Engine.Own(key) then
		local own = {}
		for i, rule in ipairs((Edit.Built())) do
			-- The numbers' markings belong to the built list, not to this one.
			own[i] = { spell = copy(rule.spell), when = copy(rule.when), note = rule.note, toggle = rule.toggle, react = rule.react, off = rule.off }
		end
		db.lists[key] = own
	end
	return db.lists[key]
end

-- Makes the edited rotation count. Returns nil, or what is wrong with it.
function Edit.Commit()
	local list = Edit.List()
	local bad = list and Engine.Lint(list)
	if bad then return bad end
	-- Marked as the player's doing, so it is kept across sessions.
	ns.db.edited = ns.db.edited or {}
	ns.db.edited[Edit.Key()] = true
	Engine.Rebuild()
	return nil
end

---------------------------------------------------------------------------
-- Undo and redo. Before each change the rotation's earlier state is put on
-- its own pile (one pile a rotation, kept for the session): either the
-- player's version as it was, or `false` for "no version of their own yet".
---------------------------------------------------------------------------

local undone, redone = {}, {}
local DEPTH = 60

-- The rotation as it stands, to go on a pile.
local function snapshot(key)
	local own = Engine.Own(key or Edit.Key())
	return own and copy(own) or false
end

-- Records `was` as the state to go back to, and forgets what was undone.
local function remember(was, key)
	key = key or Edit.Key()
	local pile = undone[key] or {}
	undone[key] = pile
	pile[#pile + 1] = was
	if #pile > DEPTH then table.remove(pile, 1) end
	redone[key] = {}
end

-- Makes `version` (or, for false, the built rotation) the one kept under `key`.
local function restore(key, version)
	local db = ns.db
	db.lists, db.edited = db.lists or {}, db.edited or {}
	db.lists[key] = version or nil
	db.edited[key] = version and true or nil
	built[key] = nil
	Engine.Rebuild()
end

local function step(from, to)
	local key = Edit.Key()
	local pile = from[key]
	if not (ns.db and pile and #pile > 0) then return false end
	to[key] = to[key] or {}
	to[key][#to[key] + 1] = snapshot(key)
	restore(key, table.remove(pile))
	return true
end

function Edit.Undo() return step(undone, redone) end
function Edit.Redo() return step(redone, undone) end
function Edit.CanUndo() local pile = undone[Edit.Key()] return pile ~= nil and #pile > 0 end
function Edit.CanRedo() local pile = redone[Edit.Key()] return pile ~= nil and #pile > 0 end

-- Throws the player's version of this rotation away: the built one is used.
function Edit.Reset()
	local key = Edit.Key()
	if not Engine.Own(key) then return end
	remember(snapshot(key), key)
	restore(key, false)
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

function Edit.Move(from, to)
	local shown = Edit.Current()
	if not shown or not shown[from] then return end
	to = math.max(1, math.min(#shown, to))
	if to == from then return end
	remember(snapshot())
	local list = Edit.List()
	table.insert(list, to, table.remove(list, from))
	return Edit.Commit()
end

function Edit.RemoveRule(index)
	local shown = Edit.Current()
	if not shown or not shown[index] then return end
	remember(snapshot())
	local gone = table.remove(Edit.List(), index)
	-- Remembered, so that Update does not bring back what the player took out.
	local db, key = ns.db, Edit.Key()
	db.removed = type(db.removed) == "table" and db.removed or {}
	db.removed[key] = db.removed[key] or {}
	db.removed[key][(ns.SpellName(gone.spell) or "?") .. "\0" .. (gone.note or "")] = true
	return Edit.Commit()
end

-- Switches an ability off, so it is passed over but keeps its place and its
-- condition, or back on.
function Edit.ToggleRule(index)
	local shown = Edit.Current()
	if not shown or not shown[index] then return end
	remember(snapshot())
	local rule = Edit.List()[index]
	rule.off = not rule.off or nil
	return Edit.Commit()
end

-- A second copy of an ability, straight after it: the way to use one spell
-- under two different conditions.
function Edit.Duplicate(index)
	local shown = Edit.Current()
	if not shown or not shown[index] then return end
	remember(snapshot())
	local list = Edit.List()
	table.insert(list, index + 1, copy(list[index]))
	return Edit.Commit()
end

-- One change to the condition of the ability at `index`: `change(rule, ...)`
-- is any of the condition edits below. Returns nil, or what went wrong; a
-- change that did not take (text where a number goes) leaves nothing behind.
function Edit.Change(index, change, ...)
	local shown = Edit.Current()
	if not shown or not shown[index] then return "no ability is selected" end
	local key, was = Edit.Key(), snapshot()
	local rule = Edit.List()[index]
	local result = change(rule, ...)
	if result == false then
		if was == false then restore(key, false) end
		return "That needs a number."
	end
	rule.mine = true
	remember(was)
	return Edit.Commit()
end

---------------------------------------------------------------------------
-- Bringing a kept rotation up to date. A version of the player's own is
-- used exactly as it is, so it misses what a later version of the add-on
-- learns about a condition. An ability that came from the built rotation
-- (the same spell under the same note), and whose condition the player has
-- not changed themselves, can take the built condition as it is now. The
-- order, the switches, and all the player added or changed stay as they are.
---------------------------------------------------------------------------

local function same(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not same(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function origin(rule)
	return (ns.SpellName(rule.spell) or "?") .. "\0" .. (rule.note or "")
end

-- Counts the abilities of the player's version that are behind the built
-- rotation, handing each to `each(rule, fresh)` with the built one.
local function behind(each)
	local own = Engine.Own(Edit.Key())
	if not own then return 0 end
	local from = {}
	for _, rule in ipairs((Edit.Built())) do from[origin(rule)] = from[origin(rule)] or rule end
	local count = 0
	for _, rule in ipairs(own) do
		local fresh = not rule.mine and from[origin(rule)]
		if fresh and not (same(rule.when, fresh.when) and (rule.toggle or false) == (fresh.toggle or false)
			and (rule.react or false) == (fresh.react or false)) then
			count = count + 1
			if each then each(rule, fresh) end
		end
	end
	return count
end

-- The built rotation moves on too: abilities are added to it (a new one in
-- the game, a better use of an old one) and taken out of it.
--   new: built abilities the player's version has no place for, each with
--     the next built ability the player's version does have, so it can go
--     in just above that one and keep its priority. What the player took
--     out themselves is not among them.
--   gone: places in the player's version that came from an earlier built
--     rotation and are in it no longer. Not what the player added ("yours")
--     or changed, and not what came in from someone else's string.
local function drift()
	local key = Edit.Key()
	local own = Engine.Own(key)
	local new, gone = {}, {}
	if not own then return new, gone end
	local have, built = {}, {}
	for _, rule in ipairs(own) do have[origin(rule)] = true end
	local dropped = ns.db and type(ns.db.removed) == "table" and ns.db.removed[key] or {}
	local waiting = {}
	for _, rule in ipairs((Edit.Built())) do
		local id = origin(rule)
		built[id] = true
		if have[id] then
			-- Everything new since the last one the player has goes above this.
			for _, add in ipairs(waiting) do add.before = id end
			waiting = {}
		elseif not dropped[id] then
			local add = { rule = rule }
			new[#new + 1], waiting[#waiting + 1] = add, add
		end
	end
	for index, rule in ipairs(own) do
		if not rule.mine and rule.note ~= "yours" and not built[origin(rule)] then gone[#gone + 1] = index end
	end
	return new, gone
end

-- How many places of the rotation the editor is on would change.
function Edit.Behind()
	local new, gone = drift()
	return behind() + #new + #gone
end

-- Of those, how many are abilities to add and how many to take out.
function Edit.Drift()
	local new, gone = drift()
	return #new, #gone
end

-- Brings the player's version up to date: newer conditions taken, the built
-- rotation's new abilities put in where they belong, what it no longer has
-- taken out. The order and the player's own changes stay. Returns how many
-- places changed. Undo takes it back.
function Edit.Update()
	local total = Edit.Behind()
	if total == 0 then return 0 end
	remember(snapshot())
	behind(function(rule, fresh)
		rule.when, rule.toggle, rule.react = copy(fresh.when), fresh.toggle, fresh.react
	end)
	local own = Engine.Own(Edit.Key())
	local new, gone = drift()
	-- From the end, so the places before it keep their numbers.
	for i = #gone, 1, -1 do table.remove(own, gone[i]) end
	for _, add in ipairs(new) do
		-- Above the next built ability the player has; at the end when there is none.
		local at = #own + 1
		for index, rule in ipairs(own) do
			if add.before and origin(rule) == add.before then
				at = index
				break
			end
		end
		local rule = add.rule
		table.insert(own, at, { spell = copy(rule.spell), when = copy(rule.when), note = rule.note, toggle = rule.toggle, react = rule.react })
	end
	Edit.Commit()
	return total
end

-- Said once a session: the rotation in use is the player's own version, and
-- the built one has moved on since.
local noticed = false
function Edit.Notice()
	if noticed or not (ns.db and Scan.class and Engine.custom) then return end
	noticed = true
	local spec, stance = Edit.spec, Edit.stance
	Edit.Pick()
	local total, new = Edit.Behind(), (Edit.Drift())
	Edit.Pick(spec, stance)
	if total > 0 then
		ns.say(("your %s rotation is your own version, and the built one has moved on in %d places since%s. /pnext update takes them in and keeps your order; Undo in the editor takes it back.")
			:format(Engine.Title(), total, new > 0 and (" (%d new abilities)"):format(new) or ""))
	end
end

-- Once: rotations kept by a version before 0.8.0, which could not tell a
-- condition the player changed from one it built itself, and had no Update,
-- are brought up to date on their own. The player is told, and can undo it.
function Edit.Migrate()
	local db = ns.db
	if not (db and Scan.class) or (db.fresh or 0) >= 8 then return end
	db.fresh = 8
	local spec, stance = Edit.spec, Edit.stance
	for key in pairs(type(db.lists) == "table" and db.lists or {}) do
		local class, tree, form = tostring(key):match("^(%u+):(%d+):(%d+)$")
		if class == Scan.class then
			Edit.Pick(tonumber(tree), tonumber(form))
			local count = Edit.Update()
			if count > 0 then
				ns.say(("your %s rotation is up to date with this version: it changed in %d places. Your order is kept; Undo in the editor takes it back.")
					:format(Engine.Title(tonumber(tree), tonumber(form)), count))
			end
		end
	end
	Edit.Pick(spec, stance)
end

-- The spells the character can put in a rotation, for the picker: those
-- whose name has `filter` in it, the ones starting with it first.
function Edit.Spells(filter)
	local wanted = (filter or ""):lower():match("^%s*(.-)%s*$")
	local out = {}
	for lower, spell in pairs(Scan.spells) do
		if not spell.passive and (wanted == "" or lower:find(wanted, 1, true)) then out[#out + 1] = spell end
	end
	table.sort(out, function(a, b)
		local first, second = a.name:lower():find(wanted, 1, true) == 1, b.name:lower():find(wanted, 1, true) == 1
		if first ~= second then return first end
		return a.name < b.name
	end)
	return out
end

-- A spell reference for what the player typed: a spell they know whose name
-- is, or contains, the text; else the text itself as a name.
function Edit.Spell(text)
	text = (text or ""):match("^%s*(.-)%s*$")
	if text == "" then return nil end
	local lower = text:lower()
	local exact = Scan.spells[lower] or Scan.bars[lower]
	if exact then return { exact.id, exact.name } end
	local found
	for name, entry in pairs(Scan.spells) do
		if name:find(lower, 1, true) and (not found or #name < #found.name) then found = entry end
	end
	if found then return { found.id, found.name } end
	return { nil, text }
end

-- Adds an ability, to use whenever there is something to attack: after the
-- one at `after`, or at the end.
function Edit.AddRule(text, after)
	local spell = Edit.Spell(text)
	if not spell then return "name a spell" end
	if not (ns.db and Scan.class) then return "no character yet" end
	remember(snapshot())
	local list = Edit.List()
	local at = (after and after >= 0 and after < #list) and after + 1 or #list + 1
	table.insert(list, at, { spell = spell, when = { "target" }, note = "yours" })
	return Edit.Commit()
end

---------------------------------------------------------------------------
-- A rule's condition. A node is reached by its path: the index to follow at
-- each level ({} is the condition itself, { 3 } its second part, ...).
---------------------------------------------------------------------------

local function at(rule, path)
	local node = rule.when
	for _, i in ipairs(path) do node = node[i] end
	return node
end

local function put(rule, path, value)
	if #path == 0 then
		rule.when = value
		return
	end
	local parent = rule.when
	for k = 1, #path - 1 do parent = parent[path[k]] end
	parent[path[#path]] = value
end

local function parentOf(path)
	local up = {}
	for k = 1, #path - 1 do up[k] = path[k] end
	return up, path[#path]
end

-- The condition as rows to show, top down: { path, depth, node }.
function Edit.Rows(rule)
	local rows = {}
	local function walk(node, path, depth)
		rows[#rows + 1] = { path = path, depth = depth, node = node }
		if grouping(node) or wrapping(node) then
			for i = 2, #node do
				local deeper = {}
				for k, v in ipairs(path) do deeper[k] = v end
				deeper[#deeper + 1] = i
				walk(node[i], deeper, depth + 1)
			end
		end
	end
	if rule.when then walk(rule.when, {}, 0) end
	return rows
end

-- How a row reads.
function Edit.Label(node)
	if grouping(node) then return node[1] == "and" and "ALL of:" or "ANY of:" end
	if node[1] == "not" then return "NOT:" end
	if node[1] == "maybe" then return "if the game will say, else yes:" end
	local entry = Edit.TESTS[testIndex[node[1]] or 0]
	local text = entry and entry[3] or node[1]
	if node[1] == "charges>=" and (node[3] or 1) > 1 then
		return ("I have %s or more stacks of %s"):format(tostring(node[3]), ns.SpellName(node[2]) or "?")
	end
	if entry and entry[2] == "spell" then return text .. " " .. (ns.SpellName(node[2]) or "?") end
	if entry and entry[2] == "number" then return text .. " " .. tostring(node[2]) end
	return text
end

-- NOT on a node that has none, off one that has.
function Edit.ToggleNot(rule, path)
	local node = at(rule, path)
	if not node then return end
	local up = parentOf(path)
	if node[1] == "not" then
		put(rule, path, node[2])
	elseif #path > 0 and at(rule, up)[1] == "not" then
		put(rule, up, node)
	else
		put(rule, path, { "not", node })
	end
end

-- ALL of <-> ANY of.
function Edit.ToggleGroup(rule, path)
	local node = at(rule, path)
	if grouping(node) then node[1] = node[1] == "and" and "or" or "and" end
end

-- Adds a part to the node at `path`: into a group, or beside anything else
-- by putting the two in a new ALL-of group.
function Edit.AddPart(rule, path, part)
	part = part or { "target" }
	local node = rule.when and at(rule, path)
	if not node then
		rule.when = part
	elseif grouping(node) then
		node[#node + 1] = part
	else
		put(rule, path, { "and", node, part })
	end
end

-- Removes the node at `path`. A group left empty, and a NOT left with
-- nothing to negate, go with it.
function Edit.RemovePart(rule, path)
	if #path == 0 then
		rule.when = nil
		return
	end
	local up, index = parentOf(path)
	local parent = at(rule, up)
	if wrapping(parent) then return Edit.RemovePart(rule, up) end
	table.remove(parent, index)
	if #parent == 1 then return Edit.RemovePart(rule, up) end
end

-- Puts the test called `name` in place of the test at `path`, starting on
-- the rule's own spell or the test's usual number.
function Edit.SetTest(rule, path, name)
	local node = at(rule, path)
	local entry = Edit.TESTS[testIndex[name] or 0]
	if not node or not entry or grouping(node) or wrapping(node) then return end
	local fresh = { entry[1] }
	if entry[2] == "spell" then fresh[2] = copy(rule.spell) end
	if entry[2] == "number" then fresh[2] = entry[4] end
	for i, extra in ipairs(entry[5] or {}) do fresh[2 + i] = extra end
	put(rule, path, fresh)
end

-- The next test (or the one before, step = -1) in place of this one.
function Edit.StepTest(rule, path, step)
	local node = at(rule, path)
	if not node or grouping(node) or wrapping(node) then return end
	local i = ((testIndex[node[1]] or 1) - 1 + (step or 1)) % #Edit.TESTS + 1
	Edit.SetTest(rule, path, Edit.TESTS[i][1])
end

-- What the player typed, as the test's spell or number. False when it is
-- not a number where one is needed.
function Edit.SetValue(rule, path, text)
	local node = at(rule, path)
	local entry = node and Edit.TESTS[testIndex[node[1]] or 0]
	if not entry then return false end
	if entry[2] == "number" then
		local n = tonumber(text)
		if not n then return false end
		node[2] = n
	elseif entry[2] == "spell" then
		local spell = Edit.Spell(text)
		if not spell then return false end
		node[2] = spell
	end
	return true
end

---------------------------------------------------------------------------
-- A condition in plain words. Each test is said two ways, for when it holds
-- and when it does not, so that a NOT never has to be read as one: negation
-- is pushed down to the tests ("not (A or B)" is "neither"), groups inside
-- groups of the same kind are run together, and the rule's own spell is "it".
---------------------------------------------------------------------------

local FORM_NAMES = { [1] = "Cat Form", [5] = "Bear Form", [8] = "Dire Bear Form", [31] = "Moonkin Form" }

local function two(yes, no)
	return function(c) return yes:format(tostring(c[2])), no:format(tostring(c[2])) end
end
local function about(yes, no)
	return function(_, spell) return yes:format(spell), no:format(spell) end
end

local SAY = {
	target = two("you have a target", "you have no target"),
	combat = two("you are in a fight", "the fight has not started"),
	elite = two("the target is elite", "the target is not elite"),
	melee = two("the target is in melee reach", "the target is out of melee reach"),
	targetcasting = two("the target is casting", "the target is not casting"),
	moving = two("you are moving", "you are standing still"),
	stealth = two("you are stealthed", "you are not stealthed"),
	pet = two("your pet is out", "your pet is not out"),
	imbue = two("your weapon has a temporary enchant", "your weapon has no temporary enchant"),
	debuff = about("%s is on the target", "%s is not on the target"),
	buff = about("you have %s", "you do not have %s"),
	selfdebuff = about("%s is on you", "%s is not on you"),
	known = about("you know %s", "you do not know %s"),
	usable = about("the game says %s can be used", "the game says %s cannot be used"),
	ready = about("%s is off cooldown", "%s is on cooldown"),
	active = about("%s is switched on", "%s is not switched on"),
	lit = about("the game lights %s up", "the game is not lighting %s up"),
	["charges>="] = function(c, spell)
		local n = c[3] or 1
		if n <= 1 then return ("you have %s"):format(spell), ("you do not have %s"):format(spell) end
		return ("you have %s or more stacks of %s"):format(tostring(n), spell), ("you have fewer than %s stacks of %s"):format(tostring(n), spell)
	end,
	["stacks<"] = function(c, spell)
		local n = tostring(c[3] or 5)
		return ("%s is stacked fewer than %s times"):format(spell, n), ("%s is stacked %s times"):format(spell, n)
	end,
	fading = function(c, spell)
		return ("%s has under %s seconds left"):format(spell, tostring(c[3] or "?")), ("%s is not about to fade"):format(spell)
	end,
	["enemies>="] = two("%s or more enemies are in reach", "fewer than %s enemies are in reach"),
	["power>="] = function(c) local bar = Engine.PowerName() return ("%s is %s or more"):format(bar, tostring(c[2])), ("%s is under %s"):format(bar, tostring(c[2])) end,
	["power<"] = function(c) local bar = Engine.PowerName() return ("%s is under %s"):format(bar, tostring(c[2])), ("%s is %s or more"):format(bar, tostring(c[2])) end,
	["mana%>="] = two("mana is %s%% or more", "mana is under %s%%"),
	["mana%<"] = two("mana is under %s%%", "mana is %s%% or more"),
	["health%>="] = two("your health is %s%% or more", "your health is under %s%%"),
	["health%<"] = two("your health is under %s%%", "your health is %s%% or more"),
	["target%>="] = two("the target's health is %s%% or more", "the target's health is under %s%%"),
	["target%<"] = two("the target's health is under %s%%", "the target's health is %s%% or more"),
	["pet%<"] = two("your pet's health is under %s%%", "your pet's health is %s%% or more"),
	["combo>="] = function(c)
		local n = tostring(c[2])
		return ("you have at least %s combo point%s"):format(n, c[2] == 1 and "" or "s"), ("you have fewer than %s combo points"):format(n)
	end,
	stance = function(c)
		local name = Scan.stances[c[2] or 0] or ("stance " .. tostring(c[2]))
		return "you are in " .. name, "you are not in " .. name
	end,
	form = function(c)
		local name = FORM_NAMES[c[2] or 0] or ("form " .. tostring(c[2]))
		return "you are in " .. name, "you are not in " .. name
	end,
}

-- The condition as a tree of ANDs and ORs over tests, each test marked as
-- wanted true or false, and as a margin ("maybe") or not.
local function shape(c, negated, unsure)
	local op = c[1]
	if op == "not" then return shape(c[2], not negated, unsure) end
	if op == "maybe" then return shape(c[2], negated, true) end
	if op == "and" or op == "or" then
		local joined = ((op == "and") ~= negated) and "and" or "or"
		local group = { op = joined, parts = {} }
		for i = 2, #c do
			local part = shape(c[i], negated, unsure)
			if part.op == joined then
				for _, inner in ipairs(part.parts) do group.parts[#group.parts + 1] = inner end
			else
				group.parts[#group.parts + 1] = part
			end
		end
		if #group.parts == 1 then return group.parts[1] end
		return group
	end
	return { leaf = c, negated = negated, unsure = unsure }
end

local function run(parts, word)
	if #parts <= 2 then return table.concat(parts, " " .. word .. " ") end
	return table.concat(parts, ", ", 1, #parts - 1) .. " " .. word .. " " .. parts[#parts]
end

local function words(node, own, inner)
	if node.text then return node.text end
	if node.leaf then
		local c = node.leaf
		local say = SAY[c[1]]
		local spell = type(c[2]) == "table" and (ns.SpellName(c[2]) or "?") or nil
		if spell and spell == own then spell = "it" end
		local yes, no
		if say then yes, no = say(c, spell) else yes, no = Rules.Describe(c), "not " .. Rules.Describe(c) end
		return (node.negated and no or yes) .. (node.unsure and " (as far as the game shows)" or "")
	end
	local parts = node.parts
	if node.op == "and" then
		-- "Targeted and in a fight" is one thought.
		local target, combat
		for i, part in ipairs(parts) do
			if part.leaf and not part.unsure then
				if part.leaf[1] == "target" and not part.negated then target = i end
				if part.leaf[1] == "combat" then combat = i end
			end
		end
		if target and combat then
			local merged = {}
			for i, part in ipairs(parts) do
				if i == target then
					merged[#merged + 1] = { text = parts[combat].negated and "you are about to start a fight" or "you are fighting something" }
				elseif i ~= combat then
					merged[#merged + 1] = part
				end
			end
			parts = merged
		end
	end
	-- Single tests first, groups after them: "A, B and either C or D".
	local said = {}
	for _, part in ipairs(parts) do
		if not part.parts then said[#said + 1] = words(part, own, true) end
	end
	for _, part in ipairs(parts) do
		if part.parts then said[#said + 1] = words(part, own, true) end
	end
	local text = run(said, node.op)
	if inner and #said > 1 then text = (node.op == "or" and "either " or (#said > 2 and "all of " or "both ")) .. text end
	return text
end

-- Condition `c` in plain words; `own` is the name of the spell it is for.
function Edit.Plain(c, own)
	if c == nil then return "always" end
	return words(shape(c, false, false), own, false)
end

-- A whole rule in a sentence or two.
function Edit.Summary(rule)
	local name = ns.SpellName(rule.spell) or "?"
	local text = rule.when == nil and ("Use %s whenever it can be used."):format(name)
		or ("Use %s when %s."):format(name, Edit.Plain(rule.when, name))
	if rule.toggle then text = text .. " It is switched on once and left on." end
	if rule.react then text = text .. " It answers a dodge, block or parry: it comes up when the game lights it." end
	if rule.off then text = text .. " Switched off for now." end
	return text
end

---------------------------------------------------------------------------
-- Ready-made conditions: the usual reasons for a place in a rotation, to
-- pick instead of building them test by test. One is added to what the
-- ability already asks (ALL of it must hold), leaving out what is there
-- already. { what it is called, the tests it stands for }.
---------------------------------------------------------------------------

local function own(rule) return copy(rule.spell) end

Edit.PRESETS = {
	{ "In a fight", function() return { { "target" }, { "combat" } } end },
	{ "Before the fight starts (an opener)", function() return { { "target" }, { "not", { "combat" } } } end },
	{ "Keep it on the target", function(rule) return { { "target" }, { "not", { "debuff", own(rule) } } } end },
	{ "Keep it on me", function(rule) return { { "not", { "buff", own(rule) } } } end },
	{ "Stack it to five and keep it from dropping", function(rule)
		return { { "target" }, { "or", { "stacks<", own(rule), 5, 30 }, { "fading", own(rule), 4.5, 30 } } }
	end },
	{ function() return ("Only with %s to spare (30 or more)"):format(Engine.PowerName()) end, function() return { { "power>=", 30 } } end },
	{ "Only with mana in reserve (40% or more)", function() return { { "maybe", { "mana%>=", 40 } } } end },
	{ "Two or more enemies in reach", function() return { { "enemies>=", 2 } } end },
	{ "Three or more enemies in reach", function() return { { "enemies>=", 3 } } end },
	{ "One enemy only", function() return { { "not", { "enemies>=", 2 } } } end },
	{ "To finish: the target is under 20% health", function() return { { "target" }, { "maybe", { "target%<", 20 } } } end },
	{ "Not on a dying target (30% health or more)", function() return { { "maybe", { "target%>=", 30 } } } end },
	{ "When I am hurt (under 40% health)", function() return { { "health%<", 40 } } end },
	{ "To interrupt: the target is casting", function() return { { "target" }, { "targetcasting" } } end },
	{ "At five combo points", function() return { { "target" }, { "combo>=", 5 } } end },
	{ "Standing still (it has a cast time)", function() return { { "not", { "moving" } } } end },
	{ "On an elite", function() return { { "target" }, { "elite" } } end },
	{ "Start again: whenever there is a target", function() return { { "target" } } end, replace = true },
}

-- What ready-made condition `index` is called.
function Edit.PresetName(index)
	local preset = Edit.PRESETS[index]
	if not preset then return nil end
	return type(preset[1]) == "function" and preset[1]() or preset[1]
end

-- Whether `part` is already asked for by `c`: as it stands, or anywhere in
-- its chain of ANDs.
local function holds(c, part)
	if same(c, part) then return true end
	if type(c) == "table" and c[1] == "and" then
		for i = 2, #c do
			if holds(c[i], part) then return true end
		end
	end
	return false
end

-- Adds ready-made condition `index` to `rule` (an edit, for Edit.Change).
function Edit.AddPreset(rule, index)
	local preset = Edit.PRESETS[index]
	if not preset then return end
	local parts = preset[2](rule)
	if preset.replace or rule.when == nil then
		rule.when = #parts == 1 and parts[1] or { "and", unpack(parts) }
		return
	end
	if rule.when[1] ~= "and" then rule.when = { "and", rule.when } end
	for _, part in ipairs(parts) do
		if not holds(rule.when, part) then rule.when[#rule.when + 1] = part end
	end
end

---------------------------------------------------------------------------
-- Sharing. A rotation as a string to copy, and back again.
--
-- The string is "PNR1:<payload>:<check>". The payload is the rotation written
-- out as plain data in a small notation of its own (numbers, pieces of text
-- with their length, lists), in letters that survive being pasted anywhere;
-- the check is a sum over it that catches a string cut short or mangled.
--
-- Reading one never runs anything. It is taken apart piece by piece by the
-- reader below, within limits on its size and depth, then checked: the
-- class, the tests it uses, the shape of every rule. Only then is it kept.
---------------------------------------------------------------------------

local PREFIX, FORMAT = "PNR", 1
local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local VALUE = {}
for i = 1, 64 do VALUE[LETTERS:byte(i)] = i - 1 end
local TOGGLE, REACT, OFF = 1, 2, 4

local function toLetters(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local function letter(shift) local v = math.floor(n / shift) % 64 + 1 return LETTERS:sub(v, v) end
		out[#out + 1] = letter(262144) .. letter(4096) .. (b and letter(64) or "") .. (c and letter(1) or "")
	end
	return table.concat(out)
end

local function fromLetters(text)
	if text:find("[^%w%-_]") or #text % 4 == 1 then return nil end
	local out = {}
	for i = 1, #text, 4 do
		local a, b, c, d = text:byte(i, i + 3)
		local n = VALUE[a] * 262144 + VALUE[b] * 4096 + (c and VALUE[c] or 0) * 64 + (d and VALUE[d] or 0)
		out[#out + 1] = string.char(math.floor(n / 65536) % 256) .. (c and string.char(math.floor(n / 256) % 256) or "")
			.. (d and string.char(n % 256) or "")
	end
	return table.concat(out)
end

local function sum(data)
	local a, b = 0, 0
	for i = 1, #data do
		a = (a + data:byte(i)) % 255
		b = (b + a) % 255
	end
	return ("%02x%02x"):format(a, b)
end

-- Writes a value: N<number>; S<length>:<text> T F Z(nothing) [<values>]
-- A list says how long it is in `n`, so nothing in it is lost to a gap.
local function write(value, out)
	local kind = type(value)
	if kind == "number" then
		out[#out + 1] = "N" .. tostring(value) .. ";"
	elseif kind == "string" then
		out[#out + 1] = "S" .. #value .. ":" .. value
	elseif kind == "boolean" then
		out[#out + 1] = value and "T" or "F"
	elseif kind == "table" then
		out[#out + 1] = "["
		for i = 1, value.n or #value do write(value[i], out) end
		out[#out + 1] = "]"
	else
		out[#out + 1] = "Z"
	end
end

local function list(...)
	return { n = select("#", ...), ... }
end

local function packCondition(c)
	if c == nil then return nil end
	local out = { n = table.maxn(c), c[1] }
	for i = 2, out.n do
		local part = c[i]
		if type(part) ~= "table" then
			out[i] = part
		elseif type(part[1]) == "string" then
			out[i] = packCondition(part)
		else
			out[i] = list(part[1], part[2]) -- a spell: its ID and its English name
		end
	end
	return out
end

-- The rotation { class, spec, stance, title, rules } as a string to share.
function Edit.Encode(rotation)
	local rules = { n = #rotation.rules }
	for i, rule in ipairs(rotation.rules) do
		local flags = (rule.toggle and TOGGLE or 0) + (rule.react and REACT or 0) + (rule.off and OFF or 0)
		rules[i] = list(rule.spell[1], rule.spell[2], packCondition(rule.when), rule.note, flags)
	end
	local out = {}
	write(list(FORMAT, rotation.class, rotation.spec or 0, rotation.stance or 0, rotation.title, rules), out)
	local payload = toLetters(table.concat(out))
	return ("%s%d:%s:%s"):format(PREFIX, FORMAT, payload, sum(payload))
end

-- Reads the notation back into lists, or fails with a word on why. Bounded:
-- no deeper than 24 lists, no more than 6000 values, no text over 400 bytes.
local function read(text)
	local at, values = 1, 0
	local function value(depth)
		values = values + 1
		if depth > 24 or values > 6000 then error("it is too deep or too long", 0) end
		local tag = text:sub(at, at)
		at = at + 1
		if tag == "N" then
			local stop = text:find(";", at, true)
			local n = stop and tonumber(text:sub(at, stop - 1))
			if not n or n ~= n or n == math.huge or n == -math.huge then error("a number in it is not a number", 0) end
			at = stop + 1
			return n
		elseif tag == "S" then
			local colon = text:find(":", at, true)
			local length = colon and tonumber(text:sub(at, colon - 1))
			if not length or length < 0 or length > 400 or length % 1 ~= 0 or colon + length > #text then error("a piece of text in it is cut short", 0) end
			at = colon + length + 1
			return text:sub(colon + 1, colon + length)
		elseif tag == "T" then
			return true
		elseif tag == "F" then
			return false
		elseif tag == "Z" then
			return nil
		elseif tag == "[" then
			local items = { n = 0 }
			while text:sub(at, at) ~= "]" do
				if at > #text then error("it is cut short", 0) end
				items.n = items.n + 1
				items[items.n] = value(depth + 1)
			end
			at = at + 1
			return items
		end
		error("it is not a rotation", 0)
	end
	local ok, result = pcall(value, 0)
	if not ok then return nil, result end
	if at <= #text then return nil, "there is something after its end" end
	return result
end

-- Text from a stranger, made safe to show: no control characters, none of
-- the game's own mark-up, not too long.
local function tidy(text, most)
	if type(text) ~= "string" then return nil end
	text = text:gsub("[%c|]", ""):sub(1, most)
	if text == "" then return nil end
	return text
end

local function unpackSpell(item)
	if type(item) ~= "table" or item.n ~= 2 then return nil end
	local id, name = item[1], tidy(item[2], 80)
	if id ~= nil and (type(id) ~= "number" or id < 1 or id % 1 ~= 0) then return nil end
	if not (id or name) then return nil end
	return { id, name }
end

local function unpackCondition(item, depth)
	if item == nil then return nil end
	if type(item) ~= "table" or type(item[1]) ~= "string" or depth > 12 then error("a condition in it is not understood", 0) end
	local op = item[1]
	local c = { op }
	if op == "and" or op == "or" or op == "not" or op == "maybe" then
		for i = 2, item.n do c[i] = unpackCondition(item[i], depth + 1) end
		return c
	end
	if not Rules.tests[op] then error(("it uses a test this version does not have (\"%s\"): it may come from a newer one"):format(tidy(op, 30) or "?"), 0) end
	for i = 2, math.min(item.n, 4) do
		local part = item[i]
		if type(part) == "table" then
			c[i] = unpackSpell(part) or error("a spell in it is not understood", 0)
		elseif type(part) == "number" or part == nil then
			c[i] = part
		else
			error("a condition in it is not understood", 0)
		end
	end
	return c
end

-- A shared string back into { class, spec, stance, title, rules }, or nil
-- and what is wrong with it. Nothing is kept or changed by this.
function Edit.Decode(text)
	if type(text) ~= "string" then return nil, "there is nothing to read" end
	text = text:gsub("%s+", "")
	if #text > 60000 then return nil, "it is far too long to be a rotation" end
	local format, payload, check = text:match("^" .. PREFIX .. "(%d+):([%w%-_]+):(%x%x%x%x)$")
	if not format then return nil, "that is not a Polestar Next rotation string" end
	if tonumber(format) ~= FORMAT then return nil, "it was made with a newer version of Polestar Next" end
	if sum(payload) ~= check:lower() then return nil, "it is damaged or cut short: copy the whole string again" end
	local data = fromLetters(payload)
	if not data then return nil, "it is damaged: copy the whole string again" end
	local root, why = read(data)
	if not root then return nil, why end
	if type(root) ~= "table" or root.n ~= 6 or root[1] ~= FORMAT then return nil, "it is not a rotation" end
	local class, spec, stance, rules = root[2], root[3], root[4], root[6]
	if type(class) ~= "string" or not Engine.SPECS[class] then return nil, "it does not say which class it is for" end
	if type(spec) ~= "number" or spec < 0 or spec > 3 or spec % 1 ~= 0 or type(stance) ~= "number" or stance < 0 or stance > 9 or stance % 1 ~= 0 then
		return nil, "it does not say which talent tree and stance it is for"
	end
	if type(rules) ~= "table" or rules.n < 1 or rules.n > 80 then return nil, "it has no abilities in it, or too many" end
	local out = {}
	local ok, problem = pcall(function()
		for i = 1, rules.n do
			local item = rules[i]
			if type(item) ~= "table" or item.n ~= 5 then error("an ability in it is not understood", 0) end
			local spell = unpackSpell(list(item[1], item[2])) or error("an ability in it has no spell", 0)
			local flags = type(item[5]) == "number" and item[5] or 0
			out[i] = {
				spell = spell, when = unpackCondition(item[3], 0), note = tidy(item[4], 120),
				toggle = flags % 2 >= 1 or nil, react = flags % 4 >= 2 or nil, off = flags % 8 >= 4 or nil,
			}
		end
	end)
	if not ok then return nil, problem end
	local bad = Engine.Lint(out)
	if bad then return nil, "it does not hold together: " .. bad end
	return { class = class, spec = spec, stance = stance, title = tidy(root[5], 80), rules = out }
end

-- The rotation the editor is on, as a string to share.
function Edit.Export()
	local spec, stance = Edit.spec or Scan.spec or 0, Edit.stance or Scan.stance or 0
	return Edit.Encode({ class = Scan.class, spec = spec, stance = stance, title = Engine.Title(spec, stance), rules = Edit.Current() })
end

-- Takes a shared string in as the player's version of the rotation it was
-- made for (its own tree and stance), or of the one the editor is on when
-- `here`. Returns whether it did, and what to tell the player. The version
-- it replaces, if there was one, is kept aside (Edit.Restore).
function Edit.Import(text, here)
	local rotation, why = Edit.Decode(text)
	if not rotation then return false, why end
	if not (ns.db and Scan.class) then return false, "no character yet" end
	if rotation.class ~= Scan.class then
		return false, ("that rotation is for a %s; this character is a %s"):format(rotation.class:lower(), Scan.class:lower())
	end
	local spec, stance = rotation.spec, rotation.stance
	if here then spec, stance = Edit.spec or Scan.spec or 0, Edit.stance or Scan.stance or 0 end
	local key = Engine.Key(spec, stance)
	local db = ns.db
	db.lists, db.edited, db.replaced = db.lists or {}, db.edited or {}, db.replaced or {}
	db.replaced[key] = Engine.Own(key)
	remember(snapshot(key), key)
	for _, rule in ipairs(rotation.rules) do rule.mine = true end
	db.lists[key], db.edited[key] = rotation.rules, true
	built[key] = nil
	if not here then Edit.Pick(spec, stance) end
	if Edit.InUse() then Edit.Pick() end
	Engine.Rebuild()
	return true, ("%d abilities taken in as your %s rotation%s."):format(#rotation.rules, Engine.Title(spec, stance),
		db.replaced[key] and " (the one it replaced is kept: /pnext restore)" or "")
end

-- Puts back the player's version an import replaced, for the rotation the
-- editor is on. Returns whether there was one.
function Edit.Restore()
	local key = Edit.Key()
	local kept = ns.db and ns.db.replaced and ns.db.replaced[key]
	if not kept then return false end
	ns.db.lists[key], ns.db.replaced[key] = kept, nil
	Engine.Rebuild()
	return true
end

---------------------------------------------------------------------------
-- The preview: what the rotation shown would do in a fight that started
-- now, on paper (Engine.Preview). The player sets how many enemies there are
-- and how fast the bar fills; both are kept for the character.
---------------------------------------------------------------------------

local SPAN = 30

-- By the kind of bar: what it starts at (full when not given), how fast it
-- fills unless the player says otherwise, and the stepper's step and limit.
local BARS = {
	rage = { start = 0, income = 5, step = 1, most = 30 },
	energy = { income = 10, step = 5, most = 40, pause = 1 },
	focus = { income = 5, step = 1, most = 30 },
	mana = { income = 0, step = 5, most = 200 },
	power = { income = 0, step = 1, most = 50 },
}

-- A druid's forms by the client's form number, and the bar each fights with.
local FORMS = {
	[1] = { { 768, "Cat Form" }, "energy" }, [5] = { { 5487, "Bear Form" }, "rage" }, [8] = { { 9634, "Dire Bear Form" }, "rage" },
	[31] = { { 24858, "Moonkin Form" }, "mana" },
}

function Edit.PreviewOptions()
	local name = Engine.PowerName()
	local ceiling = ns.num((ns.call(UnitPowerMax, "player"))) or 100
	local stance = Edit.stance or Scan.stance or 0
	-- A druid's rotation is played in the form it is for, with that form's bar.
	local form
	if Scan.class == "DRUID" then
		form = 0
		local standing = Scan.stances[stance]
		for id, entry in pairs(FORMS) do
			if standing and standing == ns.SpellName(entry[1]) then form = id end
		end
		local wanted = form == 0 and "mana" or FORMS[form][2]
		if wanted ~= name then name, ceiling = wanted, wanted == "mana" and ceiling or 100 end
	end
	local bar = BARS[name] or BARS.power
	local kept = ns.db and ns.db.preview or {}
	return {
		seconds = SPAN, bar = name, ceiling = ceiling,
		power = bar.start or ceiling,
		income = (type(kept.income) == "table" and tonumber(kept.income[name])) or bar.income,
		enemies = tonumber(kept.enemies) or 1,
		stance = stance > 0 and stance or nil,
		form = form, pause = bar.pause,
		-- A hunter's fight on paper is fought at range.
		melee = Scan.class ~= "HUNTER",
		inUse = Edit.InUse(),
	}
end

-- One step up or down for "enemies" or "income".
function Edit.StepPreview(what, by)
	local db = ns.db
	if not db then return end
	db.preview = type(db.preview) == "table" and db.preview or {}
	local now = Edit.PreviewOptions()
	if what == "enemies" then
		db.preview.enemies = math.max(1, math.min(10, now.enemies + by))
	else
		local bar = BARS[now.bar] or BARS.power
		db.preview.income = type(db.preview.income) == "table" and db.preview.income or {}
		db.preview.income[now.bar] = math.max(0, math.min(bar.most, now.income + by * bar.step))
	end
end

-- The rotation the editor is on, played out.
function Edit.Preview()
	local list = Edit.Current()
	if not list then return nil end
	return Engine.Preview(list, Edit.PreviewOptions())
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local RULES, PARTS, RULE_H, PART_H = 14, 12, 26, 24
local LEFT, RIGHT, TOP = 14, 418, -78
local window, ruleRows, partRows, menu
local header, status, treeButton, stanceButton, followButton, badge, resetButton, notesText, undoButton, redoButton, picker, updateButton
local summary, presets
local selected, ruleScroll, partScroll, dragging, sinceLive = 1, 0, 0, nil, 0
local openPicker
-- Where the buttons under the lists sit, above the preview.
local BAR = 170

local function button(parent, text, width)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	return b
end

local function say(text)
	if status then status:SetText(text or "") end
end

local refresh

-- Runs one edit on the selected rule's condition, then makes it count.
local function change(edit, ...)
	say(Edit.Change(selected, edit, ...))
	refresh()
end

-- The menu of tests, opened from a test's words.
local function openMenu(anchor, path)
	if not menu then
		menu = CreateFrame("Frame", nil, window)
		menu:SetFrameStrata("FULLSCREEN_DIALOG")
		menu:SetSize(2 * 250 + 12, math.ceil(#Edit.TESTS / 2) * 20 + 12)
		menu:EnableMouse(true)
		UI.Panel(menu, 0.97)
		menu.items = {}
		local rows = math.ceil(#Edit.TESTS / 2)
		for i, entry in ipairs(Edit.TESTS) do
			local item = CreateFrame("Button", nil, menu)
			item:SetSize(250, 20)
			item:SetPoint("TOPLEFT", 6 + (i > rows and 250 or 0), -6 - ((i - 1) % rows) * 20)
			item.glow = item:CreateTexture(nil, "BACKGROUND")
			item.glow:SetAllPoints()
			item.glow:SetColorTexture(1, 0.82, 0, 0)
			item.text = UI.Text(item, 11)
			item.text:SetPoint("LEFT", 6, 0)
			item.text:SetText(entry[3] .. (entry[2] and " ..." or ""))
			item:SetScript("OnEnter", function() item.glow:SetColorTexture(1, 0.82, 0, 0.22) end)
			item:SetScript("OnLeave", function() item.glow:SetColorTexture(1, 0.82, 0, 0) end)
			item:SetScript("OnClick", function()
				menu:Hide()
				change(Edit.SetTest, menu.path, entry[1])
			end)
			menu.items[i] = item
		end
	end
	if menu:IsShown() and menu.anchor == anchor then
		menu:Hide()
		return
	end
	menu.path, menu.anchor = path, anchor
	menu:ClearAllPoints()
	menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
	menu:Show()
end

-- The spell picker: the character's spells with their icons, narrowed as
-- the player types. A click adds one after the selected ability; Enter adds
-- the first shown, or what was typed when nothing matches (a spell not
-- learned yet).
local PICKS = 12
local pickScroll = 0

local function fillPicker()
	local spells = Edit.Spells(picker.search:GetText() or "")
	local have = {}
	for _, rule in ipairs(Edit.Current() or {}) do have[ns.SpellName(rule.spell) or ""] = true end
	pickScroll = math.max(0, math.min(math.max(0, #spells - PICKS), pickScroll))
	picker.spells = spells
	for i, row in ipairs(picker.rows) do
		local spell = spells[i + pickScroll]
		row.spell = spell
		row:SetShown(spell ~= nil)
		if spell then
			row.icon:SetTexture(UI.Icon(spell.id))
			row.text:SetText(spell.name .. (have[spell.name] and "  |cff808080in the rotation|r" or ""))
		end
	end
	picker.none:SetShown(#spells == 0)
end

local function pick(name)
	if not name or name == "" then return end
	say(Edit.AddRule(name, selected))
	selected = math.min(selected + 1, #(Edit.Current() or {}))
	picker:Hide()
	refresh()
end

openPicker = function(anchor)
	if not picker then
		picker = CreateFrame("Frame", nil, window)
		picker:SetFrameStrata("FULLSCREEN_DIALOG")
		picker:SetSize(300, 46 + PICKS * 24)
		picker:EnableMouse(true)
		picker:EnableMouseWheel(true)
		UI.Panel(picker, 0.98)
		picker.search = CreateFrame("EditBox", nil, picker, "InputBoxTemplate")
		picker.search:SetSize(270, 20)
		picker.search:SetPoint("TOPLEFT", 16, -10)
		picker.search:SetAutoFocus(false)
		picker.search:SetScript("OnTextChanged", function()
			pickScroll = 0
			fillPicker()
		end)
		picker.search:SetScript("OnEnterPressed", function(self)
			local first = picker.spells and picker.spells[1]
			pick(first and first.name or self:GetText())
		end)
		picker.search:SetScript("OnEscapePressed", function() picker:Hide() end)
		picker.none = UI.Text(picker, 11)
		picker.none:SetPoint("TOPLEFT", 12, -44)
		picker.none:SetTextColor(0.6, 0.6, 0.6)
		picker.none:SetText("No spell of yours has that in its name. Enter adds it anyway.")
		picker.none:SetWidth(276)
		picker.none:SetWordWrap(true)
		picker.rows = {}
		for i = 1, PICKS do
			local row = CreateFrame("Button", nil, picker)
			row:SetSize(288, 24)
			row:SetPoint("TOPLEFT", 6, -38 - (i - 1) * 24)
			row.glow = row:CreateTexture(nil, "BACKGROUND")
			row.glow:SetAllPoints()
			row.glow:SetColorTexture(1, 0.82, 0, 0)
			row.icon = row:CreateTexture(nil, "ARTWORK")
			row.icon:SetSize(20, 20)
			row.icon:SetPoint("LEFT", 4, 0)
			row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			row.text = UI.Text(row, 12)
			row.text:SetPoint("LEFT", 30, 0)
			row:SetScript("OnEnter", function() row.glow:SetColorTexture(1, 0.82, 0, 0.22) end)
			row:SetScript("OnLeave", function() row.glow:SetColorTexture(1, 0.82, 0, 0) end)
			row:SetScript("OnClick", function() if row.spell then pick(row.spell.name) end end)
			picker.rows[i] = row
		end
		picker:SetScript("OnMouseWheel", function(_, delta)
			pickScroll = pickScroll - delta
			fillPicker()
		end)
		picker:Hide()
	end
	if picker:IsShown() then
		picker:Hide()
		return
	end
	picker:ClearAllPoints()
	picker:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", -60, 4)
	picker.search:SetText("")
	pickScroll = 0
	picker:Show()
	fillPicker()
	picker.search:SetFocus()
end
Edit.OpenPicker = function() openPicker(window) end

-- The box for sharing: a string to copy out, or one to paste in.
local box

local function openBox(mode)
	if not box then
		box = CreateFrame("Frame", nil, window)
		box:SetFrameStrata("FULLSCREEN_DIALOG")
		box:SetSize(660, 168)
		box:SetPoint("CENTER")
		box:EnableMouse(true)
		UI.Panel(box, 0.98)
		box.title = UI.Text(box, 14)
		box.title:SetPoint("TOPLEFT", 16, -12)
		box.title:SetTextColor(1, 0.82, 0)
		box.edit = CreateFrame("EditBox", nil, box, "InputBoxTemplate")
		box.edit:SetSize(622, 22)
		box.edit:SetPoint("TOPLEFT", 20, -40)
		box.edit:SetAutoFocus(false)
		box.edit:SetMaxLetters(0)
		box.hint = UI.Text(box, 11)
		box.hint:SetPoint("TOPLEFT", 16, -70)
		box.hint:SetPoint("RIGHT", -16, 0)
		box.hint:SetWordWrap(true)
		box.hint:SetTextColor(0.75, 0.75, 0.75)
		box.result = UI.Text(box, 11)
		box.result:SetPoint("BOTTOMLEFT", 16, 42)
		box.result:SetPoint("RIGHT", -16, 0)
		box.go = button(box, "Import", 110)
		box.go:SetPoint("BOTTOMLEFT", 16, 12)
		box.here = button(box, "Import into the one shown", 210)
		box.here:SetPoint("LEFT", box.go, "RIGHT", 6, 0)
		local close = button(box, "Close", 70)
		close:SetPoint("BOTTOMRIGHT", -16, 12)
		close:SetScript("OnClick", function() box:Hide() end)
		local function take(here)
			local ok, message = Edit.Import(box.edit:GetText(), here)
			box.result:SetText(message or "")
			if ok then box.result:SetTextColor(UI.GREEN[1], UI.GREEN[2], UI.GREEN[3]) else box.result:SetTextColor(UI.RED[1], UI.RED[2], UI.RED[3]) end
			if ok then
				selected, ruleScroll, partScroll = 1, 0, 0
				box.edit:SetText("")
				refresh()
			end
		end
		box.go:SetScript("OnClick", function() take(false) end)
		box.here:SetScript("OnClick", function() take(true) end)
		box.edit:SetScript("OnEnterPressed", function() if box.mode == "import" then take(false) end end)
		box.edit:SetScript("OnEscapePressed", function() box:Hide() end)
	end
	box.mode = mode
	box.result:SetText("")
	if mode == "share" then
		local text = Edit.Export()
		box.title:SetText("Share this rotation")
		box.edit:SetText(text)
		box.hint:SetText(("It is selected for you: press Ctrl+C to copy it, then paste it wherever you like. %d characters; it holds your %s rotation, %d abilities, for a %s.")
			:format(#text, Engine.Title(Edit.spec, Edit.stance), #(Edit.Current() or {}), (Scan.class or "?"):lower()))
		box.go:Hide()
		box.here:Hide()
	else
		box.title:SetText("Import a rotation")
		box.edit:SetText("")
		box.hint:SetText("Paste a rotation string (Ctrl+V), then Import. It goes in as the rotation it was made for, say Fury in Berserker Stance, "
			.. "or into the one shown if you ask. It is read as plain data and checked first; nothing in it can run.")
		box.go:Show()
		box.here:Show()
	end
	box:Show()
	box.edit:SetFocus()
	if mode == "share" then box.edit:HighlightText() end
end

local function createRuleRow(i)
	local row = CreateFrame("Button", nil, window)
	row:SetSize(RIGHT - LEFT - 12, RULE_H)
	row:SetPoint("TOPLEFT", LEFT, TOP - (i - 1) * RULE_H)
	row.back = row:CreateTexture(nil, "BACKGROUND")
	row.back:SetAllPoints()
	-- A green bar marks the ability the icon is showing right now.
	row.now = row:CreateTexture(nil, "ARTWORK")
	row.now:SetPoint("TOPLEFT")
	row.now:SetPoint("BOTTOMLEFT")
	row.now:SetWidth(3)
	row.now:SetColorTexture(UI.GREEN[1], UI.GREEN[2], UI.GREEN[3], 1)
	row.number = UI.Text(row, 11)
	-- The switch: gold when the ability is on, hollow when it is off.
	row.switch = CreateFrame("Button", nil, row)
	row.switch:SetSize(12, 12)
	row.switch:SetPoint("LEFT", 8, 0)
	row.switch.fill = row.switch:CreateTexture(nil, "ARTWORK")
	row.switch.fill:SetAllPoints()
	UI.Edge(row.switch, 1, 0.82, 0, 0.8)
	row.switch:SetScript("OnClick", function()
		say(Edit.ToggleRule(row.index))
		refresh()
	end)
	row.number:SetPoint("LEFT", 26, 0)
	row.number:SetWidth(20)
	row.number:SetTextColor(0.6, 0.6, 0.6)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(20, 20)
	row.icon:SetPoint("LEFT", 48, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.remove = button(row, "x", 22)
	row.remove:SetPoint("RIGHT", -2, 0)
	row.remove:SetScript("OnClick", function()
		say(Edit.RemoveRule(row.index))
		refresh()
	end)
	row.state = UI.Text(row, 10)
	row.state:SetPoint("RIGHT", row.remove, "LEFT", -6, 0)
	row.state:SetJustifyH("RIGHT")
	row.text = UI.Text(row, 12)
	row.text:SetPoint("LEFT", 74, 0)
	row.text:SetPoint("RIGHT", row.state, "LEFT", -6, 0)
	row:SetScript("OnClick", function()
		selected, partScroll = row.index, 0
		if menu then menu:Hide() end
		refresh()
	end)
	-- Drag a row onto another to move it there.
	row:RegisterForDrag("LeftButton")
	row:SetScript("OnDragStart", function() dragging = row.index end)
	row:SetScript("OnDragStop", function()
		local from = dragging
		dragging = nil
		if not from then return end
		local _, y = GetCursorPosition()
		local top = ruleRows[1]:GetTop()
		local scale = window:GetEffectiveScale()
		if not (y and top and scale and scale > 0) then return end
		local to = math.floor((top - y / scale) / RULE_H) + 1 + ruleScroll
		say(Edit.Move(from, to))
		selected = math.max(1, math.min(#Edit.Current(), to))
		refresh()
	end)
	return row
end

-- The menu of ready-made conditions for the selected ability.
local function openPresets(anchor)
	if not presets then
		presets = CreateFrame("Frame", nil, window)
		presets:SetFrameStrata("FULLSCREEN_DIALOG")
		presets:SetSize(340, #Edit.PRESETS * 20 + 34)
		presets:EnableMouse(true)
		UI.Panel(presets, 0.97)
		local hint = UI.Text(presets, 10)
		hint:SetPoint("TOPLEFT", 10, -8)
		hint:SetTextColor(0.6, 0.6, 0.6)
		hint:SetText("Added to what the ability already asks. Undo takes it back.")
		presets.items = {}
		for i in ipairs(Edit.PRESETS) do
			local item = CreateFrame("Button", nil, presets)
			item:SetSize(328, 20)
			item:SetPoint("TOPLEFT", 6, -26 - (i - 1) * 20)
			item.glow = item:CreateTexture(nil, "BACKGROUND")
			item.glow:SetAllPoints()
			item.glow:SetColorTexture(1, 0.82, 0, 0)
			item.text = UI.Text(item, 11)
			item.text:SetPoint("LEFT", 6, 0)
			item:SetScript("OnEnter", function() item.glow:SetColorTexture(1, 0.82, 0, 0.22) end)
			item:SetScript("OnLeave", function() item.glow:SetColorTexture(1, 0.82, 0, 0) end)
			item:SetScript("OnClick", function()
				presets:Hide()
				change(Edit.AddPreset, i)
			end)
			presets.items[i] = item
		end
		presets:Hide()
	end
	if presets:IsShown() then
		presets:Hide()
		return
	end
	-- The names follow the character: "rage to spare" for a warrior.
	for i, item in ipairs(presets.items) do item.text:SetText(Edit.PresetName(i)) end
	presets:ClearAllPoints()
	presets:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
	presets:Show()
end
Edit.OpenPresets = function() openPresets(window) end

local function createPartRow(i)
	local row = CreateFrame("Frame", nil, window)
	row:SetSize(428, PART_H)
	row:SetPoint("TOPLEFT", RIGHT, TOP - 68 - (i - 1) * PART_H)
	row.back = row:CreateTexture(nil, "BACKGROUND")
	row.back:SetAllPoints()
	-- Click a test's words for the menu of tests; a group's to switch it
	-- between ALL and ANY.
	row.label = CreateFrame("Button", nil, row)
	row.label:SetHeight(PART_H)
	row.label.text = UI.Text(row.label, 11)
	row.label.text:SetAllPoints()
	row.label:SetScript("OnClick", function()
		if not row.path then return end
		if row.group then
			change(Edit.ToggleGroup, row.path)
		elseif row.test then
			openMenu(row.label, row.path)
		end
	end)
	row.value = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	row.value:SetSize(110, 18)
	row.value:SetAutoFocus(false)
	row.value:SetScript("OnEnterPressed", function(box)
		box:ClearFocus()
		if row.path then change(Edit.SetValue, row.path, box:GetText()) end
	end)
	row.value:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
	row.remove = button(row, "x", 22)
	row.remove:SetPoint("RIGHT", 0, 0)
	row.remove:SetScript("OnClick", function() if row.path then change(Edit.RemovePart, row.path) end end)
	row.negate = button(row, "not", 36)
	row.negate:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
	row.negate:SetScript("OnClick", function() if row.path then change(Edit.ToggleNot, row.path) end end)
	row.add = button(row, "+", 22)
	row.add:SetPoint("RIGHT", row.negate, "LEFT", -2, 0)
	row.add:SetScript("OnClick", function() if row.path then change(Edit.AddPart, row.path) end end)
	row.value:SetPoint("RIGHT", row.add, "LEFT", -6, 0)
	return row
end

-- The words down the right of each ability: what it is doing this moment.
-- Only the rotation in use has a moment to speak of.
local function live()
	if not window then return end
	local list = Edit.Current() or {}
	local now
	if Edit.InUse() then now = Engine.Suggest() end
	for _, row in ipairs(ruleRows) do
		local rule = list[row.index or 0]
		if rule then
			local state = Engine.State(rule.spell)
			local words = rule.off and "off" or "not learned"
			if state.known then words = Edit.InUse() and (rule == now and "now" or Engine.Why(rule)) or "" end
			row.state:SetText(words)
			if rule == now then row.state:SetTextColor(UI.GREEN[1], UI.GREEN[2], UI.GREEN[3]) else row.state:SetTextColor(0.55, 0.55, 0.55) end
			row.now:SetShown(rule == now)
		end
	end
end

---------------------------------------------------------------------------
-- The preview band along the bottom: time runs left to right. The big icons
-- are the presses, one a global cooldown; the small ones above them are what
-- goes beside a press without taking its place; the bars under the line are
-- the effects the rotation keeps up.
---------------------------------------------------------------------------

local band
local TRACK_X, TRACK_W = 118, 700
local LANES = 2

local function across(seconds)
	return TRACK_X + math.max(0, math.min(SPAN, seconds)) / SPAN * TRACK_W
end

local function previewIcon(pool, i, size)
	local icon = pool[i]
	if not icon then
		icon = CreateFrame("Button", nil, band)
		icon:SetSize(size, size)
		icon.tex = icon:CreateTexture(nil, "ARTWORK")
		icon.tex:SetAllPoints()
		icon.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		icon.edge = UI.Edge(icon, 1, 1, 1, 0.3)
		-- A cast or a channel: a line from the icon for as long as it takes.
		icon.long = band:CreateTexture(nil, "ARTWORK")
		icon.long:SetColorTexture(0.5, 0.72, 1, 0.9)
		icon:SetScript("OnEnter", function() band.title:SetText(icon.words or "") end)
		icon:SetScript("OnLeave", function() band.title:SetText(band.words or "") end)
		-- A click goes to the ability in the list.
		icon:SetScript("OnClick", function()
			if not icon.index then return end
			selected, partScroll = icon.index, 0
			if selected <= ruleScroll or selected > ruleScroll + RULES then ruleScroll = math.max(0, selected - 3) end
			refresh()
		end)
		pool[i] = icon
	end
	return icon
end

local function stepper(parent, what)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(170, 18)
	local less, more = button(holder, "-", 20), button(holder, "+", 20)
	less:SetHeight(18)
	more:SetHeight(18)
	less:SetPoint("LEFT")
	more:SetPoint("RIGHT")
	holder.text = UI.Text(holder, 11)
	holder.text:SetPoint("LEFT", less, "RIGHT", 4, 0)
	holder.text:SetPoint("RIGHT", more, "LEFT", -4, 0)
	holder.text:SetJustifyH("CENTER")
	less:SetScript("OnClick", function()
		Edit.StepPreview(what, -1)
		refresh()
	end)
	more:SetScript("OnClick", function()
		Edit.StepPreview(what, 1)
		refresh()
	end)
	return holder
end

local function createBand()
	band = CreateFrame("Frame", nil, window)
	band:SetPoint("BOTTOMLEFT", LEFT, 40)
	band:SetPoint("BOTTOMRIGHT", -14, 40)
	band:SetHeight(104)
	local fill = band:CreateTexture(nil, "BACKGROUND")
	fill:SetAllPoints()
	fill:SetColorTexture(1, 1, 1, 0.04)
	band.title = UI.Text(band, 11)
	band.title:SetPoint("TOPLEFT", 6, -5)
	band.title:SetTextColor(0.8, 0.8, 0.8)
	band.enemies = stepper(band, "enemies")
	band.enemies:SetWidth(120)
	band.enemies:SetPoint("TOPRIGHT", -6, -2)
	band.income = stepper(band, "income")
	band.income:SetPoint("RIGHT", band.enemies, "LEFT", -10, 0)

	local function label(text, y)
		local words = UI.Text(band, 9)
		words:SetPoint("TOPLEFT", 6, y)
		words:SetTextColor(0.55, 0.55, 0.55)
		words:SetText(text)
		return words
	end
	label("beside a press", -26)
	label("one press each", -47)

	-- The line of time, with a tick every five seconds.
	local line = band:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(1, 1, 1, 0.25)
	line:SetSize(TRACK_W, 1)
	line:SetPoint("TOPLEFT", TRACK_X, -68)
	for second = 0, SPAN, 5 do
		local tick = band:CreateTexture(nil, "ARTWORK")
		tick:SetColorTexture(1, 1, 1, 0.25)
		tick:SetSize(1, 4)
		tick:SetPoint("TOPLEFT", across(second), -68)
		local words = UI.Text(band, 9)
		words:SetPoint("TOPLEFT", across(second) + 3, -70)
		words:SetTextColor(0.55, 0.55, 0.55)
		words:SetText(second .. "s")
	end

	band.main, band.free, band.lanes = {}, {}, {}
	for i = 1, LANES do
		local lane = { label = label("", -68 - i * 12 + 1), bars = {} }
		lane.label:SetWidth(TRACK_X - 10)
		lane.full = band:CreateTexture(nil, "OVERLAY")
		lane.full:SetColorTexture(1, 0.82, 0, 1)
		lane.full:SetSize(2, 10)
		band.lanes[i] = lane
	end
	band.empty = UI.Text(band, 11)
	band.empty:SetPoint("TOPLEFT", TRACK_X, -44)
	band.empty:SetTextColor(0.6, 0.6, 0.6)
	band.empty:SetText("Nothing to press: no ability of this rotation that you have learned fits the start of a fight.")
end

local function drawPreview()
	if not band then return end
	local options, preview = Edit.PreviewOptions(), Edit.Preview()
	local steps = preview and preview.steps or {}
	band.enemies.text:SetText(options.enemies == 1 and "1 enemy" or (options.enemies .. " enemies"))
	band.income.text:SetText(("%d %s a second"):format(options.income, options.bar))
	band.income:SetShown(options.bar ~= "power")

	local presses, beside, lastBeside = 0, 0, -100
	for _, step in ipairs(steps) do
		local icon, x = nil, across(step.at)
		if step.free then
			beside = beside + 1
			icon = previewIcon(band.free, beside, 16)
			-- Several at one moment sit side by side.
			x = math.max(x, lastBeside + 17)
			lastBeside = x
			icon:ClearAllPoints()
			icon:SetPoint("TOPLEFT", x, -22)
		else
			presses = presses + 1
			icon = previewIcon(band.main, presses, 22)
			icon:ClearAllPoints()
			icon:SetPoint("TOPLEFT", x, -42)
		end
		icon.index = step.index
		icon.tex:SetTexture(UI.Icon(step.state.id or step.rule.spell[1]))
		if step.index == selected then icon.edge(1, 0.82, 0, 1) else icon.edge(1, 1, 1, 0.3) end
		local put, what = step.puts, ""
		if put and put.cap and put.cap > 1 then
			what = ("  (stack %d of %d)"):format(put.stacks or 1, put.cap)
		elseif put then
			what = ("  (on until %.0fs)"):format(put.to)
		end
		local long = math.max(step.cast or 0, step.channel or 0)
		if long > 0 then what = ("  (%.1fs %s)"):format(long, step.channel and "channel" or "cast") .. what end
		icon.long:SetShown(long > 0 and not step.free)
		if long > 0 and not step.free then
			icon.long:ClearAllPoints()
			icon.long:SetPoint("TOPLEFT", x, -65)
			icon.long:SetSize(math.max(2, across(step.at + long) - x), 2)
		end
		icon.words = ("|cffffd100%.1fs|r  %s%s%s%s%s"):format(step.at, step.state.name or "?", what,
			step.power and ("  ·  %d %s after it"):format(step.power, options.bar) or "",
			step.combo and ("  ·  %d combo point%s"):format(step.combo, step.combo == 1 and "" or "s") or "",
			step.rule.note and ("  ·  |cff999999" .. step.rule.note .. "|r") or "")
		icon:Show()
	end
	for i = presses + 1, #band.main do
		band.main[i]:Hide()
		band.main[i].long:Hide()
	end
	for i = beside + 1, #band.free do
		band.free[i]:Hide()
		band.free[i].long:Hide()
	end

	-- The effects kept up: a bar for as long as each is on, a gold mark where
	-- one that stacks reached the top.
	local lanes = preview and preview.lanes or {}
	for i, lane in ipairs(band.lanes) do
		local kept, bars = lanes[i], 0
		lane.label:SetText(kept and (kept.name .. (kept.cap > 1 and ("  x" .. kept.most) or "")) or "")
		for _, span in ipairs(kept and kept.spans or {}) do
			bars = bars + 1
			local bar = lane.bars[bars]
			if not bar then
				bar = band:CreateTexture(nil, "ARTWORK")
				lane.bars[bars] = bar
			end
			if kept.unit == "player" then bar:SetColorTexture(0.45, 0.85, 0.5, 0.7) else bar:SetColorTexture(0.9, 0.4, 0.33, 0.75) end
			bar:ClearAllPoints()
			bar:SetPoint("TOPLEFT", across(span.from), -68 - i * 12)
			bar:SetSize(math.max(2, across(span.to) - across(span.from)), 8)
			bar:Show()
		end
		for j = bars + 1, #lane.bars do lane.bars[j]:Hide() end
		lane.full:SetShown(kept ~= nil and kept.cap > 1 and kept.full ~= nil)
		if kept and kept.full then
			lane.full:ClearAllPoints()
			lane.full:SetPoint("TOPLEFT", across(kept.full), -67 - i * 12)
		end
	end

	band.empty:SetShown(#steps == 0)
	band.words = ("The first %d seconds of a fight, on paper: %d presses, %d beside them. Point at one for the detail; click it to go to it. Reactions are left out.")
		:format(SPAN, presses, beside)
	band.title:SetText(band.words)
end
Edit.DrawPreview = drawPreview

refresh = function()
	if not window then return end
	local list = Edit.Current() or {}
	local own = Engine.Own(Edit.Key()) ~= nil
	selected = math.max(1, math.min(#list, selected))
	ruleScroll = math.max(0, math.min(math.max(0, #list - RULES), ruleScroll))

	-- Which rotation, and whose.
	local trees = Engine.SPECS[Scan.class or ""] or {}
	local spec, stance = Edit.spec or Scan.spec or 0, Edit.stance or Scan.stance or 0
	treeButton:SetText("Tree: " .. (trees[spec] or "none yet"))
	stanceButton:SetText("Stance: " .. (Scan.stances[stance] or "none"))
	stanceButton:SetShown(#Scan.stances > 0)
	followButton:SetShown(not Edit.InUse())
	badge:SetText((Edit.InUse() and "|cff73d980in use now|r" or "|cff999999not the one in use|r")
		.. "    " .. (own and "|cffffd100your version|r" or "|cff999999built for your character|r"))
	resetButton:SetShown(own)
	local late = own and Edit.Behind() or 0
	updateButton:SetShown(late > 0)
	undoButton:SetEnabled(Edit.CanUndo())
	redoButton:SetEnabled(Edit.CanRedo())

	for i, row in ipairs(ruleRows) do
		local index = i + ruleScroll
		local rule = list[index]
		row.index = index
		row:SetShown(rule ~= nil)
		if rule then
			local state = Engine.State(rule.spell)
			row.number:SetText(index .. ".")
			row.icon:SetTexture(UI.Icon(state.id or rule.spell[1]))
			row.icon:SetDesaturated(not state.known)
			local key = state.key and ("  |cffffd100[" .. Scan.ShortKey(state.key) .. "]|r") or ""
			row.text:SetText((ns.SpellName(rule.spell) or "?") .. key)
			if state.known and not rule.off then row.text:SetTextColor(1, 1, 1) else row.text:SetTextColor(0.5, 0.5, 0.5) end
			if rule.off then row.switch.fill:SetColorTexture(0, 0, 0, 0.6) else row.switch.fill:SetColorTexture(1, 0.82, 0, 0.9) end
			if rule.off then row.icon:SetDesaturated(true) end
			if index == selected then row.back:SetColorTexture(1, 0.82, 0, 0.22) else row.back:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.045 or 0) end
		end
	end

	local rule = list[selected]
	local rows = rule and Edit.Rows(rule) or {}
	header:SetText(rule and ("Use |cffffd100%s|r when%s"):format(ns.SpellName(rule.spell) or "?", #rows == 0 and ":  always" or ":")
		or "No ability selected")
	summary:SetText(rule and Edit.Summary(rule) or "")
	partScroll = math.max(0, math.min(math.max(0, #rows - PARTS), partScroll))
	for i, row in ipairs(partRows) do
		local part = rows[i + partScroll]
		row.path = part and part.path or nil
		row:SetShown(part ~= nil)
		if part then
			local node = part.node
			local entry = Edit.TESTS[testIndex[node[1]] or 0]
			row.group, row.test = grouping(node), entry ~= nil
			row.back:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
			row.label:ClearAllPoints()
			row.label:SetPoint("LEFT", 6 + part.depth * 16, 0)
			row.label:SetWidth(math.max(60, 300 - part.depth * 16 - (entry and entry[2] and 116 or 0)))
			-- The value has its own box, so the words stop before it.
			local words = Edit.Label(node)
			if entry and entry[2] then words = entry[3] end
			row.label.text:SetText(words)
			if row.group or wrapping(node) then row.label.text:SetTextColor(1, 0.82, 0) else row.label.text:SetTextColor(1, 1, 1) end
			row.value:SetShown(entry ~= nil and entry[2] ~= nil)
			if entry and entry[2] == "spell" then row.value:SetText(ns.SpellName(node[2]) or "") end
			if entry and entry[2] == "number" then row.value:SetText(tostring(node[2] or "")) end
			-- NOT is switched off from the row it negates.
			row.negate:SetShown(node[1] ~= "not")
		end
	end

	-- Why the built rotation is the way it is.
	drawPreview()
	local _, notes = Edit.Built()
	notesText:SetText(own and ("This is your version: it is used exactly as it is here."
		.. (late > 0 and ("  |cffffd100The built rotation has moved on in %d places (new abilities, newer conditions).|r Update takes those in, and keeps your order and what you changed yourself.")
			:format(late) or ""))
		or table.concat(notes or {}, "  "))
	live()
end
Edit.Refresh = refresh

local function create()
	window = CreateFrame("Frame", "PolestarNextEditor", UIParent)
	window:SetSize(860, 652)
	window:SetPoint("CENTER")
	window:SetFrameStrata("DIALOG")
	window:SetMovable(true)
	window:EnableMouse(true)
	window:SetClampedToScreen(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", window.StopMovingOrSizing)
	UI.Panel(window, 0.95)

	-- The strip along the top: what this is, and which rotation.
	local strip = CreateFrame("Frame", nil, window)
	strip:SetPoint("TOPLEFT")
	strip:SetPoint("TOPRIGHT")
	strip:SetHeight(66)
	local stripFill = strip:CreateTexture(nil, "BACKGROUND")
	stripFill:SetAllPoints()
	stripFill:SetColorTexture(1, 1, 1, 0.05)
	local title = UI.Text(strip, 16)
	title:SetPoint("TOPLEFT", 14, -10)
	title:SetTextColor(1, 0.82, 0)
	title:SetText("Polestar Next  ·  rotations")
	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)
	close:SetScript("OnClick", function() window:Hide() end)

	treeButton = button(strip, "Tree", 170)
	treeButton:SetPoint("TOPLEFT", 14, -36)
	treeButton:SetScript("OnClick", function()
		Edit.Pick(((Edit.spec or Scan.spec or 0) + 1) % 4, Edit.stance or Scan.stance or 0)
		selected, ruleScroll, partScroll = 1, 0, 0
		refresh()
	end)
	stanceButton = button(strip, "Stance", 210)
	stanceButton:SetPoint("LEFT", treeButton, "RIGHT", 6, 0)
	stanceButton:SetScript("OnClick", function()
		Edit.Pick(Edit.spec or Scan.spec or 0, ((Edit.stance or Scan.stance or 0) + 1) % (#Scan.stances + 1))
		selected, ruleScroll, partScroll = 1, 0, 0
		refresh()
	end)
	followButton = button(strip, "Back to mine", 110)
	followButton:SetPoint("LEFT", stanceButton, "RIGHT", 6, 0)
	followButton:SetScript("OnClick", function()
		Edit.Pick()
		selected, ruleScroll, partScroll = 1, 0, 0
		refresh()
	end)
	badge = UI.Text(strip, 12)
	badge:SetPoint("LEFT", followButton, "RIGHT", 14, 0)
	undoButton, redoButton = button(strip, "Undo", 60), button(strip, "Redo", 60)
	redoButton:SetPoint("TOPRIGHT", -170, -36)
	undoButton:SetPoint("RIGHT", redoButton, "LEFT", -4, 0)
	undoButton:SetScript("OnClick", function()
		Edit.Undo()
		say("")
		refresh()
	end)
	redoButton:SetScript("OnClick", function()
		Edit.Redo()
		say("")
		refresh()
	end)
	local share = button(strip, "Share", 70)
	share:SetPoint("TOPRIGHT", -14, -36)
	share:SetScript("OnClick", function() openBox("share") end)
	local import = button(strip, "Import", 70)
	import:SetPoint("RIGHT", share, "LEFT", -4, 0)
	import:SetScript("OnClick", function() openBox("import") end)

	local hint = UI.Text(window, 10)
	hint:SetPoint("TOPRIGHT", -40, -14)
	hint:SetTextColor(0.6, 0.6, 0.6)
	hint:SetText("Most urgent first. Drag to reorder. Click a test to change it.")

	header = UI.Text(window, 13)
	header:SetPoint("TOPLEFT", RIGHT, TOP - 4)
	local ready = button(window, "Ready-made conditions...", 170)
	ready:SetPoint("TOPRIGHT", -14, TOP + 1)
	ready:SetScript("OnClick", function() openPresets(ready) end)
	-- The ability's condition in plain words, above the tests it is made of.
	summary = UI.Text(window, 11)
	summary:SetPoint("TOPLEFT", RIGHT, TOP - 26)
	summary:SetSize(428, 38)
	summary:SetWordWrap(true)
	summary:SetJustifyV("TOP")
	summary:SetTextColor(0.82, 0.82, 0.82)

	ruleRows, partRows = {}, {}
	for i = 1, RULES do ruleRows[i] = createRuleRow(i) end
	for i = 1, PARTS do partRows[i] = createPartRow(i) end

	window:EnableMouseWheel(true)
	window:SetScript("OnMouseWheel", function(_, delta)
		-- Over the list the list scrolls, over the condition the condition.
		local x = GetCursorPosition()
		local scale = window:GetEffectiveScale()
		local left = window:GetLeft()
		if x and scale and left and x / scale - left > RIGHT - 6 then partScroll = partScroll - delta else ruleScroll = ruleScroll - delta end
		if menu then menu:Hide() end
		refresh()
	end)
	window:SetScript("OnUpdate", function(_, dt)
		sinceLive = sinceLive + dt
		if sinceLive < 0.3 then return end
		sinceLive = 0
		live()
	end)
	window:SetScript("OnHide", function()
		if menu then menu:Hide() end
		if box then box:Hide() end
		if picker then picker:Hide() end
		if presets then presets:Hide() end
	end)

	-- Under the list.
	local up, down = button(window, "Up", 50), button(window, "Down", 56)
	up:SetPoint("BOTTOMLEFT", LEFT, BAR)
	down:SetPoint("LEFT", up, "RIGHT", 4, 0)
	up:SetScript("OnClick", function()
		say(Edit.Move(selected, selected - 1))
		selected = selected - 1
		refresh()
	end)
	down:SetScript("OnClick", function()
		say(Edit.Move(selected, selected + 1))
		selected = selected + 1
		refresh()
	end)
	local again = button(window, "Duplicate", 84)
	again:SetPoint("LEFT", down, "RIGHT", 4, 0)
	again:SetScript("OnClick", function()
		say(Edit.Duplicate(selected))
		selected = selected + 1
		refresh()
	end)
	local add = button(window, "Add an ability...", 130)
	add:SetPoint("LEFT", again, "RIGHT", 4, 0)
	add:SetScript("OnClick", function() openPicker(add) end)

	-- Under the condition.
	local when = button(window, "Add a test", 96)
	when:SetPoint("BOTTOMLEFT", RIGHT, BAR)
	when:SetScript("OnClick", function() change(Edit.AddPart, {}) end)
	local any = button(window, "Add an ANY group", 130)
	any:SetPoint("LEFT", when, "RIGHT", 4, 0)
	any:SetScript("OnClick", function() change(Edit.AddPart, {}, { "or", { "target" } }) end)
	resetButton = button(window, "Use the built one", 130)
	resetButton:SetPoint("BOTTOMRIGHT", -14, BAR)
	updateButton = button(window, "Update", 60)
	updateButton:SetPoint("RIGHT", resetButton, "LEFT", -4, 0)
	updateButton:SetScript("OnClick", function()
		local count = Edit.Update()
		say(("Brought up to date in %d places. Undo takes it back."):format(count))
		refresh()
	end)
	resetButton:SetScript("OnClick", function()
		Edit.Reset()
		say("")
		refresh()
	end)

	status = UI.Text(window, 11)
	status:SetPoint("BOTTOMLEFT", LEFT, BAR - 20)
	status:SetTextColor(UI.RED[1], UI.RED[2], UI.RED[3])
	notesText = UI.Text(window, 10)
	notesText:SetPoint("BOTTOMLEFT", LEFT, 8)
	notesText:SetPoint("BOTTOMRIGHT", -14, 8)
	notesText:SetHeight(26)
	notesText:SetTextColor(0.62, 0.62, 0.62)
	notesText:SetWordWrap(true)
	createBand()
end

-- Opens the editor with the box for sharing ("share") or taking one in
-- ("import") on top of it.
function Edit.Share(mode)
	if not ns.db then return end
	if not window then create() end
	if not window:IsShown() then
		Edit.Pick()
		window:Show()
		Engine.Rebuild()
		say("")
		refresh()
	end
	openBox(mode == "import" and "import" or "share")
end

-- Opens the editor on the rotation in use, or closes it when it is open.
function Edit.Toggle()
	if not ns.db then return end
	if not window then create() elseif window:IsShown() then
		window:Hide()
		return
	end
	Edit.Pick()
	window:Show()
	Engine.Rebuild()
	say("")
	refresh()
end
