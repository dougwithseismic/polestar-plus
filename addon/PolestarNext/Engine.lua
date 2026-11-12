-- Scan -> the rotation for this tree and stance -> the suggestion for this
-- moment.
--
-- A rule is { spell = { id, "English name" }, when = condition, note = "why",
-- toggle = true } (toggle: an attack that stays on, not suggested again while
-- it is). The first rule down the list fires whose spell the character has,
-- whose condition holds, and which the game does not say is unusable, on
-- cooldown or out of range.
--
-- There is one rotation for each class, talent tree and stance or form (a
-- Protection warrior in Defensive Stance, a Feral druid in Cat Form...). The
-- one that matches the character is in use, and changes as they do. Each is
-- built by the class's builder, unless the player has edited it, in which
-- case their version is used as it is.

local _, ns = ...
local num, call, tri, fn = ns.num, ns.call, ns.tri, ns.fn
local Scan, Rules = ns.Scan, ns.Rules

local Engine = { list = {}, custom = false, notes = {}, key = nil, idle = { times = 0 }, picks = { shown = 0, agreed = 0 } }
ns.Engine = Engine

Engine.SPECS = {
	WARRIOR = { "Arms", "Fury", "Protection" }, PALADIN = { "Holy", "Protection", "Retribution" },
	HUNTER = { "Beast Mastery", "Marksmanship", "Survival" }, ROGUE = { "Assassination", "Combat", "Subtlety" },
	PRIEST = { "Discipline", "Holy", "Shadow" }, SHAMAN = { "Elemental", "Enhancement", "Restoration" },
	MAGE = { "Arcane", "Fire", "Frost" }, WARLOCK = { "Affliction", "Demonology", "Destruction" },
	DRUID = { "Balance", "Feral Combat", "Restoration" },
}

-- A cooldown this short is the pause between abilities, not a wait.
local GLOBAL = 1.5

---------------------------------------------------------------------------
-- A spell right now. Read once a tick and kept until the next.
---------------------------------------------------------------------------

local states = {}

local function cooldown(info, a, b)
	-- The table the newer call returns, or the older call's three values.
	local start, duration, enabled
	if type(ns.plain(info)) == "table" then
		start, duration, enabled = num(ns.field(info, "startTime")), num(ns.field(info, "duration")), ns.field(info, "isEnabled")
	else
		start, duration, enabled = num(info), num(a), ns.plain(b)
	end
	if not (start and duration) then return nil, nil end
	if enabled == false or enabled == 0 then return false, nil end
	local left = duration > 0 and math.max(0, start + duration - GetTime()) or 0
	return left <= GLOBAL, left
end

-- Range has three answers of its own: in range, out of range, and no
-- answer at all (nothing targeted, or a spell with no range), which must not
-- read as "out of range". Older clients answer 1 and 0.
local function inRange(check, ...)
	if type(check) ~= "function" then return nil end
	local ok, v = pcall(check, ...)
	if not ok or v == nil or ns.secret(v) then return nil end
	return v == true or v == 1
end

local function read(ref)
	local s = { known = false }
	local name = ns.SpellName(ref)
	if not name then return s end
	local lower = name:lower()
	local bar, book = Scan.bars[lower], Scan.spells[lower]
	s.name = name
	s.known = Scan.Knows(ref)
	if not s.known then return s end
	s.key = bar and bar.key or nil
	s.onBars = bar ~= nil
	s.id = (bar and bar.id) or (book and book.id) or (type(ref) == "table" and ref[1]) or nil
	if bar then
		local slot = bar.slot
		local usable = fn("C_ActionBar", "IsUsableAction")
		if usable then
			local ok, can, short = pcall(usable, slot)
			if ok and not ns.secret(can) and not ns.secret(short) then
				s.usable = (can and not short) and true or false
				s.short = short and true or false
			end
		end
		s.ready, s.left = cooldown(call(fn("C_ActionBar", "GetActionCooldown"), slot))
		s.inRange = inRange(fn("C_ActionBar", "IsActionInRange"), slot)
		local on, repeating = tri(fn("C_ActionBar", "IsCurrentAction"), slot), tri(fn("C_ActionBar", "IsAutoRepeatAction"), slot)
		if on == true or repeating == true then s.active = true elseif on == false then s.active = false end
	elseif s.id then
		local usable = fn("C_Spell", "IsSpellUsable") or IsUsableSpell
		if usable then
			local ok, can, short = pcall(usable, s.id)
			if ok and not ns.secret(can) and not ns.secret(short) then
				s.usable = (can and not short) and true or false
				s.short = short and true or false
			end
		end
		s.ready, s.left = cooldown(call(fn("C_Spell", "GetSpellCooldown"), s.id))
		if tri(UnitExists, "target") == true then s.inRange = inRange(fn("C_Spell", "IsSpellInRange"), s.id, "target") end
		s.active = tri(fn("C_Spell", "IsCurrentSpell"), s.id)
	end
	-- Where the game will not say whether it is on cooldown, the player's own
	-- last use of it and how long its cooldown runs do.
	if s.ready == nil and s.id then
		local cast = Rules.casts[lower]
		local _, _, long = Engine.Facts(s.id)
		if cast and long and long > GLOBAL then
			local left = long - (GetTime() - cast.at)
			if left > 0 then s.ready, s.left = false, left end
		end
	end
	return s
