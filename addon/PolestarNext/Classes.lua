-- Each class's priority list, built from what the scan found.
--
-- These are orders of preference, most urgent first, for fighting one enemy
-- while levelling. They are for World of Warcraft: Forever (1.60.1), which is
-- Classic reworked: abilities that are new there (Victory Rush, Holy Strike,
-- Ice Lance, Wrack, Primal Bite...), ones that are gone (Tiger's Fury) and
-- changed cooldowns are followed from Blizzard's class notes and the guides
-- written for it, bent to the character: a spell is only listed where the
-- talents and gear make it the right call (which seal, which nuke, when spare
-- rage becomes a Heroic Strike). A rule for a spell the character does not
-- have never shows, so listing one costs nothing. They are a reasoned order,
-- not the output of a simulation, and
-- the game's own "usable" answer does a lot of the work: Execute and
-- Overpower are simply listed high and fire when the game lights them up.
--
-- A spell is { first-rank spell ID, "English name" }: the ID finds the
-- client's name for it in any language, the English name stands in where
-- this client has no such ID.

local _, ns = ...
local Scan = ns.Scan

local Classes = {}
ns.Classes = Classes

---------------------------------------------------------------------------
-- Writing rules
---------------------------------------------------------------------------

local function all(...) return { "and", ... } end
local function any(...) return { "or", ... } end
local function no(c) return { "not", c } end
local function buff(spell, lasts) return { "buff", spell, lasts } end
local function debuff(spell, lasts) return { "debuff", spell, lasts } end
local function test(name, n) return { name, n } end
-- A proc: the game lights the spell's button up, or the effect that makes it
-- worth pressing is on the player (`n` stacks of it).
local function proc(spell, effect, n) return any({ "lit", spell }, { "charges>=", effect, n or 1 }) end

-- Mana kept in reserve is a margin, like a health check: where the game
-- hides the bar and nothing is proved about it, it reads as passed, and the
-- game's own "not enough mana" still keeps an unaffordable spell out.
local function reserve(n) return { "maybe", { "mana%>=", n } } end

local TARGET, COMBAT, ELITE = { "target" }, { "combat" }, { "elite" }
-- A check that the player's health is high enough is a safety margin: where
-- the game hides the health (Forever does, in a fight) it reads as passed,
-- which is what { "maybe", ... } is for. "You are low" rules stay strict: an
-- unknown health never brings up a heal.
-- Two or more, and three or more, enemies in reach (Rules.Enemies).
local CROWD, PACK = { "enemies>=", 2 }, { "enemies>=", 3 }

-- The melee abilities whose range stands for "in reach" when enemies are
-- counted. A class with none counts the enemies that are on its threat list.
Classes.REACH = {
	WARRIOR = { { 772, "Rend" }, { 1715, "Hamstring" }, { 7386, "Sunder Armor" } },
	ROGUE = { { 1752, "Sinister Strike" }, { 2098, "Eviscerate" } },
	PALADIN = { { 20271, "Judgement" } },
	HUNTER = { { 2974, "Wing Clip" }, { 2973, "Raptor Strike" } },
	SHAMAN = { { 17364, "Stormstrike" } },
	DRUID = { { 1082, "Claw" }, { 6807, "Maul" } },
}
local OPENING = all(TARGET, no(COMBAT))
local FIGHTING = all(TARGET, COMBAT)

local function rule(list, spell, when, note, toggle)
	list[#list + 1] = { spell = spell, when = when, note = note, toggle = toggle or nil }
end

-- Marks the rules for these spells as reactions: usable because something
-- just happened (a dodge, a block, a parry), so the plan counts on them once
-- and not again.
local function reactions(list, ...)
	local set = {}
	for i = 1, select("#", ...) do set[select(i, ...)] = true end
	for _, r in ipairs(list) do
		if set[r.spell] then r.react = true end
	end
end

-- Marks the rules for these spells as ones the game's numbers may reorder
-- among themselves (Numbers.Order): the damage abilities, not the buffs,
-- interrupts and finishers whose place is a matter of timing.
local function ranked(list, ...)
	local set = {}
	for i = 1, select("#", ...) do set[select(i, ...)] = true end
	for _, r in ipairs(list) do
		if set[r.spell] then r.rank = true end
	end
end

-- What a builder is told about the character.
-- `spec` and `stance` stand in for the character's own, to build the
-- rotation for a tree or stance they are not in right now.
function Classes.Context(notes, spec, stance)
	local c = { class = Scan.class, level = Scan.level, gear = Scan.gear, points = Scan.points }
	c.spec, c.stance = spec or Scan.spec, stance or Scan.stance
	if spec == 0 then c.spec = nil end
	function c.has(spell) return Scan.Knows(spell) end
	function c.talent(name) return Scan.Talent(name) end
	-- Why the list came out the way it did, for /pnext list.
	function c.note(text) notes[#notes + 1] = text end
	return c
end

local ATTACK = { 6603, "Attack" }
local SHOOT = { 5019, "Shoot" }

-- A wand, for a caster whose mana is better kept.
local function wand(list, c)
	if c.gear.wand then
		rule(list, SHOOT, TARGET, "wand: mana is better kept", true)
		c.note("You have a wand: it finishes fights when mana runs short.")
	end
end

---------------------------------------------------------------------------
-- Warrior
---------------------------------------------------------------------------

function Classes.WARRIOR(c)
	local L = {}
	local BattleShout, Charge, Bloodrage, Intercept = { 6673, "Battle Shout" }, { 100, "Charge" }, { 2687, "Bloodrage" }, { 20252, "Intercept" }
	local Execute, Overpower, Revenge = { 5308, "Execute" }, { 7384, "Overpower" }, { 6572, "Revenge" }
	local MortalStrike, Bloodthirst, ShieldSlam = { 12294, "Mortal Strike" }, { 23881, "Bloodthirst" }, { 23922, "Shield Slam" }
	local Whirlwind, Rend, Sunder, HeroicStrike = { 1680, "Whirlwind" }, { 772, "Rend" }, { 7386, "Sunder Armor" }, { 78, "Heroic Strike" }
	local ShieldBlock, Pummel, ShieldBash, BerserkerRage = { 2565, "Shield Block" }, { 6552, "Pummel" }, { 72, "Shield Bash" }, { 18499, "Berserker Rage" }
	local DefensiveStance, BattleStance = { 71, "Defensive Stance" }, { 2457, "Battle Stance" }
	local ThunderClap, Cleave, Sweeping, DemoShout = { 6343, "Thunder Clap" }, { 845, "Cleave" }, { 12328, "Sweeping Strikes" }, { 1160, "Demoralizing Shout" }
	-- Forever: Victory Rush for every warrior from level 20, Spearing Strike
	-- at 16 points of Arms, and a Slam that Improved Slam makes worth using.
	local VictoryRush, Slam, Spearing = { 34428, "Victory Rush" }, { 1464, "Slam" }, { nil, "Spearing Strike" }

	-- A warrior has a rotation for each stance: what opens the fight, and
	-- which abilities the stance allows, differ.
	local DEFENSIVE, BERSERKER = 2, 3
	local stance = c.stance
	-- Protection talents, a shield on the arm, or simply standing in
	-- Defensive Stance: the tanking order.
	local tank = c.spec == 3 or c.gear.shield or stance == DEFENSIVE

	local strike = c.has(MortalStrike) or c.has(Bloodthirst) or c.has(ShieldSlam)
	-- Heroic Strike takes rage a main strike would rather have, and a slow
	-- two-hander wastes fewer swings on it than fast weapons do.
	-- With one: 40 rage for a tank, 60 for Arms and Fury. Without: 30, or 25
	-- with fast one-handers and no shield.
	local spare = strike and (tank and 40 or 60) or ((tank or c.gear.twoHand) and 30 or 25)
	spare = spare - c.talent("Improved Heroic Strike")
	-- Cleave, with two enemies, from 50 for a tank with a main strike.
	local crowdSpare = (strike and tank) and math.max(spare, 50) or spare
	if strike then
		c.note("You have a main strike, so Heroic Strike waits for " .. spare .. " rage.")
	elseif c.gear.twoHand then
		c.note("Two-hander and no main strike yet: Heroic Strike from " .. spare .. " rage.")
	else
		c.note("No main strike yet: Heroic Strike from " .. spare .. " rage.")
	end

	-- The stance the talents want.
	if c.spec == 3 and stance ~= DEFENSIVE then
		c.note("Protection talents: Defensive Stance is asked for when you are out of it.")
		rule(L, DefensiveStance, all(TARGET, no({ "stance", DEFENSIVE })), "Protection: Defensive Stance")
	elseif c.spec and c.spec ~= 3 and stance == DEFENSIVE then
		-- Arms or Fury left in Defensive Stance after tanking something.
		rule(L, BattleStance, all(OPENING, { "stance", DEFENSIVE }), "back to Battle Stance")
	end
	rule(L, BattleShout, no(buff(BattleShout, 110)), "keep Battle Shout up")

	-- The opener is the stance's.
	local healthy = { "maybe", test("health%>=", 50) }
	if stance == DEFENSIVE then
		if c.talent("Vanguard") > 0 then
			c.note("Vanguard: Charge opens from Defensive Stance too.")
			rule(L, Charge, OPENING, "open with Charge")
		else
			c.note("Defensive Stance has no Charge: Bloodrage gives the rage to open with.")
		end
		rule(L, Bloodrage, all(TARGET, test("power<", 20), healthy), "rage to open with")
	elseif stance == BERSERKER then
		c.note("Berserker Stance: Intercept opens, with Bloodrage first when there is no rage for it.")
		rule(L, Bloodrage, all(OPENING, test("power<", 10), healthy), "rage for Intercept")
		rule(L, Intercept, OPENING, "open with Intercept")
	else
		rule(L, Charge, OPENING, "open with Charge")
	end
	rule(L, ATTACK, TARGET, "start attacking", true)
	rule(L, Pummel, all(TARGET, { "targetcasting" }), "interrupt the cast")
	rule(L, ShieldBash, all(TARGET, { "targetcasting" }), "interrupt the cast")
	-- Free, and it heals: the game lights it for 20 seconds after a kill.
	rule(L, VictoryRush, TARGET, "you just made a kill: free, and it heals you")
	rule(L, Bloodrage, all(FIGHTING, test("power<", 20), { "maybe", test("health%>=", 50) }), "rage is low")
	rule(L, BerserkerRage, all(FIGHTING, test("power<", 40)), "free rage")
	-- Two or more enemies in reach change the fight.
	if c.has(ThunderClap) or c.has(Cleave) or c.has(Sweeping) or c.has(Whirlwind) then
		c.note("With two or more enemies in reach: Sweeping Strikes, Thunder Clap, Whirlwind, and Cleave in place of Heroic Strike."
			.. (c.talent("Improved Thunder Clap") > 0 and " Your Improved Thunder Clap makes it worth keeping up." or ""))
	end
	rule(L, Sweeping, all(FIGHTING, CROWD), "two or more: your swings hit a second enemy")
	rule(L, ThunderClap, all(FIGHTING, CROWD, no(debuff(ThunderClap, 20))), "two or more: slow their attacks")
	if tank then rule(L, DemoShout, all(FIGHTING, any(ELITE, PACK), no(debuff(DemoShout, 28))), "an elite, or three or more: weaken them") end
	rule(L, Execute, all(TARGET, { "maybe", test("target%<", 20) }), "the target is nearly dead")
	rule(L, Overpower, TARGET, "the target dodged")
	-- Its own entry, apart from the Whirlwind the numbers rank further down.
	rule(L, { 1680, "Whirlwind" }, all(FIGHTING, CROWD), "two or more: hits them all")
	if tank then
		if c.gear.shield then
			c.note("Shield equipped: Shield Block whenever it is up (it sets up Revenge), then Revenge, Shield Slam, and Sunder Armor stacked to five between them.")
			rule(L, ShieldBlock, FIGHTING, "whenever it is up: it sets up Revenge")
		else
			c.note((c.spec == 3 and "Protection talents, but no shield equipped" or "Defensive Stance, no shield")
				.. ": Revenge comes first and Sunder Armor is stacked to five. Shield Block and Shield Slam need a shield"
				.. (c.talent("Shield Specialization") > 0 and ", and your Shield Specialization gives nothing without one." or "."))
		end
		rule(L, Revenge, TARGET, "you blocked, dodged or parried")
		rule(L, ShieldSlam, TARGET, "main strike")
		-- To five, then again before it fades.
		rule(L, Sunder, all(FIGHTING, any({ "stacks<", Sunder, 5, 30 }, { "fading", Sunder, 4.5, 30 })), "stack it to five: threat, and its armour down")
		-- On something that lasts, its attacks are worth slowing: Thunder
		-- Clap works in Defensive Stance in Forever.
		rule(L, { 6343, "Thunder Clap" }, all(FIGHTING, ELITE, no(debuff(ThunderClap, 20))), "elite: slow its attacks")
	else
		rule(L, Revenge, TARGET, "you blocked, dodged or parried")
	end
	rule(L, MortalStrike, TARGET, "main strike")
	rule(L, Bloodthirst, TARGET, "main strike")
	if not tank then rule(L, ShieldSlam, TARGET, "main strike") end
	rule(L, Spearing, TARGET, "off cooldown")
	-- Slam is only worth its cast once Improved Slam stops it resetting the swing.
	if c.talent("Improved Slam") > 0 then
		c.note("Improved Slam: Slam between swings, when the main strike is on cooldown.")
		rule(L, Slam, all(FIGHTING, no({ "moving" })), "between swings")
	end
	rule(L, Whirlwind, TARGET, "off cooldown")
	-- Rend pays for itself over a long fight; with a main strike it only
	-- stays on the list when talents improve it.
	if not strike or c.talent("Improved Rend") > 0 then
		rule(L, Rend, all(FIGHTING, no(debuff(Rend, 15)), { "maybe", test("target%>=", 35) }), "bleed for the rest of the fight")
	else
		c.note("Rend is left out: your main strike is the better use of the rage.")
	end
	if not tank then rule(L, Sunder, all(FIGHTING, ELITE, no(debuff(Sunder, 25))), "elite: wear its armour down") end
	-- A tank on a long fight keeps the threat coming once the stack is full.
	if tank then rule(L, { 7386, "Sunder Armor" }, all(FIGHTING, ELITE, test("power>=", 30)), "elite: more threat while there is the rage") end
	rule(L, Cleave, all(FIGHTING, CROWD, test("power>=", crowdSpare)), "spare rage, two enemies", true)
	rule(L, HeroicStrike, all(FIGHTING, test("power>=", spare)), "spare rage", true)
	-- Slam is not ranked with them: with no cooldown, its damage for the
	-- rage would put it ahead of the strike it is meant to fill in behind.
	ranked(L, MortalStrike, Bloodthirst, ShieldSlam, Spearing, Whirlwind, Rend)
	reactions(L, Overpower, Revenge, VictoryRush)
	return L
end

---------------------------------------------------------------------------
-- Paladin
---------------------------------------------------------------------------

function Classes.PALADIN(c)
	local L = {}
	local Might, Wisdom = { 19740, "Blessing of Might" }, { 19742, "Blessing of Wisdom" }
	local Righteousness, Command, Crusader = { 21084, "Seal of Righteousness" }, { 20375, "Seal of Command" }, { 21082, "Seal of the Crusader" }
	local Judgement, HammerOfWrath, Exorcism = { 20271, "Judgement" }, { 24275, "Hammer of Wrath" }, { 879, "Exorcism" }
	local HolyLight, FlashOfLight, HammerOfJustice = { 635, "Holy Light" }, { 19750, "Flash of Light" }, { 853, "Hammer of Justice" }
	local HolyShield, Consecration = { 20925, "Holy Shield" }, { 26573, "Consecration" }
	-- Forever: Holy Strike for every paladin, Seal of Fury for a tank (its
	-- Judgement is the taunt), and Swift Judgement to judge again at once.
	local HolyStrike, SealOfFury, SwiftJudgement = { nil, "Holy Strike" }, { nil, "Seal of Fury" }, { nil, "Swift Judgement" }

	local tank = c.spec == 2 or c.gear.shield
	-- Seal of Command hits on a chance per swing, so it wants a slow two-hander.
	local seal = Righteousness
	if tank and c.has(SealOfFury) then
		seal = SealOfFury
		c.note("Seal of Fury for tanking: it shields you, and its Judgement taunts.")
	elseif c.has(Command) and c.gear.twoHand then
		seal = Command
		c.note("Seal of Command with your two-hander.")
	elseif c.has(Command) then
		c.note("Seal of Righteousness: Seal of Command wants a slow two-hander.")
	end
	local sealed = any(buff(Righteousness, 28), buff(Command, 28), buff(Crusader, 28), buff(SealOfFury, 28))

	rule(L, HolyLight, all(test("health%<", 35), no({ "moving" })), "you are low")
	rule(L, FlashOfLight, all(test("health%<", 35), no({ "moving" })), "you are low")
	rule(L, Might, no(any(buff(Might, 280), buff(Wisdom, 280))), "no blessing up")
	rule(L, seal, all(TARGET, no(sealed)), "no seal up")
	rule(L, ATTACK, TARGET, "start attacking", true)
	rule(L, HammerOfJustice, all(TARGET, { "targetcasting" }), "stop the cast")
	if tank then rule(L, HolyShield, all(FIGHTING, no(buff(HolyShield, 9))), "you are up front: keep it up") end
	rule(L, HammerOfWrath, all(TARGET, { "maybe", test("target%<", 20) }), "the target is nearly dead")
	rule(L, HolyStrike, TARGET, "off cooldown")
	rule(L, Judgement, all(FIGHTING, sealed, reserve(35)), "unleash the seal, then seal again")
	rule(L, SwiftJudgement, all(FIGHTING, sealed, no({ "ready", Judgement })), "Judgement again, at once")
	rule(L, Exorcism, all(TARGET, reserve(40)), "undead or demon")
	if tank then
		rule(L, Consecration, all(FIGHTING, reserve(40)), "hold them on you")
	else
		rule(L, Consecration, all(FIGHTING, any(ELITE, CROWD), reserve(50)), "an elite, or two or more: ground them")
	end
	ranked(L, HolyStrike, Exorcism)
	return L
end

---------------------------------------------------------------------------
-- Hunter
---------------------------------------------------------------------------

function Classes.HUNTER(c)
	local L = {}
	local Hawk, Monkey, CallPet, MendPet = { 13165, "Aspect of the Hawk" }, { 13163, "Aspect of the Monkey" }, { 883, "Call Pet" }, { 136, "Mend Pet" }
	local Mark, AutoShot, Serpent = { 1130, "Hunter's Mark" }, { 75, "Auto Shot" }, { 1978, "Serpent Sting" }
	local Aimed, Multi, Arcane = { 19434, "Aimed Shot" }, { 2643, "Multi-Shot" }, { 3044, "Arcane Shot" }
	local Raptor, Mongoose = { 2973, "Raptor Strike" }, { 1495, "Mongoose Bite" }
	local Bestial, RapidFire = { 19574, "Bestial Wrath" }, { 3045, "Rapid Fire" }
	-- Forever: Aimed Shot for every hunter at 20, sharing its cooldown with
	-- Multi-Shot; Sniper Shot (Marksmanship), Summon Hawk (Beast Mastery,
	-- on Arcane Shot's cooldown) and Strider Kick (Survival, in melee).
	local Sniper, SummonHawk, StriderKick = { nil, "Sniper Shot" }, { nil, "Summon Hawk" }, { nil, "Strider Kick" }

	if not c.gear.rangedWeapon then c.note("No bow, gun or crossbow equipped: only the melee abilities will come up.") end
	if c.has(Aimed) and c.has(Multi) then c.note("Aimed Shot and Multi-Shot share a cooldown in Forever: Aimed Shot opens the fight, Multi-Shot is used during it.") end

	rule(L, Hawk, no(any(buff(Hawk), buff(Monkey))), "no aspect up")
	rule(L, CallPet, all(no({ "pet" }), no(COMBAT)), "your pet is not out")
	rule(L, MendPet, all({ "pet" }, test("pet%<", 40), no(buff(MendPet, 5))), "your pet is low")
	-- Before the fight its cast costs nothing; in one, the cooldown it
	-- shares is better spent on Multi-Shot, which is instant.
	rule(L, Aimed, all(OPENING, no({ "moving" })), "open with Aimed Shot")
	rule(L, Mark, all(TARGET, no(debuff(Mark, 110)), { "maybe", test("target%>=", 60) }), "mark the target")
	rule(L, AutoShot, TARGET, "start shooting", true)
	rule(L, Bestial, all(FIGHTING, ELITE), "elite: burn it")
	rule(L, RapidFire, all(FIGHTING, ELITE), "elite: burn it")
	rule(L, Serpent, all(TARGET, no(debuff(Serpent, 15)), { "maybe", test("target%>=", 30) }), "keep the sting on")
	rule(L, Sniper, all(TARGET, no({ "moving" })), "off cooldown")
	rule(L, Multi, TARGET, "off cooldown")
	rule(L, SummonHawk, TARGET, "a hawk at your side")
	rule(L, Arcane, all(TARGET, reserve(40)), "off cooldown")
	-- In melee the shots are out of range and these are in.
	local MELEE = all(TARGET, { "maybe", { "melee" } })
	rule(L, Mongoose, MELEE, "you dodged")
	rule(L, StriderKick, MELEE, "in melee")
	rule(L, Raptor, MELEE, "in melee", true)
	rule(L, ATTACK, MELEE, "in melee", true)
	ranked(L, Sniper, Multi, Arcane)
	reactions(L, Mongoose)
	return L
end

---------------------------------------------------------------------------
-- Rogue
---------------------------------------------------------------------------

function Classes.ROGUE(c)
	local L = {}
	local Sinister, Backstab, Eviscerate, SliceAndDice = { 1752, "Sinister Strike" }, { 53, "Backstab" }, { 2098, "Eviscerate" }, { 5171, "Slice and Dice" }
	local Ambush, Garrote, CheapShot, Kick = { 8676, "Ambush" }, { 703, "Garrote" }, { 1833, "Cheap Shot" }, { 1766, "Kick" }
	local Hemorrhage, Ghostly, Riposte = { 16511, "Hemorrhage" }, { 14278, "Ghostly Strike" }, { 14251, "Riposte" }
	local BladeFlurry, Adrenaline, Evasion, Rupture = { 13877, "Blade Flurry" }, { 13750, "Adrenaline Rush" }, { 5277, "Evasion" }, { 1943, "Rupture" }
	local Mutilate, ColdBlood = { nil, "Mutilate" }, { 14177, "Cold Blood" }
	-- Forever: Shank, for when the energy runs low, and Subtlety's Death Mark.
	local Shank, DeathMark = { nil, "Shank" }, { nil, "Death Mark" }

	local opener = all({ "stealth" }, TARGET)
	if c.gear.dagger then
		rule(L, Ambush, opener, "open from stealth, from behind")
		c.note("Dagger in the main hand: Ambush opens, and Backstab is listed for when you are behind the target.")
	end
	rule(L, CheapShot, opener, "open from stealth")
	rule(L, Garrote, opener, "open from stealth")
	rule(L, ATTACK, TARGET, "start attacking", true)
	rule(L, Kick, all(TARGET, { "targetcasting" }), "interrupt the cast")
	rule(L, Evasion, all(FIGHTING, test("health%<", 40)), "you are low")
	rule(L, Riposte, TARGET, "you parried")
	rule(L, BladeFlurry, all(FIGHTING, any(ELITE, CROWD)), "an elite, or two or more: burn")
	rule(L, Adrenaline, all(FIGHTING, ELITE), "elite: burn it")
	-- Finishers: Slice and Dice early in a fight that will last, Rupture on
	-- an elite (or always, for Subtlety's bleeds), Eviscerate at five points
	-- or to finish.
	rule(L, SliceAndDice, all(TARGET, test("combo>=", 1), no(buff(SliceAndDice, 9)), { "maybe", test("target%>=", 50) }), "attack speed for the fight")
	if c.has(Shank) then c.note("Shank is listed for when the energy is low, as the guides for Forever use it.") end
	rule(L, Shank, all(FIGHTING, test("power<", c.spec == 2 and 55 or 70)), "energy is low")
	if c.spec == 3 then
		rule(L, Rupture, all(TARGET, test("combo>=", 5), no(debuff(Rupture, 12)), { "maybe", test("target%>=", 50) }), "keep the bleed on")
	else
		rule(L, Rupture, all(TARGET, ELITE, test("combo>=", 5), no(debuff(Rupture, 12))), "elite: bleed it")
	end
	rule(L, DeathMark, all(TARGET, test("combo>=", 5)), "at five points")
	rule(L, ColdBlood, all(TARGET, test("combo>=", 5)), "with the finisher")
	rule(L, Eviscerate, all(TARGET, any(test("combo>=", 5), all(test("combo>=", 3), test("target%<", 35)))), "finish")
	rule(L, Ghostly, TARGET, "off cooldown")
	if c.gear.dagger then rule(L, Mutilate, TARGET, "builder: two points") end
	rule(L, Hemorrhage, TARGET, "builder")
	rule(L, Sinister, TARGET, "builder")
	-- With no Sinister Strike to fall back on, Backstab is the builder.
	if c.gear.dagger then rule(L, Backstab, TARGET, "builder, from behind") end
	ranked(L, Ghostly, Mutilate, Hemorrhage, Sinister)
	reactions(L, Riposte)
	return L
end

---------------------------------------------------------------------------
-- Priest
---------------------------------------------------------------------------

function Classes.PRIEST(c)
	local L = {}
	local Fortitude, InnerFire, Shield, WeakenedSoul = { 1243, "Power Word: Fortitude" }, { 588, "Inner Fire" }, { 17, "Power Word: Shield" }, { 6788, "Weakened Soul" }
	local Pain, MindBlast, Smite, HolyFire = { 589, "Shadow Word: Pain" }, { 8092, "Mind Blast" }, { 585, "Smite" }, { 14914, "Holy Fire" }
	local MindFlay, Shadowform, Embrace, Plague = { 15407, "Mind Flay" }, { 15473, "Shadowform" }, { 15286, "Vampiric Embrace" }, { 2944, "Devouring Plague" }
	local FlashHeal, Heal, LesserHeal, Penance = { 2061, "Flash Heal" }, { 2054, "Heal" }, { 2050, "Lesser Heal" }, { nil, "Penance" }
	-- Forever: Shadow Word: Death for every priest at 32 (it bites back if
	-- the target lives), and Devouring Plague for every race at 20.
	local Death = { 32379, "Shadow Word: Death" }

	local shadow = c.spec == 3 or c.has(MindFlay)
	c.note(shadow and "Shadow: Mind Flay is the filler." or "Smite is the filler until you have Mind Flay.")

	rule(L, FlashHeal, all(test("health%<", 35), no({ "moving" })), "you are low")
	rule(L, Heal, all(test("health%<", 35), no({ "moving" })), "you are low")
	rule(L, LesserHeal, all(test("health%<", 35), no({ "moving" })), "you are low")
	rule(L, Fortitude, no(buff(Fortitude, 1700)), "keep Fortitude up")
	rule(L, InnerFire, no(buff(InnerFire, 590)), "keep Inner Fire up")
	rule(L, Shadowform, no(buff(Shadowform)), "back into Shadowform")
	rule(L, Shield, all(TARGET, no(buff(Shield, 15)), no({ "selfdebuff", WeakenedSoul }), reserve(30)), "shield before the hits land")
	if not shadow then rule(L, HolyFire, all(OPENING, no({ "moving" })), "open with Holy Fire") end
	rule(L, MindBlast, all(OPENING, no({ "moving" })), "open with Mind Blast")
	rule(L, Pain, all(TARGET, no(debuff(Pain, 17)), { "maybe", test("target%>=", 25) }), "keep Pain on")
	rule(L, Plague, all(FIGHTING, no(debuff(Plague, 23)), { "maybe", test("target%>=", 50) }), "off cooldown")
	rule(L, Penance, all(TARGET, no({ "moving" })), "off cooldown")
	rule(L, MindBlast, all(TARGET, reserve(30), no({ "moving" })), "off cooldown")
	rule(L, Death, all(FIGHTING, { "maybe", test("health%>=", 50) }), "instant: it costs you health if the target lives")
	-- Thirty seconds on a minute's cooldown in Forever: for a fight that lasts.
	rule(L, Embrace, all(FIGHTING, no(debuff(Embrace, 30)), { "maybe", test("target%>=", 50) }), "heal from your damage")
	if shadow then
		rule(L, MindFlay, all(TARGET, reserve(40), no({ "moving" })), "filler")
	else
		rule(L, Smite, all(TARGET, reserve(50), no({ "moving" })), "filler")
	end
	wand(L, c)
	if not c.gear.wand then rule(L, Smite, all(TARGET, no({ "moving" })), "filler") end
	ranked(L, Pain, Plague, Penance)
	return L
end

---------------------------------------------------------------------------
-- Mage
---------------------------------------------------------------------------

function Classes.MAGE(c)
	local L = {}
	local Intellect, MageArmor, IceArmor, FrostArmor = { 1459, "Arcane Intellect" }, { 6117, "Mage Armor" }, { 7302, "Ice Armor" }, { 168, "Frost Armor" }
	local Frostbolt, Fireball, FireBlast, Missiles = { 116, "Frostbolt" }, { 133, "Fireball" }, { 2136, "Fire Blast" }, { 5143, "Arcane Missiles" }
	local Pyroblast, Scorch, IceBarrier, Counterspell = { 11366, "Pyroblast" }, { 2948, "Scorch" }, { 11426, "Ice Barrier" }, { 2139, "Counterspell" }
	local Combustion, ArcanePower, Evocation = { 11129, "Combustion" }, { 12042, "Arcane Power" }, { 12051, "Evocation" }
	local ArcaneBlast = { nil, "Arcane Blast" }
	-- Forever's procs: Fingers of Frost for an Ice Lance, three Heating Up
	-- for a quick Pyroblast, Missile Barrage for Arcane Missiles; and Arcane
	-- Wrath once Arcane Blast is stacked, and Frostfire Bolt for all at 40.
	local IceLance, FingersOfFrost, HeatingUp = { 30455, "Ice Lance" }, { nil, "Fingers of Frost" }, { nil, "Heating Up" }
	local MissileBarrage, ArcaneWrath, Frostfire = { nil, "Missile Barrage" }, { nil, "Arcane Wrath" }, { nil, "Frostfire Bolt" }

	-- The filler follows the talents: the tree with the most points.
	local nuke, why
	if c.spec == 2 then
		nuke, why = Fireball, "Fire talents: Fireball is the filler."
	elseif c.spec == 1 then
		nuke = (c.has(ArcaneBlast) and ArcaneBlast) or (c.has(Missiles) and Missiles) or Frostbolt
		why = "Arcane talents: " .. (ns.SpellName(nuke) or "Arcane Missiles") .. " is the filler."
	elseif c.spec == 3 then
		nuke, why = Frostbolt, "Frost talents: Frostbolt is the filler."
	else
		nuke = c.has(Frostbolt) and Frostbolt or Fireball
		why = "No talents yet: " .. (c.has(Frostbolt) and "Frostbolt, for the slow." or "Fireball until you learn Frostbolt.")
	end
	c.note(why)
	local still = no({ "moving" })
	local armored = any(buff(MageArmor), buff(IceArmor), buff(FrostArmor))

	rule(L, Intellect, no(buff(Intellect, 1700)), "keep Arcane Intellect up")
	rule(L, MageArmor, no(armored), "no armor spell up")
	rule(L, IceArmor, no(armored), "no armor spell up")
	rule(L, FrostArmor, no(armored), "no armor spell up")
	rule(L, Evocation, all(test("mana%<", 15), still), "out of mana")
	rule(L, Counterspell, all(TARGET, { "targetcasting" }), "interrupt the cast")
	rule(L, IceBarrier, all(FIGHTING, no(buff(IceBarrier, 55))), "shield up")
	rule(L, { 122, "Frost Nova" }, all(FIGHTING, CROWD), "two or more on you: root them and step back")
	rule(L, { 1449, "Arcane Explosion" }, all(FIGHTING, PACK, reserve(30)), "three or more on you")
	if nuke == Fireball then rule(L, Pyroblast, all(OPENING, still), "open with Pyroblast") end
	rule(L, Combustion, all(FIGHTING, ELITE), "elite: burn it")
	rule(L, ArcanePower, all(FIGHTING, ELITE), "elite: burn it")
	-- What a proc makes worth pressing comes before the filler.
	if c.has(IceLance) or c.has(Pyroblast) or c.has(ArcaneBlast) then
		c.note("Procs come first when the game shows them: Ice Lance on Fingers of Frost, Pyroblast at three Heating Up, Arcane Missiles on Missile Barrage.")
	end
	rule(L, { 11366, "Pyroblast" }, all(TARGET, still, proc(Pyroblast, HeatingUp, 3)), "three Heating Up: a quick Pyroblast")
	rule(L, IceLance, all(TARGET, proc(IceLance, FingersOfFrost)), "Fingers of Frost: it hits as if the target were frozen")
	rule(L, { 5143, "Arcane Missiles" }, all(TARGET, still, proc(Missiles, MissileBarrage)), "Missile Barrage: quicker and cheaper")
	rule(L, ArcaneWrath, all(TARGET, still, { "charges>=", ArcaneBlast, 3 }), "Arcane Blast is stacked: spend it")
	if c.spec == 2 then
		-- Fire wants its crits: on cooldown, for Heating Up.
		rule(L, FireBlast, FIGHTING, "on cooldown: it feeds Heating Up")
	else
		-- Fire Blast is instant: on the move, or to finish.
		rule(L, FireBlast, all(FIGHTING, any({ "moving" }, test("target%<", 25))), "instant: moving, or to finish")
	end
	rule(L, nuke, all(TARGET, still, reserve(15)), "filler")
	if nuke == Fireball then rule(L, Frostfire, all(TARGET, still, reserve(15)), "filler") end
	if nuke ~= Frostbolt then rule(L, Frostbolt, all(TARGET, still, reserve(15)), "filler") end
	if nuke ~= Fireball then rule(L, Fireball, all(TARGET, still, reserve(15)), "filler") end
	rule(L, Scorch, all(TARGET, still), "cheap filler")
	wand(L, c)
	ranked(L, nuke, Frostfire, Frostbolt, Fireball)
	return L
end

---------------------------------------------------------------------------
-- Warlock
---------------------------------------------------------------------------

function Classes.WARLOCK(c)
	local L = {}
	local DemonArmor, DemonSkin, Voidwalker, Imp = { 706, "Demon Armor" }, { 687, "Demon Skin" }, { 697, "Summon Voidwalker" }, { 688, "Summon Imp" }
	-- Forever renames the damaging curses to banes: one bane and one curse
	-- can be on a target together.
	local Agony, Doom = { 980, "Bane of Agony" }, { 603, "Bane of Doom" }
	local Corruption, Immolate, ShadowBolt = { 172, "Corruption" }, { 348, "Immolate" }, { 686, "Shadow Bolt" }
	local LifeTap, DrainLife, SiphonLife, HealthFunnel = { 1454, "Life Tap" }, { 689, "Drain Life" }, { 18265, "Siphon Life" }, { 755, "Health Funnel" }
	local Shadowburn, Conflagrate, SoulFire = { 17877, "Shadowburn" }, { 17962, "Conflagrate" }, { 6353, "Soul Fire" }
	-- Forever: Affliction's Wrack (a channel that hurries the effects on the
	-- target), Destruction's Incinerate, and the Nightfall proc's instant
	-- Shadow Bolt.
	local Wrack, Incinerate, ShadowTrance = { nil, "Wrack" }, { nil, "Incinerate" }, { 17941, "Shadow Trance" }

	local still = no({ "moving" })
	local armored = any(buff(DemonArmor), buff(DemonSkin))
	-- Immolate costs a cast: worth it for Destruction (Conflagrate and
	-- Incinerate want it on the target), and before Corruption exists.
	local immolate = c.spec == 3 or not c.has(Corruption) or c.has(Incinerate) or c.has(Conflagrate)
	c.note(immolate and "Immolate is on the list (Destruction, or no Corruption yet)." or "Immolate is left out: the instant effects do more for the mana.")

	rule(L, DemonArmor, no(armored), "no armor spell up")
	rule(L, DemonSkin, no(armored), "no armor spell up")
	rule(L, Voidwalker, all(no({ "pet" }), no(COMBAT), still), "your demon is not out")
	rule(L, Imp, all(no({ "pet" }), no(COMBAT), still), "your demon is not out")
	rule(L, LifeTap, all(test("mana%<", 40), { "maybe", test("health%>=", 60) }), "trade health for mana")
	rule(L, HealthFunnel, all({ "pet" }, test("pet%<", 35), { "maybe", test("health%>=", 60) }, still), "your demon is low")
	rule(L, Shadowburn, all(TARGET, test("target%<", 20)), "finish")
	rule(L, { 686, "Shadow Bolt" }, all(TARGET, proc(ShadowBolt, ShadowTrance)), "Nightfall: an instant Shadow Bolt")
	-- A bane: Doom on something that will live the minute it takes, else Agony.
	rule(L, Doom, all(TARGET, ELITE, no(debuff(Doom, 60)), no(debuff(Agony, 23)), { "maybe", test("target%>=", 60) }), "elite: it lands after a minute")
	rule(L, Agony, all(TARGET, no(debuff(Agony, 23)), no(debuff(Doom, 60)), { "maybe", test("target%>=", 30) }), "keep the bane on")
	rule(L, Corruption, all(TARGET, no(debuff(Corruption, 17)), { "maybe", test("target%>=", 25) }), "keep Corruption on")
	rule(L, SiphonLife, all(TARGET, no(debuff(SiphonLife, 29)), { "maybe", test("target%>=", 40) }), "keep Siphon Life on")
	if immolate then rule(L, Immolate, all(TARGET, still, no(debuff(Immolate, 14)), { "maybe", test("target%>=", 40) }), "keep Immolate on") end
	rule(L, Conflagrate, all(TARGET, debuff(Immolate, 14)), "Immolate is on it")
	if c.talent("Decimation") > 0 then
		rule(L, SoulFire, all(TARGET, still, test("target%<", 35)), "Decimation: quick, and no shard, under 35%")
	end
	rule(L, DrainLife, all(TARGET, still, test("health%<", 50)), "you are low: drain")
	rule(L, Wrack, all(TARGET, still, debuff(Agony, 23), debuff(Corruption, 17)), "your effects on it tick twice as fast")
	rule(L, Incinerate, all(TARGET, still, reserve(35)), "filler")
	rule(L, ShadowBolt, all(TARGET, still, reserve(35)), "filler")
	wand(L, c)
	if not c.gear.wand then rule(L, ShadowBolt, all(TARGET, still), "filler") end
	ranked(L, Agony, Corruption, SiphonLife, Immolate)
	return L
end

---------------------------------------------------------------------------
-- Shaman
---------------------------------------------------------------------------

function Classes.SHAMAN(c)
	local L = {}
	local LightningShield, WaterShield = { 324, "Lightning Shield" }, { nil, "Water Shield" }
	local Windfury, Rockbiter, Flametongue = { 8232, "Windfury Weapon" }, { 8017, "Rockbiter Weapon" }, { 8024, "Flametongue Weapon" }
	local Bolt, EarthShock, FlameShock, Chain = { 403, "Lightning Bolt" }, { 8042, "Earth Shock" }, { 8050, "Flame Shock" }, { 421, "Chain Lightning" }
	local Stormstrike, Mastery, LesserWave, Wave = { 17364, "Stormstrike" }, { 16166, "Elemental Mastery" }, { 8004, "Lesser Healing Wave" }, { 331, "Healing Wave" }
	local LavaBurst = { nil, "Lava Burst" }
	-- Forever: Maelstrom Weapon (five stacks make a quick Lightning Bolt),
	-- a Fire Nova that goes off through the fire totem, and Enhancement's
	-- Rage of the Farseer.
	local Maelstrom, FireNova, Farseer = { nil, "Maelstrom Weapon" }, { nil, "Fire Nova" }, { nil, "Rage of the Farseer" }

	-- Elemental and Restoration stand back and cast; everyone else swings.
	local caster = c.spec == 1 or c.spec == 3
	local still = no({ "moving" })
	local shielded = any(buff(LightningShield, 590), buff(WaterShield, 590))

	rule(L, LesserWave, all(test("health%<", 35), still), "you are low")
	rule(L, Wave, all(test("health%<", 35), still), "you are low")
	if caster then
		c.note("Casting talents: Flametongue on the weapon, Lightning Bolt as the filler.")
		rule(L, WaterShield, no(shielded), "no shield up")
		rule(L, LightningShield, no(shielded), "no shield up")
		rule(L, Flametongue, no({ "imbue" }), "no weapon enchant")
		rule(L, Rockbiter, no({ "imbue" }), "no weapon enchant")
		rule(L, EarthShock, all(TARGET, { "targetcasting" }), "interrupt the cast")
		rule(L, Mastery, FIGHTING, "off cooldown")
		rule(L, FlameShock, all(TARGET, no(debuff(FlameShock, 11)), reserve(30), { "maybe", test("target%>=", 40) }), "keep Flame Shock on")
		rule(L, LavaBurst, all(TARGET, still), "off cooldown: best with Flame Shock on")
		rule(L, Chain, all(TARGET, still, reserve(40)), "off cooldown")
		rule(L, Bolt, all(TARGET, still), "filler")
	else
		c.note(c.has(Windfury) and "Melee: Windfury on the weapon." or "Melee: Rockbiter on the weapon until you learn Windfury.")
		rule(L, LightningShield, no(shielded), "no shield up")
		rule(L, Windfury, no({ "imbue" }), "no weapon enchant")
		rule(L, Rockbiter, no({ "imbue" }), "no weapon enchant")
		rule(L, Flametongue, no({ "imbue" }), "no weapon enchant")
		rule(L, Bolt, all(OPENING, still), "pull with Lightning Bolt")
		rule(L, ATTACK, TARGET, "start attacking", true)
		rule(L, EarthShock, all(TARGET, { "targetcasting" }), "interrupt the cast")
		rule(L, Farseer, all(FIGHTING, ELITE), "elite: burn it")
		rule(L, { 403, "Lightning Bolt" }, all(TARGET, proc(Bolt, Maelstrom, 5)), "five Maelstrom Weapon: a quick Lightning Bolt")
		rule(L, Stormstrike, TARGET, "off cooldown")
		rule(L, FlameShock, all(FIGHTING, no(debuff(FlameShock, 11)), reserve(40), { "maybe", test("target%>=", 40) }), "keep Flame Shock on")
		rule(L, EarthShock, all(FIGHTING, reserve(60)), "mana to spare")
		rule(L, FireNova, all(FIGHTING, CROWD, reserve(40)), "two or more: through your fire totem")
	end
	if c.has({ nil, "Call of the Elements" }) then c.note("Totems are yours to place: Call of the Elements drops all four at once.") end
	ranked(L, FlameShock, LavaBurst, Chain, Stormstrike)
	return L
end

---------------------------------------------------------------------------
-- Druid
---------------------------------------------------------------------------

function Classes.DRUID(c)
	local L = {}
	local Mark, Thorns, Regrowth, HealingTouch = { 1126, "Mark of the Wild" }, { 467, "Thorns" }, { 8936, "Regrowth" }, { 5185, "Healing Touch" }
	local CatForm, BearForm, DireBear, Moonkin = { 768, "Cat Form" }, { 5487, "Bear Form" }, { 9634, "Dire Bear Form" }, { 24858, "Moonkin Form" }
	local Claw, Rake, Bite, Rip, Pounce = { 1082, "Claw" }, { 1822, "Rake" }, { 22568, "Ferocious Bite" }, { 1079, "Rip" }, { 9005, "Pounce" }
	local Maul, Swipe, Enrage, Bash, Roar = { 6807, "Maul" }, { 779, "Swipe" }, { 5229, "Enrage" }, { 5211, "Bash" }, { 99, "Demoralizing Roar" }
	local Moonfire, Wrath, Starfire, Swarm = { 8921, "Moonfire" }, { 5176, "Wrath" }, { 2912, "Starfire" }, { 5570, "Insect Swarm" }
	-- Forever: Tiger's Fury is gone (Shifting Power turns mana into energy
	-- instead), a bear has Primal Bite in Mangle's place and Lacerate to
	-- stack, Faerie Fire is free in form, Omen of Clarity is every druid's,
	-- and Balance is built on Eclipse.
	local ShiftingPower, PrimalBite, Lacerate = { nil, "Shifting Power" }, { nil, "Primal Bite" }, { nil, "Lacerate" }
	local Shred, Clearcasting, FaerieFire = { 5221, "Shred" }, { 16870, "Clearcasting" }, { 16857, "Faerie Fire (Feral)" }
	local Frenzied, Eclipse = { 22842, "Frenzied Regeneration" }, { nil, "Eclipse" }

	local CAT, BEAR = { "form", 1 }, any({ "form", 5 }, { "form", 8 })
	local shifted = any(CAT, BEAR, { "form", 31 })
	local still = no({ "moving" })
	-- Feral once the talents say so, or once there is a cat form and the
	-- talents do not say otherwise.
	local feral = c.spec == 2 or (c.spec == nil and c.has(CatForm))

	-- Out of form: heal, buff. In form the game marks these unusable.
	rule(L, Regrowth, all(test("health%<", 35), still, no(shifted)), "you are low")
	rule(L, HealingTouch, all(test("health%<", 35), still, no(shifted)), "you are low")
	rule(L, Mark, all(no(buff(Mark, 1700)), no(shifted)), "keep Mark of the Wild up")
	rule(L, Thorns, all(no(buff(Thorns, 590)), no(shifted)), "keep Thorns up")

	if feral then
		c.note("Feral: Cat Form for the fight; the bear abilities are listed for when you are in Bear Form.")
		rule(L, CatForm, all(TARGET, no(shifted)), "into Cat Form")
		if not c.has(CatForm) then rule(L, BearForm, all(TARGET, no(shifted)), "into Bear Form") end
		-- Cat
		rule(L, Pounce, all(CAT, { "stealth" }, TARGET), "open from stealth")
		rule(L, ATTACK, all(shifted, TARGET), "start attacking", true)
		rule(L, FaerieFire, all(any(CAT, BEAR), FIGHTING, no(debuff(FaerieFire, 40))), "free in form: its armour down")
		rule(L, Shred, all(CAT, TARGET, proc(Shred, Clearcasting)), "Omen of Clarity: a free Shred")
		rule(L, ShiftingPower, all(CAT, FIGHTING, test("power<", 60)), "energy is low: mana for energy")
		rule(L, Rip, all(CAT, TARGET, ELITE, test("combo>=", 5), no(debuff(Rip, 11))), "elite: bleed it")
		rule(L, Bite, all(CAT, TARGET, any(test("combo>=", 5), all(test("combo>=", 3), test("target%<", 30)))), "finish")
		rule(L, Rake, all(CAT, TARGET, no(debuff(Rake, 8)), { "maybe", test("target%>=", 40) }), "keep Rake on")
		rule(L, Claw, all(CAT, TARGET), "builder")
		-- Bear
		rule(L, Bash, all(BEAR, TARGET, { "targetcasting" }), "stop the cast")
		rule(L, Frenzied, all(BEAR, FIGHTING, test("health%<", 40)), "you are low")
		rule(L, Enrage, all(BEAR, FIGHTING, test("power<", 10), { "maybe", test("health%>=", 60) }), "rage is low")
		rule(L, Roar, all(BEAR, FIGHTING, ELITE, no(debuff(Roar, 28))), "elite: weaken it")
		rule(L, Lacerate, all(BEAR, FIGHTING, any({ "stacks<", Lacerate, 5, 15 }, { "fading", Lacerate, 4.5, 15 })), "stack it to five: threat, and it bleeds")
		rule(L, PrimalBite, all(BEAR, TARGET), "off cooldown")
		rule(L, Swipe, all(BEAR, FIGHTING, CROWD, test("power>=", 20)), "two or more: hits them all")
		rule(L, Swipe, all(BEAR, FIGHTING, test("power>=", 40)), "spare rage")
		rule(L, Maul, all(BEAR, FIGHTING, test("power>=", 15)), "spare rage", true)
	else
		rule(L, Moonkin, no(buff(Moonkin)), "into Moonkin Form")
		rule(L, Swarm, all(TARGET, no(debuff(Swarm, 11)), { "maybe", test("target%>=", 30) }), "keep Insect Swarm on")
		rule(L, Moonfire, all(TARGET, no(debuff(Moonfire, 11)), { "maybe", test("target%>=", 30) }), "keep Moonfire on")
		if c.talent("Eclipse") > 0 then
			-- Wrath is cheap in Forever and quickens the Starfires after it.
			c.note("Eclipse: Wrath is the filler, and Starfire is cast while Eclipse makes it quick.")
			rule(L, Starfire, all(TARGET, still, { "charges>=", Eclipse, 1 }), "Eclipse: a quicker Starfire")
			rule(L, Wrath, all(TARGET, still), "filler: it builds Eclipse")
		else
			local filler = (c.has(Starfire) and (c.talent("Improved Starfire") > 0 or c.level >= 30)) and Starfire or Wrath
			c.note("Casting: " .. (filler == Starfire and "Starfire" or "Wrath") .. " is the filler.")
			rule(L, filler, all(TARGET, still), "filler")
			if filler ~= Wrath then rule(L, Wrath, all(TARGET, still), "filler") end
		end
		rule(L, Moonfire, all(FIGHTING, { "moving" }), "instant, on the move")
	end
	ranked(L, Swarm, Starfire, Wrath)
	return L
end

Classes.ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