end

-- Forgets what was read this moment, for a new one.
function Engine.Fresh()
	ns.wipe(states)
end

function Engine.State(ref)
	local key = ns.SpellName(ref) or ref
	local s = states[key]
	if not s then
		s = read(ref)
		states[key] = s
	end
	return s
end

---------------------------------------------------------------------------
-- Rotations
---------------------------------------------------------------------------

-- What is wrong with `list` as data, or nil.
function Engine.Lint(list)
	if type(list) ~= "table" then return "a list must be a table of rules" end
	for i, rule in ipairs(list) do
		if type(rule) ~= "table" then return ("rule %d is not a table"):format(i) end
		local spell = rule.spell
		if type(spell) ~= "table" or (type(spell[1]) ~= "number" and type(spell[2]) ~= "string") then
			return ("rule %d names no spell"):format(i)
		end
		local bad = Rules.Lint(rule.when)
		if bad then return ("rule %d (%s): %s"):format(i, ns.SpellName(spell) or "?", bad) end
	end
	return nil
end

-- The name a rotation is saved under: class, talent tree (0 before any
-- talents), and stance or form (0 for none). Without arguments, the
-- character's own right now.
function Engine.Key(spec, stance)
	return ("%s:%d:%d"):format(Scan.class or "?", spec or Scan.spec or 0, stance or Scan.stance or 0)
end

-- A rotation's name in words: "Protection, Defensive Stance".
function Engine.Title(spec, stance)
	spec, stance = spec or Scan.spec or 0, stance or Scan.stance or 0
	local trees = Engine.SPECS[Scan.class or ""]
	local name = trees and trees[spec] or "No talents yet"
	local place = Scan.stances[stance]
	if place then return name .. ", " .. place end
	return name
end

-- The class's rotation for a tree and stance (the character's own without
-- arguments), with the game's numbers over the damage abilities. `notes`
-- collects why it came out the way it did.
function Engine.Build(notes, spec, stance)
	notes = notes or {}
	local build = Scan.class and ns.Classes[Scan.class]
	local list = build and build(ns.Classes.Context(notes, spec, stance)) or {}
	Rules.reach = ns.Classes.REACH[Scan.class or ""] or {}
	-- Area abilities are only offered when the enemies around can be counted.
	local shown = ns.str((call(fn("C_CVar", "GetCVar"), "nameplateShowEnemies")))
	if shown == "0" then
		notes[#notes + 1] = "Enemy nameplates are off, so enemies around you cannot be counted: switch them on for the area abilities."
	end
	ns.wipe(states)
	local scored, wanted = ns.Numbers.Order(list)
	if wanted > 0 and scored == 0 then
		notes[#notes + 1] = "The game gave no damage numbers to go by (descriptions not loaded yet, or not in English): the class's own order stands."
	elseif scored > 0 then
		notes[#notes + 1] = ("%d of %d damage abilities are ordered by the game's numbers for your character."):format(scored, wanted)
	end
	return list, scored, wanted
end

-- The player's own version of the rotation saved under `key`, when there is
-- a sound one.
function Engine.Own(key)
	local lists = ns.db and ns.db.lists
	local saved = type(lists) == "table" and lists[key] or nil
	if saved and not Engine.Lint(saved) then return saved end
	return nil
end

-- Reads the character again and puts the rotation for their tree and stance
-- in use: their own version when they have edited it, else the built one.
function Engine.Rebuild()
	Scan.All()
	-- A new rank or talent changes what a spell costs and how long it lasts.
	Engine.ForgetFacts()
	Rules.Forget()
	Engine.signature = Scan.Signature()
	Engine.notes = {}
	Engine.key = Engine.Key()
	local own = Engine.Own(Engine.key)
	if own then
		Engine.list, Engine.custom = own, true
		Engine.scored, Engine.wanted = nil, nil
	else
		Engine.list, Engine.scored, Engine.wanted = Engine.Build(Engine.notes)
		Engine.custom = false
	end
	Engine.Report()
	return Engine.list
end

-- What the scan found, kept with the saved settings so a problem on a new
-- client can be looked at after a /reload. Nothing here changes while playing.
function Engine.Report()
	if not ns.db then return end
	local spells, bars, keyed, unknown = 0, 0, 0, {}
	for _ in pairs(Scan.spells) do spells = spells + 1 end
	for _, entry in pairs(Scan.bars) do
		bars = bars + 1
		if entry.key then keyed = keyed + 1 end
	end
	for _, rule in ipairs(Engine.list) do
		if not (rule.spell[1] and ns.SpellNameOf(rule.spell[1])) and rule.spell[1] then
			unknown[#unknown + 1] = ("%d %s"):format(rule.spell[1], rule.spell[2] or "")
		end
	end
	local g = Scan.gear
	-- The talents found, the list in order, and what the talent calls
	-- answered: enough to see from outside why a list came out as it did.
	local talents, order, trees, stances = {}, {}, {}, {}
	for name, rank in pairs(Scan.talents) do
		if type(name) == "string" then talents[name] = rank end
	end
	for _, rule in ipairs(Engine.list) do
		local s = Engine.State(rule.spell)
		if s.known then
			order[#order + 1] = ("%s [%s]%s"):format(s.name or "?", s.key or (s.onBars and "no key" or "not on bars"),
				rule.figures and (" " .. rule.figures) or "")
		end
	end
	local S = C_SpecializationInfo
	for tree = 1, 3 do
		if S and S.GetSpecializationInfo then
			local ok, _, name, _, _, _, _, points = pcall(S.GetSpecializationInfo, tree)
			trees[tree] = ok and ("%s=%s"):format(tostring(ns.plain(name)), tostring(ns.plain(points))) or "call failed"
		else
			trees[tree] = "no such call"
		end
	end
	for place, name in pairs(Scan.stances) do stances[place] = name end
	-- Whether this client has the game's own one-button rotation helper, and
	-- what it offers: the sanctioned way to "one key does the rotation".
	local assistant = {}
	if type(C_AssistedCombat) == "table" then
		for name, value in pairs(C_AssistedCombat) do
			if type(value) == "function" then assistant[#assistant + 1] = name end
		end
		table.sort(assistant)
	end
	ns.db.report = {
		rotation = Engine.key, rotationName = Engine.Title(), stances = stances,
		gameAssistant = type(C_AssistedCombat) == "table" and assistant or "this client has none",
		-- Filled in while playing: what the game would not say in a fight, and
		-- the last time there was nothing to suggest in one.
		hiddenInCombat = Rules.hidden, nothingToSuggest = Engine.idle,
		effectDurationsSeen = Rules.durations, powerPerSecondLately = Rules.rate,
		enemyNameplates = ns.str((call(fn("C_CVar", "GetCVar"), "nameplateShowEnemies"))), mostEnemiesCounted = Rules.mostEnemies,
		mostNameplatesSeen = Rules.mostPlates, gamePicks = Engine.picks,
		talents = talents, order = order, trees = trees, pointsSpentOnTree = Scan.Spent(), stance = Scan.stance, form = Scan.form,
		pointsFrom = Scan.pointsFrom,
		signature = Engine.signature,
		class = Scan.class, level = Scan.level, points = { Scan.points[1], Scan.points[2], Scan.points[3] }, spec = Scan.spec,
		spells = spells, barSpells = bars, barSpellsWithKeys = keyed, rules = #Engine.list, custom = Engine.custom,
		gear = { twoHand = g.twoHand, shield = g.shield, dualWield = g.dualWield, dagger = g.dagger, wand = g.wand, ranged = g.rangedWeapon },
		spellIDsThisClientLacks = unknown, problems = Scan.problems, notes = Engine.notes,
		orderedByNumbers = Engine.scored, wantedNumbers = Engine.wanted,
	}
end

---------------------------------------------------------------------------
-- The suggestion
---------------------------------------------------------------------------

local queue = {}

-- What the class's bar holds, for "not enough rage yet".
function Engine.PowerName()
	local kind = num((call(UnitPowerType, "player")))
	return ({ [0] = "mana", [1] = "rage", [2] = "focus", [3] = "energy" })[kind or -1] or "power"
end

-- Up to `most` abilities that could be used now, best first: each entry is
-- { rule, state, index }. The first is the suggestion; the rest are what
-- else is ready. When nothing can be used, the first ability held up only
-- by distance or by not having the rage, energy or mana for it yet is
-- returned alone, with `blocked = "range"` or `"power"`: something to head
-- for, instead of nothing.
function Engine.Queue(most)
	ns.wipe(states)
	ns.wipe(queue)
	Rules.fighting = tri(UnitAffectingCombat, "player") == true
	local seen = {}
	local waiting, waitingState, waitingIndex, waitingFor
	for index, rule in ipairs(Engine.list) do
		local s = Engine.State(rule.spell)
		if not rule.off and s.known and not seen[s.name] and s.ready ~= false and (s.usable ~= false or s.short)
			and not (rule.toggle and s.active == true) and Rules.Check(rule.when) == true then
			if s.usable ~= false and s.inRange ~= false then
				seen[s.name] = true
				queue[#queue + 1] = { rule = rule, state = s, index = index }
				if #queue >= (most or 1) then break end
			elseif not waiting then
				waiting, waitingState, waitingIndex = rule, s, index
				waitingFor = s.usable == false and "power" or "range"
			end
		end
	end
	if #queue == 0 and waiting then
		queue[1] = { rule = waiting, state = waitingState, index = waitingIndex, blocked = waitingFor }
	end
	return queue
end

-- A cooldown with this long or less to run is worth showing as coming up.
local SOON = 12

-- What cannot be used yet, for when there is nothing to plan: what is only
-- held up by distance or by not having the rage, energy or mana, in the
-- rotation's order; then what comes off cooldown within a few seconds,
-- soonest first. Each entry is { rule, state, index, blocked, left }.
function Engine.Waiting(most)
	local out, cooling, seen = {}, {}, {}
	for index, rule in ipairs(Engine.list) do
		local s = Engine.State(rule.spell)
		if not rule.off and s.known and not seen[s.name] and not (rule.toggle and s.active == true) and Rules.Check(rule.when) == true then
			local entry = { rule = rule, state = s, index = index }
			if s.ready == false then
				if s.left and s.left <= SOON then
					entry.blocked, entry.left = "cooldown", s.left
					cooling[#cooling + 1], seen[s.name] = entry, true
				end
			elseif s.usable == false then
				if s.short then
					entry.blocked = "power"
					out[#out + 1], seen[s.name] = entry, true
				end
			elseif s.inRange == false then
				entry.blocked = "range"
				out[#out + 1], seen[s.name] = entry, true
			end
		end
	end
	table.sort(cooling, function(a, b) return a.left < b.left end)
	for _, entry in ipairs(cooling) do out[#out + 1] = entry end
	for i = #out, (most or 1) + 1, -1 do out[i] = nil end
	return out
end

---------------------------------------------------------------------------
-- The plan: the next several presses, laid out in time.
--
-- From the moment the global cooldown (or a cast in progress) ends, the plan
-- steps forward one global cooldown at a time. At each step it asks the
-- rotation what to use at that moment, in a future where its own earlier
-- steps have happened: an effect it put on is on and running down, a spell
-- it used is on cooldown, rage it spent is gone and rage coming in has
-- arrived. So Rend goes back on in the slot before it would drop, Sunder
-- Armor is renewed before it fades, a strike is placed where its cooldown
-- ends, and whatever fits goes in between. Abilities off the global cooldown
-- (a strike queued for the next swing, Bloodrage) take no slot of their own.
-- When nothing fits a moment, the plan looks half a second further on.
---------------------------------------------------------------------------

local HORIZON = 12 -- how many seconds ahead the plan looks

local costs, pauses, cooldowns, castings = {}, {}, {}, {} -- by spell ID: rage or mana, off the global cooldown, cooldown seconds, cast seconds

local function spellFacts(id)
	if costs[id] == nil then
		local list = ns.plain((call(fn("C_Spell", "GetSpellPowerCost"), id)))
		local cost = false
		for _, entry in ipairs(type(list) == "table" and list or {}) do
			local amount = num(ns.field(entry, "cost")) or num(ns.field(entry, "minCost"))
			if amount and amount > 0 then cost = amount end
		end
		costs[id] = cost
		local base, pause = call(GetSpellBaseCooldown, id)
		cooldowns[id] = (num(base) or 0) / 1000
		pauses[id] = num(pause) == 0
		castings[id] = (num(ns.field(call(fn("C_Spell", "GetSpellInfo"), id), "castTime")) or 0) / 1000
	end
	return costs[id] or nil, pauses[id], cooldowns[id], castings[id]
end

-- A spell's cost, whether it is off the global cooldown, its cooldown, and
-- how long it takes to cast.
function Engine.Facts(id)
	return spellFacts(id)
end

---------------------------------------------------------------------------
-- What the game does not say about a spell in so many numbers, by its
-- English name (a rule carries it) and, failing that, by its description.
---------------------------------------------------------------------------

-- Combo points awarded, and the finishing moves that spend them all.
local BUILDERS = {
	["sinister strike"] = 1, backstab = 1, hemorrhage = 1, ["ghostly strike"] = 1, ambush = 1, garrote = 1, gouge = 1,
	["cheap shot"] = 2, mutilate = 2, claw = 1, rake = 1, mangle = 1, pounce = 1, shred = 1, ravage = 1,
}
local FINISHERS = {
	eviscerate = true, ["slice and dice"] = true, rupture = true, ["kidney shot"] = true, ["expose armor"] = true,
	["ferocious bite"] = true, rip = true, ["death mark"] = true,
}
-- Spells held for their whole length, and how long that is where the
-- description does not say.
local CHANNELS = {
	["mind flay"] = 3, ["arcane missiles"] = 5, ["drain life"] = 5, ["drain soul"] = 15, ["health funnel"] = 10,
	evocation = 8, penance = 2, blizzard = 8, hurricane = 10, ["rain of fire"] = 8, volley = 6, tranquility = 10,
	wrack = 6,
}
-- A wand's Shoot is switched on like an attack, but not beside a cast: it
-- is what there is to do when nothing above it in the order fits.
local ALONE = { shoot = true }
-- What refills the bar is planned once where the plan cannot tell how much
-- it gives: without that it would see the bar still low and ask again.
local ONCE = { ["life tap"] = true, evocation = true, ["shifting power"] = true }
-- Effects of the player's own that an ability uses up.
local SPENDS = {
	judgement = {
		{ 21084, "Seal of Righteousness" }, { 20375, "Seal of Command" }, { 21082, "Seal of the Crusader" },
		{ 20164, "Seal of Justice" }, { 20165, "Seal of Light" }, { 20166, "Seal of Wisdom" },
	},
}
-- Abilities that share one cooldown.
local SHARED = {
	{ { 8042, "Earth Shock" }, { 8050, "Flame Shock" }, { 8056, "Frost Shock" } },
	-- Forever: Multi-Shot shares Aimed Shot's cooldown (Arcane Shot no longer
	-- does), and a Beast Master's Summon Hawk shares Arcane Shot's.
	{ { 19434, "Aimed Shot" }, { 2643, "Multi-Shot" } },
	{ { 3044, "Arcane Shot" }, { nil, "Summon Hawk" } },
}

local kinds = {} -- by lower-case name: { combo = points or "spend", channel = seconds }

local function english(rule, s)
	return ((type(rule.spell) == "table" and rule.spell[2]) or s.name or ""):lower()
end

-- { combo = the points it awards, or "spend" for a finishing move;
--   channel = seconds it is held; spends; shares = the abilities whose
--   cooldown it starts too; alone = it takes the slot though it is a toggle }.
local function kindOf(rule, s)
	local name = english(rule, s)
	local kind = kinds[name]
	if kind then return kind end
	kind = { combo = FINISHERS[name] and "spend" or BUILDERS[name], channel = CHANNELS[name], spends = SPENDS[name], alone = ALONE[name], once = ONCE[name] }
	for _, group in ipairs(SHARED) do
		for _, ref in ipairs(group) do
			if ref[2]:lower() == name then kind.shares = group end
		end
	end
	local text = s.id and ns.str((call(fn("C_Spell", "GetSpellDescription"), s.id)))
	-- A description still loading is asked for again.
	if s.id and (not text or text == "") then return kind end
	local lower, parsed = (text or ""):lower(), ns.Numbers.Parse(text or "")
	if not kind.combo then
		if lower:find("finishing move", 1, true) then
			kind.combo = "spend"
		else
			kind.combo = tonumber(lower:match("awards (%d+) combo point"))
		end
	end
	-- The description's own length for a channel, where it gives one.
	if kind.channel and parsed.over and parsed.over <= 20 then kind.channel = parsed.over end
	kinds[name] = kind
	return kind
end

function Engine.Kind(rule)
	return kindOf(rule, Engine.State(rule.spell))
end

-- The rage or energy a spell gives the moment it is used (Bloodrage, Charge),
-- from its description; nil when none.
local gains = {}

-- What was read about spells is read again: a new rank or a talent may
-- have changed a cost, a cast time or a description.
function Engine.ForgetFacts()
	for _, kept in ipairs({ costs, pauses, cooldowns, castings, kinds, gains }) do ns.wipe(kept) end
end
function Engine.Gain(id)
	if gains[id] == nil then
		local text = ns.str((call(fn("C_Spell", "GetSpellDescription"), id)))
		-- A description still loading is asked for again.
		if not text or text == "" then return nil end
		gains[id] = ns.Numbers.Parse(text).gain or false
	end
	return gains[id] or nil
end

-- What a spell costs in rage, energy or mana; nil when nothing or unknown.
function Engine.Cost(id)
	return (spellFacts(id))
end

-- Seconds until the spell is off cooldown: the plan's own use of it where it
-- has used it, else the game's.
function Engine.ReadyIn(ref, future)
	local s = Engine.State(ref)
	local planned = future and s.name and future.cooldowns[s.name]
	if planned then return planned end
	-- A fight on paper starts with everything off cooldown.
	if future and future.sim then return 0 end
	if s.ready == false then return s.left or math.huge end
	return 0
end

-- Whether `rule` could be used at the moment the plan has reached.
-- Whether condition `c` asks `test` anywhere in it.
local function asks(c, test)
	if type(c) ~= "table" then return false end
	if c[1] == test then return true end
	for i = 2, #c do
		if asks(c[i], test) then return true end
	end
	return false
end

local function fits(rule, s, future, t, wait, spent)
	if rule.off or not s.known or future.used[s.name] then return false end
	if Engine.ReadyIn(rule.spell, future) > t + 0.05 then return false end
	local cost = s.id and spellFacts(s.id)
	local sim = future.sim
	if sim then
		-- A fight that has not happened: nothing has been dodged or blocked
		-- to answer, and the sum alone decides what there is rage for. What
		-- the game calls unusable for another reason (no shield for Shield
		-- Slam) stays out, when the rotation is the one the character is
		-- standing in; a finisher that only waits for a dying target does not.
		if rule.react then return false end
		if sim.inUse and s.usable == false and not s.short and not asks(rule.when, "target%<") then return false end
		if cost and future.power and future.power < cost then return false end
		return Rules.Check(rule.when) == true
	end
	if (rule.toggle and s.active == true) or s.inRange == false then return false end
	-- Unusable for want of rage is a matter of time; unusable for any other
	-- reason (the stance, a reaction that has not come) is taken to stay so.
	if s.usable == false and not s.short then return false end
	-- For the present, with nothing spent yet, the game's own word on
	-- whether there is the rage for it outranks this sum.
	local present = spent == 0 and t <= wait + 0.05 and s.usable ~= false
	if not present and cost and future.power and future.power < cost then return false end
	if s.usable == false and not (cost and future.power) then return false end
	return Rules.Check(rule.when) == true
end

-- The planner. Up to `most` steps of `list`, no further ahead than `horizon`
-- seconds: { rule, state, index, at = seconds from now, free = it takes no
-- slot, blocked = "cooldown" and left = at when it is not for now, cast and
-- channel = seconds it takes, puts = the effect it puts on, power and combo
-- = the bar and the combo points after it }. With `sim` it plans a fight on
-- paper (see Rules) instead of carrying this moment forward.
--
-- A press takes a slot: the global cooldown, or the spell's own cast or
-- channel where that is longer. What it puts on lands when the cast ends.
local ENERGY, MANA = 3, 0

local function run(list, most, horizon, sim)
	ns.wipe(states)
	local wait, pause, power, ceiling, rate, combo
	local kind = num((call(UnitPowerType, "player")))
	local future = { effects = {}, cooldowns = {}, used = {}, sim = sim }
	if sim then
		wait, pause = 0, sim.pause or select(2, Rules.Global())
		power, ceiling, rate, combo = sim.power, sim.ceiling or 100, sim.income or 0, 0
		future.combat, future.mana = false, sim.bar == "mana"
	else
		Rules.fighting = tri(UnitAffectingCombat, "player") == true
		Rules.SamplePower()
		wait, pause = Rules.Global()
		-- A cast in progress holds things up as the global cooldown does.
		local ok, casting, _, _, _, ends = pcall(UnitCastingInfo or error, "player")
		if ok and casting and num(ends) then wait = math.max(wait, ends / 1000 - GetTime()) end
		power = num((call(UnitPower, "player")))
		ceiling = num((call(UnitPowerMax, "player"))) or 100
		rate = Rules.rate
		-- Energy comes in at its own steady pace, seen lately or not.
		if kind == ENERGY then rate = math.max(rate, 10) end
		combo = num((call(GetComboPoints, "player", "target")))
		if combo == nil then combo = num((call(UnitPower, "player", 4))) end
		future.combat, future.mana = Rules.fighting, kind == MANA
	end
	future.ahead, future.power, future.ceiling, future.combo = wait, power, ceiling, combo
	-- struck: something has been pressed at the enemy, so the fight is on.
	-- swinging: only an attack has been switched on, which starts the fight
	-- when there is nothing to press first (an opener still has its moment).
	local plan, t, spent, gained, slot, busy, struck, swinging = {}, wait, 0, 0, wait, 0, false, false

	-- The bar at the moment reached: what there was, what has come in, what
	-- the plan has spent and what its own steps gave back.
	local function bar()
		if power then future.power = math.max(0, math.min(ceiling, power + rate * t - spent + gained)) end
	end

	-- Puts `rule` in the plan at the moment reached, and makes the future one
	-- in which it has been used.
	local function take(rule, s, index)
		local cost, free, cooldown, cast = nil, false, 0, 0
		if s.id then cost, free, cooldown, cast = spellFacts(s.id) end
		local what = kindOf(rule, s)
		free = (free or rule.toggle == true) and not what.alone
		cast = cast or 0
		local entry = { rule = rule, state = s, index = index, at = t, free = free }
		if cast > 0 then entry.cast = cast end
		if what.channel then entry.channel = what.channel end
		-- Not for this moment: the plan had to leave a gap before it.
		if t - slot > 0.3 then entry.blocked, entry.left = "cooldown", t end
		plan[#plan + 1] = entry
		local applies = Rules.Applies(rule)
		if applies then
			local put = Rules.PutOn(applies.unit, rule.spell, applies.lasts, applies.cap, cast)
			if put then entry.puts = { unit = applies.unit, to = put.ends - GetTime(), stacks = put.stacks, cap = applies.cap } end
		end
		for _, ref in ipairs(what.spends or {}) do Rules.TakeOff("player", ref) end
		if cost then spent = spent + cost end
		local gain = (s.id and Engine.Gain(s.id)) or 0
		gained = gained + gain
		bar()
		entry.power = future.power
		if future.combo ~= nil then
			if what.combo == "spend" then
				future.combo = 0
			elseif what.combo then
				future.combo = math.min(5, future.combo + what.combo)
			end
			if what.combo then entry.combo = future.combo end
		end
		-- Anything pressed at the enemy starts the fight, from the next moment
		-- on: what is for "before the first hit" still has this one.
		if asks(rule.when, "target") then
			if free then swinging = true else struck = true end
		end
		if free or rule.react or rule.toggle or (what.once and gain == 0) then
			-- Once is enough for something that stays on, takes no slot, or
			-- answers something that happened (a dodge, a block).
			future.used[s.name] = true
		end
		if not free then
			local back = t + cast + math.max(cooldown or 0, 0)
			future.cooldowns[s.name] = back
			for _, ref in ipairs(what.shares or {}) do
				local other = ns.SpellName(ref)
				if other and (cooldown or 0) > 0 then future.cooldowns[other] = back end
			end
			busy = math.max(cast, what.channel or 0)
		end
		return free
	end

	local guard = 0
	while #plan < most and t <= horizon and guard < horizon * 5 do
		guard = guard + 1
		future.ahead = t
		-- The present: nothing spent yet and no waiting, where what the game
		-- says of each ability is still true.
		future.present = not sim and spent == 0 and t <= wait + 0.05
		bar()
		Rules.Ahead(future)
		-- Down the rotation once: the first ability that takes the slot, and
		-- every free one that fits beside it, each in its place in the order.
		-- A free one that gives rage (Bloodrage) may pay for an ability above
		-- it in the order: the rotation is then gone down again from the top.
		local pressed, again = false, true
		busy = 0
		while again do
			again = false
			for index, rule in ipairs(list) do
				if #plan >= most then break end
				local s = Engine.State(rule.spell)
				local free = (rule.toggle == true or (s.id ~= nil and select(2, spellFacts(s.id)) == true)) and not kindOf(rule, s).alone
				if (free or not pressed) and fits(rule, s, future, t, wait, spent) then
					local had = gained
					if not take(rule, s, index) then
						pressed = true
					elseif gained > had and not pressed then
						again = true
						break
					end
				end
			end
			-- Nothing to press before the fight, and the attack is on: the
			-- fight has started, so the rotation is gone down again as one.
			if not pressed and not again and swinging and not future.combat then
				future.combat, again = true, true
			end
		end
		if struck then future.combat = true end
		if pressed then
			t = t + math.max(pause, busy)
			slot = t
		else
			t = t + 0.5
		end
	end
	Rules.Ahead(nil)
	return plan
end

-- The next `most` steps of the rotation in use, from this moment.
function Engine.Plan(most)
	return run(Engine.list, most or 1, HORIZON)
end

-- What a rotation would do in a fight that started now, on paper: a new
-- enemy in reach (`options.enemies` of them) that goes from full health to
-- dead over `options.seconds`, nothing of the player's on it, everything off
-- cooldown, the bar at `options.power` and filling by `options.income` a
-- second, no combo points. The player's own buffs are as they stand.
-- Reactions are left out: nothing has been dodged or blocked yet.
-- Returns { steps (as Engine.Plan's), lanes = the effects it keeps up, each
-- { name, unit, cap, most = stacks reached, full = when it got there,
-- spans = { { from, to } } }, seconds }.
function Engine.Preview(list, options)
	options = options or {}
	local seconds = options.seconds or 30
	local sim = {
		power = options.power, income = options.income or 0, enemies = options.enemies or 1, stance = options.stance,
		ceiling = options.ceiling or num((call(UnitPowerMax, "player"))) or 100, inUse = options.inUse == true,
		bar = options.bar or Engine.PowerName(), pause = options.pause, form = options.form, dies = options.dies or seconds,
		melee = options.melee,
	}
	local steps = run(list or Engine.list, 120, seconds, sim)
	local lanes, byName = {}, {}
	for _, step in ipairs(steps) do
		local put = step.puts
		if put then
			local lane = byName[step.state.name]
			if not lane then
				lane = { name = step.state.name, unit = put.unit, cap = put.cap or 1, most = 0, spans = {} }
				byName[step.state.name] = lane
				lanes[#lanes + 1] = lane
			end
			local last = lane.spans[#lane.spans]
			if last and step.at <= last.to + 0.05 then
				last.to = put.to
			else
				lane.spans[#lane.spans + 1] = { from = step.at, to = put.to }
			end
			if (put.stacks or 1) > lane.most then
				lane.most = put.stacks or 1
				if lane.most >= lane.cap then lane.full = step.at end
			end
		end
	end
	return { steps = steps, lanes = lanes, seconds = seconds }
end

-- The effects on the target that the rotation keeps up, as they stand now:
-- { name, left = seconds (nil when the game gives no timer), stacks (for one
-- that stacks), sure = the timer is the game's own and not an estimate }.
function Engine.Tracked()
	local out, seen = {}, {}
	for _, rule in ipairs(Engine.list) do
		local s = Engine.State(rule.spell)
		if not rule.off and s.known and not seen[s.name] then
			local applies = Rules.Applies(rule)
			if applies and applies.unit == "target" then
				seen[s.name] = true
				local up, ends, stacks, sure = Rules.Effect("target", rule.spell, applies.lasts)
				if up then
					out[#out + 1] = { name = s.name, left = ends and (ends - GetTime()) or nil, stacks = applies.cap > 1 and stacks or nil, sure = sure == true }
				end
			end
		end
	end
	return out
end

---------------------------------------------------------------------------
-- The game's own assistant. Forever has one (C_AssistedCombat): the game
-- picks the next spell itself, knowing what it hides from add-ons, and
-- offers a single button that casts its pick. This add-on can read the pick
-- and show it: as a fallback when its own rotation has nothing to say, or
-- always, as the player chooses.
---------------------------------------------------------------------------

-- { available, pick = { id, name }, button = { id, name } }: whether the
-- game's assistant is there, what it would cast next, and its one button.
function Engine.Assistant()
	local A = C_AssistedCombat
	if type(A) ~= "table" then return { available = false } end
	local function spell(get, ...)
		local id = num((call(get, ...)))
		local name = id and ns.SpellNameOf(id)
		if id and id > 0 and name then return { id, name } end
		return nil
	end
	local available = ns.tri(A.IsAvailable)
	return { available = available ~= false, pick = spell(A.GetNextCastSpell, false), button = spell(A.GetActionSpell) }
end

-- How the game's pick is used: "fallback" (when this add-on's own rotation
-- has nothing for now), "always", or "off".
function Engine.AssistMode()
	local mode = ns.db and ns.db.assist
	if mode == "always" or mode == "off" then return mode end
	return "fallback"
end

-- What is coming up, for the row beside the suggestion: the plan when there
-- is one, else what is waiting on distance, rage or a cooldown; with the
-- game's own pick put first where the player wants it.
function Engine.Upcoming(most)
	local plan = Engine.Plan(most)
	if #plan == 0 then plan = Engine.Waiting(most) end
	local mode = Engine.AssistMode()
	if mode == "off" then return plan end
	local first = plan[1]
	if mode == "always" or not first or first.blocked then
		local pick = Engine.Assistant().pick
		-- Nothing to add when it is what the plan starts with anyway.
		if pick and not (first and not first.blocked and first.state.name == pick[2]) then
			local s = Engine.State(pick)
			if s.name then
				table.insert(plan, 1, { rule = { spell = pick, note = "the game's own pick" }, state = s, index = 0, at = 0, game = true })
				for i = #plan, (most or 1) + 1, -1 do plan[i] = nil end
			end
		end
	end
	return plan
end

-- Each ability the character has, and why it is or is not the suggestion:
-- what the panel had to go on at a moment it showed nothing.
function Engine.Explain()
	local lines = {}
	for _, rule in ipairs(Engine.list) do
		local s = Engine.State(rule.spell)
		if s.known then lines[#lines + 1] = ("%s: %s"):format(s.name or "?", Engine.Why(rule)) end
	end
	return lines
end

-- The rule to act on now, its spell's state, its place on the list, and
-- "range" when it is only waiting on distance; nil when nothing applies.
function Engine.Suggest()
	local first = Engine.Queue(1)[1]
	if not first then return nil end
	return first.rule, first.state, first.index, first.blocked
end

-- Why rule `rule` is not the suggestion right now, in a few words.
function Engine.Why(rule)
	local s = Engine.State(rule.spell)
	if rule.off then return "switched off" end
	if not s.known then return "not learned" end
	if s.usable == false and s.short then return "not enough " .. Engine.PowerName() end
	if s.usable == false then return "not usable now" end
	if s.ready == false then return s.left and ("%.0fs cooldown"):format(s.left) or "on cooldown" end
	if rule.toggle and s.active == true then return "already on" end
	local held = Rules.Check(rule.when)
	if held == false then return "condition not met" end
	if held == nil then return "the game will not say" end
	if s.inRange == false then return "out of range" end
	return "ready"
end
