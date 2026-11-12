"""Runs the real PolestarNext add-on against a stand-in game and checks what it
suggests: per class, with talents and gear changing the list, with the game's
numbers ordering the damage abilities, and with the client keeping values
secret.

    python tests/next_addon.py

Needs Python with lupa (Lua 5.1, the game's Lua).
"""

import base64
import re
from pathlib import Path

from lupa.lua51 import LuaRuntime, lua_type

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "addon" / "PolestarNext"
FILES = [line.strip() for line in (ADDON / "PolestarNext.toc").read_text(encoding="utf-8").splitlines()
         if line.strip().endswith(".lua")]

# Every { id, "English name" } the class lists use, so the stand-in game knows
# the same spells by the same IDs.
CLASSES_SOURCE = (ADDON / "Classes.lua").read_text(encoding="utf-8")
NAMED = {int(i): name for i, name in re.findall(r'\{ (\d+), "([^"]+)" \}', CLASSES_SOURCE)}
NAME_ONLY = set(re.findall(r'\{ nil, "([^"]+)" \}', CLASSES_SOURCE))

GAME = r"""
W = {}            -- the world the tests set up
SPELLS = {}       -- id -> { name, desc, cost, cast (ms), cd (ms) }
FRAMES, SAID, REGIONS = {}, {}, {}

local function stub()
    local t = { scripts = {} }
    return setmetatable(t, { __index = function(_, k)
        if k == "SetScript" then return function(s, name, f) s.scripts[name] = f end end
        if k == "CreateTexture" or k == "CreateFontString" then return function() local r = stub(); REGIONS[#REGIONS + 1] = r; return r end end
        if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
        if k == "IsVisible" then return function(s) return s.hidden ~= true end end
        if k == "GetFrameLevel" then return function() return 1 end end
        if k == "SetPoint" then return function(s, _, anchor) s.anchor = anchor end end
        if k == "Show" then return function(s) s.up = true end end
        if k == "Hide" then return function(s) s.up = false end end
        if k == "SetText" then return function(s, v) s.text = v end end
        if k == "SetHeight" then return function(s, v) s.height = v end end
        if k == "SetTexture" then return function(s, v) s.tex = v end end
        if k == "SetAlpha" then return function(s, v) s.alpha = v end end
        if k == "RegisterEvent" then return function(s, e) if e == "ACTIVE_TALENT_GROUP_CHANGED" then error("unknown event") end end end
        return function() end
    end })
end
function CreateFrame() local f = stub(); FRAMES[#FRAMES + 1] = f; return f end
UIParent, GameTooltip, SlashCmdList = stub(), stub(), {}
function print(text) SAID[#SAID + 1] = tostring(text) end
function GetTime() return W.time end

SECRET = {}
function issecretvalue(v) return v == SECRET end
local function hide(v) if W.secret then return SECRET end return v end

Enum = { SpellBookItemType = { Spell = 1, FutureSpell = 2, PetAction = 3, Flyout = 4 }, SpellBookSpellBank = { Player = 0 } }

function world(class, level)
    W = { class = class, level = level, time = 100, book = {}, slots = {}, keys = {}, points = { 0, 0, 0 }, talents = {},
          worn = {}, power = 0, powerMax = 100, powerType = 1, health = 100, healthMax = 100, combo = 0, form = 0,
          auras = { player = {}, target = {} }, usable = {}, shortOf = {}, cooldowns = {}, range = {}, current = {},
          plates = {}, nameplates = "1", lit = {},
          damage = { 100, 140 }, speed = 3.3, target = nil, combat = false, stance = 0 }
    for n = 1, 12 do
        local b = stub()
        b.action, b.name = n, "ActionButton" .. n
        _G["ActionButton" .. n] = b
    end
    FRAMES = { FRAMES[1], FRAMES[2] }
end
function learn(id, future) W.book[#W.book + 1] = { id = id, future = future } end
function bar(slot, id, key) W.slots[slot] = id; if key then W.keys["ACTIONBUTTON" .. slot] = key end end
function target(t) W.target = t end

C_Spell = {
    GetSpellName = function(id) return SPELLS[id] and SPELLS[id].name end,
    GetSpellInfo = function(id) local s = SPELLS[id]; return s and { name = s.name, castTime = s.cast or 0 } end,
    GetSpellDescription = function(id) return SPELLS[id] and SPELLS[id].desc or "" end,
    GetSpellPowerCost = function(id) local s = SPELLS[id]; return s and s.cost and { { type = W.powerType, cost = s.cost } } or {} end,
    GetSpellTexture = function(id) return 1000 + id end,
    RequestLoadSpellData = function() end,
    IsSpellUsable = function(id) if W.usable[id] == nil then return true, false end return W.usable[id], false end,
    GetSpellCooldown = function(id) local c = W.cooldowns[id] or { 0, 0 }; return { startTime = hide(c[1]), duration = hide(c[2]), isEnabled = true } end,
    IsSpellInRange = function(id, unit)
        local plate = W.plates[tonumber((tostring(unit):match("^nameplate(%d+)$")))]
        if plate then return plate.near end
        return W.range[id]
    end,
    IsCurrentSpell = function(id) return W.current[id] == true end,
}
-- The cooldown, and the global cooldown it starts (none for an ability marked off it).
function GetSpellBaseCooldown(id)
    local spell = SPELLS[id]
    return spell and spell.cd or 0, (spell and spell.off) and 0 or 1500
end
C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 1 end,
    GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = #W.book } end,
    GetSpellBookItemInfo = function(i) local b = W.book[i]; return { itemType = b.future and 2 or 1, spellID = b.id, isPassive = false } end,
    IsSpellKnown = function() return false end,
}
function IsPlayerSpell(id) return id == 6603 end

function GetActionInfo(slot) local id = W.slots[slot]; if id then return "spell", id end end
function GetBindingKey(command) return W.keys[command] end
C_ActionBar = {
    IsUsableAction = function(slot)
        local id = W.slots[slot]
        if W.shortOf[id] then return false, true end
        if W.usable[id] == nil then return true, false end
        return W.usable[id], false
    end,
    GetActionCooldown = function(slot) local c = W.cooldowns[W.slots[slot]] or { 0, 0 }; return { startTime = hide(c[1]), duration = hide(c[2]), isEnabled = true } end,
    IsActionInRange = function(slot) return W.range[W.slots[slot]] end,
    IsCurrentAction = function(slot) return W.current[W.slots[slot]] == true end,
    IsAutoRepeatAction = function() return false end,
    GetActionBarPage = function() return 1 end,
    GetBonusBarOffset = function() return 0 end,
}

C_ClassTalents = { GetActiveConfigID = function() return 7 end }
C_Traits = {
    GetConfigInfo = function() return { treeIDs = { 1 } } end,
    GetTreeNodes = function() local ids = {}; for i = 1, #W.talents do ids[i] = i end; return ids end,
    GetNodeInfo = function(_, node) return { activeRank = W.talents[node].rank, activeEntry = { entryID = node }, posX = W.talents[node].x } end,
    GetEntryInfo = function(_, entry) return { definitionID = entry } end,
    GetDefinitionInfo = function(def) return { overrideName = W.talents[def].name } end,
    GetTreeCurrencyInfo = function()
        local spent = 0
        for _, t in ipairs(W.talents) do spent = spent + t.rank end
        return { { spent = spent, quantity = 0 } }
    end,
}
-- As seen on Forever 1.60.1: one entry named after the class, counting no
-- points. W.gameCounts makes it answer per tree, as other clients do.
C_SpecializationInfo = { GetSpecializationInfo = function(i)
    if W.gameCounts then return i, "tree", "", 0, "", 0, W.points[i] end
    if i == 1 then return 1, "Warrior", "", 0, "", 0, 0 end
end }

function GetInventoryItemID(_, slot) return W.worn[slot] and slot end
C_Item = { GetItemInfoInstant = function(slot) local it = W.worn[slot]; return slot, "", "", it.loc, 0, it.class, it.sub end }
function UnitAttackSpeed() return W.speed end
function UnitDamage() return W.damage[1], W.damage[2] end

function UnitClass() return W.class, W.class end
function UnitLevel() return W.level end
function UnitPowerType() return W.powerType end
function UnitPower(_, kind) if kind == 4 then return W.combo end return hide(W.power) end
function UnitPowerMax() return W.powerMax end
function UnitHealth(unit) if unit == "target" then return hide(W.target and W.target.health or 0) end return hide(W.health) end
function UnitHealthMax(unit) if unit == "target" then return W.target and W.target.healthMax or 0 end return W.healthMax end
function UnitExists(unit)
    if unit == "target" then return W.target ~= nil end
    if unit == "pet" then return W.pet == true end
    local plate = tostring(unit):match("^nameplate(%d+)$")
    if plate then return W.plates[tonumber(plate)] ~= nil end
    return true
end
-- The game's own assistant, when the test gives it one: W.assist = { next = spell, button = spell }.
C_AssistedCombat = {
    IsAvailable = function() return W.assist ~= nil end,
    GetNextCastSpell = function() return W.assist and W.assist.next end,
    GetActionSpell = function() return W.assist and W.assist.button end,
    GetRotationSpells = function() return {} end,
}
local function plateOf(unit) return W.plates[tonumber((tostring(unit):match("^nameplate(%d+)$")))] end
function UnitCanAttack(_, unit)
    local plate = plateOf(unit)
    if plate then return plate.friendly ~= true end
    return W.target ~= nil and W.target.friendly ~= true
end
function UnitIsDeadOrGhost(unit)
    local plate = plateOf(unit)
    if plate then return plate.dead == true end
    return unit == "target" and W.target ~= nil and W.target.dead == true
end
-- As on Forever 1.60.1, the list of nameplate frames gives an add-on nothing.
C_NamePlate = { GetNamePlates = function() return nil end }
function UnitThreatSituation(_, unit) local plate = plateOf(unit); return plate and plate.onMe and 1 or nil end
C_CVar = { GetCVar = function(name) return name == "nameplateShowEnemies" and W.nameplates or nil end }
function UnitAffectingCombat() return W.combat end
-- The game's own glow on a button whose proc is up.
C_SpellActivationOverlay = { IsSpellOverlayed = function(id) return W.lit[id] == true end }
function UnitClassification() return W.target and W.target.kind or "normal" end
function UnitGUID(unit) return unit == "target" and W.target and W.target.guid or nil end
function UnitCastingInfo(unit)
    if unit == "target" and W.target and W.target.casting then return "Fireball", nil, nil, 0, 0, false, nil, false end
    -- W.casting = { start, end } in seconds on the game's clock: the player's own cast.
    if unit == "player" and W.casting then return "Frostbolt", nil, nil, W.casting[1] * 1000, W.casting[2] * 1000, false, nil, false end
end
function GetComboPoints() return W.combo end
function IsStealthed() return W.stealth == true end
function GetShapeshiftFormID() return W.form ~= 0 and W.form or nil end
function GetShapeshiftForm() return W.stance end
function GetNumShapeshiftForms() return W.class == "WARRIOR" and 3 or 0 end
function GetShapeshiftFormInfo(place) return 0, W.stance == place, true, ({ 2457, 71, 2458 })[place] end
function GetCursorPosition() return 0, 0 end
function GetUnitSpeed() return W.moving and 7 or 0 end
function GetWeaponEnchantInfo() return W.imbue == true end
C_UnitAuras = { GetAuraDataBySpellName = function(unit, name)
    if W.secret then error("restricted") end
    local on = W.auras[unit][name]
    if type(on) == "table" then return { name = name, applications = on.stacks or 0, expirationTime = on.ends, duration = on.lasts } end
    return on and { name = name, applications = type(on) == "number" and on or 0 } or nil
end }
"""


class Game:
    """One character in the stand-in game, with the add-on loaded."""

    def __init__(self, cls, level, db=None):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(GAME)
        g = self.g = self.lua.globals()
        for spell_id, name in NAMED.items():
            g.SPELLS[spell_id] = self.lua.table(name=name)
        g.world(cls, level)
        self.ns = self.lua.table()
        if db is not None:
            g.PolestarNextDB = db
        load = self.lua.eval("function(src, name) return assert(loadstring(src, name)) end")
        for name in FILES:
            load((ADDON / name).read_text(encoding="utf-8"), name)("PolestarNext", self.ns)
        self.display, self.events = g.FRAMES[1], g.FRAMES[2]
        self.events.scripts.OnEvent(self.events, "ADDON_LOADED", "PolestarNext")
        self.events.scripts.OnEvent(self.events, "PLAYER_LOGIN")
        self._next_id = 900000

    def spell(self, spell_id, desc=None, cost=None, cast=None, cd=None, name=None, off=None):
        entry = self.g.SPELLS[spell_id] or self.lua.table(name=name)
        entry.desc, entry.cost, entry.cast, entry.cd, entry.off = desc, cost, cast, cd, off
        if name:
            entry.name = name
        self.g.SPELLS[spell_id] = entry

    def learn(self, *spells, keys=True):
        """Puts the spells in the spellbook and on the main bar, keys 1, 2, 3..."""
        for spell in spells:
            if isinstance(spell, str):  # a spell this client has under its own ID
                self._next_id += 1
                self.spell(self._next_id, name=spell)
                spell = self._next_id
            self.g.learn(spell)
            slot = len(self.g.W.slots) + 1
            if slot <= 12:
                self.g.bar(slot, spell, str(slot % 10) if keys else None)
        return self

    def id_of(self, name):
        return next(i for i, entry in self.g.SPELLS.items() if entry.name == name)

    def talents(self, points, **ranks):
        """Spends `points` in the three trees (the named talents in the biggest), as nodes
        on a tree drawn in three columns. Replaces whatever was spent before: a respec."""
        column_x = (100, 700, 1300)
        main = max(range(3), key=lambda i: points[i])
        # A real tree keeps its nodes and a respec moves the ranks between them:
        # every tree always has its two nodes here, taken or not.
        nodes = []
        for i, n in enumerate(points):
            self.g.W.points[i + 1] = n
            rest = max(0, n - (sum(ranks.values()) if i == main else 0))
            nodes += [(f"Untaken {i + 1}", 0, column_x[i] + 40), (f"Tree {i + 1} talent", rest, column_x[i])]
        nodes += [(name.replace("_", " "), rank, column_x[main] + 80) for name, rank in ranks.items()]
        self.g.W.talents = self.lua.table()
        for k, (name, rank, x) in enumerate(nodes, 1):
            self.g.W.talents[k] = self.lua.table(name=name, rank=rank, x=x)
        return self

    def wear(self, slot, loc, cls, sub):
        self.g.W.worn[slot] = self.lua.table(loc=loc, **{"class": cls, "sub": sub})
        return self

    def rebuild(self):
        return self.ns.Engine.Rebuild()

    def order(self):
        """The list as spell names, only those the character has."""
        return [self.ns.SpellName(r.spell) for r in self.ns.Engine.list.values() if self.ns.Engine.State(r.spell).known]

    def enemies(self, *near, onMe=()):
        """The enemies with nameplates up: True for one in melee reach, False for one further off."""
        self.g.W.plates = self.lua.table()
        for i, close in enumerate(near, 1):
            self.g.W.plates[i] = self.lua.table(near=close, onMe=i in onMe)
        return self

    def plan(self, most=6):
        """The plan as (ability, seconds from now, whether the plan left a gap before it)."""
        self.ns.Rules.Recount()
        return [(e.state.name, round(e.at, 2), e.blocked == "cooldown") for e in self.ns.Engine.Plan(most).values()]

    def effect(self, unit, name, left, lasts, stacks=0):
        """An effect the game shows, with its own timer."""
        self.g.W.auras[unit][name] = self.lua.table(ends=self.g.W.time + left, lasts=lasts, stacks=stacks)

    def ranked(self):
        """The abilities the game's numbers may reorder, in their order, only those the character has."""
        return [self.ns.SpellName(r.spell) for r in self.ns.Engine.list.values() if r.rank and self.ns.Engine.State(r.spell).known]

    def next(self):
        """The ability suggested now; None when there is none or it only waits on range."""
        self.ns.Rules.Recount()
        rule, state, _, blocked = self.ns.Engine.Suggest() or (None, None, None, None)
        return state.name if rule and not blocked else None

    def waiting(self):
        """The ability shown dimmed because only the distance is in the way."""
        rule, state, _, blocked = self.ns.Engine.Suggest() or (None, None, None, None)
        return state.name if rule and blocked == "range" else None

    def held(self):
        """The ability shown dimmed, and what it is waiting on: "range" or "power"."""
        self.ns.Rules.Recount()
        rule, state, _, blocked = self.ns.Engine.Suggest() or (None, None, None, None)
        return (state.name, blocked) if rule and blocked else None

    def queue(self, most=3):
        self.ns.Rules.Recount()
        return [entry.state.name for entry in self.ns.Engine.Queue(most).values()]

    def notes(self):
        return " ".join(self.ns.Engine.notes.values())


TWO_HANDER, ONE_HANDER, SHIELD, DAGGER, WAND = ("INVTYPE_2HWEAPON", 2, 1), ("INVTYPE_WEAPON", 2, 7), ("INVTYPE_SHIELD", 4, 6), ("INVTYPE_WEAPON", 2, 15), ("INVTYPE_RANGEDRIGHT", 2, 19)
MOB = dict(health=100, healthMax=100, guid="Creature-1", kind="normal")


def warrior():
    game = Game("WARRIOR", 14).wear(16, *TWO_HANDER)
    game.spell(772, "Wounds the target causing them to bleed for 15 damage over 9 sec.", cost=10)
    game.spell(78, "A strong attack that increases melee damage by 11 and causes a high amount of threat.", cost=15)
    game.learn(6603, 78, 772, 100, 6673)  # Attack, Heroic Strike, Rend, Charge, Battle Shout on keys 1-5
    game.rebuild()
    return game


def check_rules(game):
    check = game.ns.Rules.Check
    t = game.lua.eval('function(v) return { v == nil and "known" or "power>=", v } end')
    yes, no, unknown = t(0), t(10 ** 9), game.lua.eval('{ "known", { nil, "No Such Spell" } }')
    unknown = game.lua.eval('{ "form", 1 }')
    game.g.GetShapeshiftFormID = None  # the client will not say
    table = game.lua.eval("function(...) return { ... } end")
    assert check(yes) is True and check(no) is False and check(unknown) is None
    assert check(table("and", yes, yes)) is True and check(table("and", yes, no)) is False
    assert check(table("and", yes, unknown)) is None and check(table("and", no, unknown)) is False
    assert check(table("or", no, yes)) is True and check(table("or", no, no)) is False
    assert check(table("or", no, unknown)) is None and check(table("or", yes, unknown)) is True
    assert check(table("not", yes)) is False and check(table("not", unknown)) is None
    assert check(table("maybe", unknown)) is True and check(table("maybe", no)) is False
    assert check(None) is True
    lint = game.ns.Rules.Lint
    assert lint(table("and", yes)) is None and "unknown test" in lint(table("and", table("nonsense")))
    assert "exactly one" in lint(table("not", yes, no)) and "at least one" in lint(table("or"))
    print("ok  AND / OR / NOT keep unknown unknown; bad conditions are caught")


def check_warrior():
    game = warrior()
    W = game.g.W
    assert "Two-hander" in game.notes() and "30 rage" in game.notes(), game.notes()
    assert game.order() == ["Battle Shout", "Charge", "Attack", "Rend", "Heroic Strike"], game.order()

    # No rage: the game marks Battle Shout unusable, so nothing is suggested.
    W.usable[6673] = False
    assert game.next() is None
    W.usable[6673] = None
    assert game.next() == "Battle Shout"
    assert game.ns.Scan.ShortKey(game.ns.Engine.State(game.lua.eval('{ 6673, "Battle Shout" }')).key) == "5"
    W.auras.player["Battle Shout"] = True

    game.g.target(game.lua.table(**MOB))
    W.range[100] = True
    assert game.next() == "Charge"
    W.range[100] = False  # in melee now
    W.combat = True
    assert game.next() == "Attack"
    W.current[6603] = True
    W.power = 12
    assert game.next() == "Rend"
    W.auras.target["Rend"] = True
    assert game.next() is None, "12 rage is not spare rage"
    W.power = 35
    assert game.next() == "Heroic Strike"
    W.current[78] = True  # queued for the next swing
    assert game.next() is None
    W.cooldowns[772], W.auras.target["Rend"], W.current[78] = game.lua.table(95, 30), None, None
    assert game.next() == "Heroic Strike", "Rend on a long cooldown is passed over"

    # The display shows the suggestion and its key.
    for _ in range(12):
        game.display.scripts.OnUpdate(game.display, 0.11)
    assert game.g.FRAMES[1].alpha == 1
    print("ok  warrior: buff, opener, attack, bleed, spare rage, in that order")
    return game


def check_gear_and_talents():
    # A main strike moves Heroic Strike's threshold and drops Rend; a shield reorders.
    game = Game("WARRIOR", 40).wear(16, *ONE_HANDER).wear(17, *SHIELD)
    game.learn(6603, 78, 772, 12294, 6572, 23922, 2565).rebuild()
    order = game.order()
    assert "Rend" not in order and "Rend is left out" in game.notes()
    assert order.index("Revenge") < order.index("Shield Slam") < order.index("Mortal Strike") < order.index("Heroic Strike"), order
    assert "40 rage" in game.notes(), "a tank with a main strike: Heroic Strike from 40"
    game.talents((31, 0, 0), Improved_Rend=3, Improved_Heroic_Strike=3).rebuild()
    assert "Rend" in game.order() and "37 rage" in game.notes()
    assert game.ns.Scan.spec == 1

    # Paladin: Seal of Command only with a two-hander.
    for weapon, seal in ((TWO_HANDER, "Seal of Command"), (ONE_HANDER, "Seal of Righteousness")):
        paladin = Game("PALADIN", 30).wear(16, *weapon)
        paladin.learn(6603, 21084, 20375, 20271).rebuild()
        paladin.g.target(paladin.lua.table(**MOB))
        paladin.g.W.auras.player["Blessing of Might"] = True
        assert paladin.next() == seal, (weapon, paladin.next())

    # Mage: the filler follows the talent tree; no talents, Frostbolt.
    for points, first in (((0, 0, 0), "Frostbolt"), ((0, 21, 0), "Fireball"), ((0, 0, 21), "Frostbolt")):
        mage = Game("MAGE", 30)
        mage.g.W.powerType = 0
        mage.learn(116, 133, 1459).talents(points).rebuild()
        fillers = [name for name in mage.order() if name in ("Frostbolt", "Fireball")]
        assert fillers[0] == first, (points, fillers)

    # Rogue: a dagger opens with Ambush, a sword with Cheap Shot.
    for weapon, opener in ((DAGGER, "Ambush"), (ONE_HANDER, "Cheap Shot")):
        rogue = Game("ROGUE", 30).wear(16, *weapon)
        rogue.learn(6603, 1752, 2098, 8676, 1833).rebuild()
        rogue.g.target(rogue.lua.table(**MOB))
        rogue.g.W.stealth = True
        assert rogue.next() == opener, (weapon, rogue.next())
    rogue.g.W.stealth, rogue.g.W.combat, rogue.g.W.current[6603] = False, True, True
    assert rogue.next() == "Sinister Strike"
    rogue.g.W.combo = 5
    assert rogue.next() == "Eviscerate"
    rogue.g.W.combo, rogue.g.W.target.health = 3, 30
    assert rogue.next() == "Eviscerate", "three points finish a target that is nearly dead"
    rogue.g.W.target.health = 90
    assert rogue.next() == "Sinister Strike"

    # Caster with a wand: it takes over when mana runs short.
    priest = Game("PRIEST", 20).wear(18, *WAND)
    priest.g.W.powerType = 0
    priest.learn(585, 589, 5019).rebuild()
    priest.g.target(priest.lua.table(**MOB))
    for name in ("Power Word: Fortitude", "Inner Fire"):
        priest.g.W.auras.player[name] = True
    priest.g.W.power, priest.g.W.combat = 100, True
    assert priest.next() == "Shadow Word: Pain"
    priest.g.W.auras.target["Shadow Word: Pain"] = True
    assert priest.next() == "Smite"
    priest.g.W.power = 20
    assert priest.next() == "Shoot" and "wand" in priest.notes()

    # Druid: the form decides which abilities are offered.
    druid = Game("DRUID", 25)
    druid.learn(768, 1082, 22568, 5176, 6807, 5487).talents((0, 11, 0)).rebuild()
    druid.g.target(druid.lua.table(**MOB))
    for name in ("Mark of the Wild", "Thorns"):
        druid.g.W.auras.player[name] = True
    assert druid.next() == "Cat Form"
    druid.g.W.form, druid.g.W.combat, druid.g.W.current[6603] = 1, True, True
    assert druid.next() == "Claw"
    druid.g.W.form, druid.g.W.power = 5, 20
    assert druid.next() == "Maul"
    print("ok  gear and talents change the list: shield, two-hander, dagger, wand, talent tree, form")


def check_numbers():
    parse = Game("WARRIOR", 1).ns.Numbers.Parse
    p = parse("Wounds the target causing them to bleed for 15 damage over 9 sec.")
    assert (p.dot, p.over, p.direct) == (15, 9, None)
    p = parse("Launches a bolt of frost at the enemy, causing 1,038 to 1,044 Frost damage and slowing movement speed by 40% for 5 sec.")
    assert p.direct == 1041 and p.dot is None
    p = parse("Hurls a fiery ball that causes 14 to 22 Fire damage and an additional 2 Fire damage over 4 sec.")
    assert (p.direct, p.dot, p.over) == (18, 2, 4)
    p = parse("A vicious strike that deals weapon damage plus 85 and wounds the target, reducing healing by 50% for 10 sec.")
    assert (p.weapon, p.plus, p.onSwing) == (100, 85, None)
    p = parse("A strong attack that increases melee damage by 11 and causes a high amount of threat.")
    assert (p.onSwing, p.plus, p.direct) == (True, 11, None)
    p = parse("Instantly strike the target for 150% weapon damage.")
    assert p.weapon == 150
    assert next(iter(parse("").items()), None) is None and next(iter(parse("Increases Stamina by 3.").items()), None) is None

    # Level 40 warrior, 100-140 weapon. Mortal Strike: 120 + 85 = 205 for 30 rage (6.8 a point).
    # Whirlwind: 120 for 25 (4.8). Rend: 15 for 10 (1.5). The class's order has them
    # Mortal Strike, Whirlwind, Rend already; make Whirlwind cheap and it must move up.
    game = Game("WARRIOR", 40).wear(16, *TWO_HANDER).talents((31, 0, 0), Improved_Rend=3)
    game.spell(12294, "A vicious strike that deals weapon damage plus 85 and wounds the target.", cost=30)
    game.spell(1680, "In a whirlwind of steel you attack up to 4 enemies within 8 yards, causing weapon damage to each enemy.", cost=25)
    game.spell(772, "Wounds the target causing them to bleed for 15 damage over 9 sec.", cost=10)
    game.learn(6603, 12294, 1680, 772, 78).rebuild()
    strikes = [n for n in game.ranked() if n in ("Mortal Strike", "Whirlwind", "Rend")]
    assert strikes == ["Mortal Strike", "Whirlwind", "Rend"], strikes
    assert "3 of 3 damage abilities are ordered by the game's numbers" in game.notes(), game.notes()
    figures = {game.ns.SpellName(r.spell): r.figures for r in game.ns.Engine.list.values() if r.figures}
    assert figures["Mortal Strike"] == "205 damage, 6.8 per point" and figures["Rend"] == "15 damage, 15 of it over 9s, 1.5 per point", figures

    game.spell(1680, "In a whirlwind of steel you attack up to 4 enemies within 8 yards, causing weapon damage to each enemy.", cost=5)
    game.rebuild()
    strikes = [n for n in game.ranked() if n in ("Mortal Strike", "Whirlwind", "Rend")]
    assert strikes == ["Whirlwind", "Mortal Strike", "Rend"], strikes

    # A better weapon changes the answer too: at 400-500 Mortal Strike is 535 for 30 (17.8),
    # Whirlwind at its real cost 450 for 25 (18.0).
    game.spell(1680, "In a whirlwind of steel you attack up to 4 enemies within 8 yards, causing weapon damage to each enemy.", cost=25)
    game.g.W.damage = game.lua.table(400, 500)
    game.rebuild()
    assert [n for n in game.ranked() if n in ("Mortal Strike", "Whirlwind")] == ["Whirlwind", "Mortal Strike"]

    # A mage fights on mana: damage per second of casting. Fireball 100 in 3.0 s (33 a second)
    # against Frostbolt 80 in 2.0 s (40): Frostbolt leads even with Fire talents.
    mage = Game("MAGE", 30)
    mage.g.W.powerType = 0
    mage.spell(133, "Hurls a fiery ball that causes 90 to 110 Fire damage.", cost=60, cast=3000)
    mage.spell(116, "Launches a bolt of frost at the enemy, causing 75 to 85 Frost damage.", cost=50, cast=2000)
    mage.learn(116, 133).talents((0, 21, 0)).rebuild()
    assert [n for n in mage.order() if n in ("Frostbolt", "Fireball")] == ["Frostbolt", "Fireball"]
    fireball = next(r.figures for r in mage.ns.Engine.list.values() if mage.ns.SpellName(r.spell) == "Fireball")
    assert fireball == "100 damage, 33 a second, 1.7 per mana", fireball

    # No readable numbers: the class's own order stands, and the list says so.
    plain = Game("WARRIOR", 40).wear(16, *TWO_HANDER)
    plain.learn(6603, 12294, 1680).rebuild()
    assert [n for n in plain.ranked() if n in ("Mortal Strike", "Whirlwind")] == ["Mortal Strike", "Whirlwind"]
    assert "gave no damage numbers" in plain.notes()
    print("ok  damage abilities are ordered by the game's numbers: cost, cast time and weapon all move them")


def check_secret_values():
    game = warrior()
    W = game.g.W
    game.g.target(game.lua.table(**MOB))
    W.auras.player["Battle Shout"] = True
    W.combat, W.power, W.range[100] = True, 12, False
    W.current[6603] = True
    W.secret = True  # auras throw, rage and health and cooldowns are secret

    # Battle Shout cannot be seen and was not cast this session: it is offered again.
    assert game.next() == "Battle Shout"
    game.ns.Rules.SawCast(6673)
    # Rend's effect cannot be seen either: offered until the add-on sees it cast...
    assert game.next() == "Rend"
    game.ns.Rules.SawCast(772)
    # ...then taken to be up. The rage cannot be read, and the game says there is not
    # enough for Heroic Strike, so it is not offered.
    W.shortOf[78] = True
    assert game.next() is None
    W.time = 116  # Rend's fifteen seconds are over
    assert game.next() == "Rend"
    game.ns.Rules.SawCast(772)
    W.target.guid = "Creature-2"  # a new target has no Rend on it
    assert game.next() == "Rend"
    # What the game would not say while fighting is counted, test by test, for the report.
    hidden = dict(game.ns.Rules.hidden.items())
    assert hidden.get("target%>=", 0) > 0 and game.ns.db.report.hiddenInCombat["target%>="] == hidden["target%>="], hidden
    print("ok  secret values: unknown is never read as yes, and the player's own casts stand in for hidden effects")


def check_every_class():
    order = list(Game("WARRIOR", 1).ns.Classes.ORDER.values())
    assert len(order) == 9
    for cls in order:
        for level in (1, 10, 20, 40, 60):
            for everything in (False, True):
                for spec in (0, 1, 2, 3):
                    for weapon in (None, TWO_HANDER, DAGGER):
                        game = Game(cls, level)
                        if weapon:
                            game.wear(16, *weapon).wear(18, *WAND)
                        if everything:
                            game.learn(*NAMED.keys(), *sorted(NAME_ONLY))
                        if spec:
                            game.talents([30 if i == spec - 1 else 0 for i in range(3)])
                        rules = game.rebuild()
                        assert game.ns.Engine.Lint(rules) is None, (cls, level, game.ns.Engine.Lint(rules))
                        for rule in rules.values():
                            assert isinstance(game.ns.Rules.Describe(rule.when), str) and rule.note
                        # It must cope with any moment: no target, a target, hidden values.
                        for combat, tgt, secret in ((False, None, False), (True, MOB, False), (True, MOB, True)):
                            game.g.W.combat, game.g.W.secret = combat, secret
                            game.g.target(game.lua.table(**tgt) if tgt else None)
                            game.next()
                        if everything:
                            assert len(game.order()) >= 8, (cls, len(game.order()))
    print("ok  all nine classes build a valid list at every level, tree and weapon, and survive every moment")


def check_own_list_and_commands():
    lua_db = LuaRuntime().eval  # a throwaway, to show the shape only
    game = warrior()
    # A list the player saved is used as it is; a broken one is ignored.
    game.ns.db.lists = game.lua.eval('{ ["WARRIOR:0:0"] = { { spell = { 78, "Heroic Strike" }, when = { "target" }, note = "mine" } } }')
    game.rebuild()
    assert game.order() == ["Heroic Strike"] and game.ns.Engine.custom and game.ns.Engine.key == "WARRIOR:0:0"
    game.ns.db.lists = game.lua.eval('{ ["WARRIOR:0:0"] = { { spell = { 78 }, when = { "nonsense" } } } }')
    game.rebuild()
    assert len(game.order()) == 5 and not game.ns.Engine.custom

    # The report kept with the settings says what was found.
    report = game.ns.db.report
    assert report["class"] == "WARRIOR" and report.spells == 5 and report.barSpellsWithKeys == 5 and report.gear.twoHand

    slash = game.g.SlashCmdList.POLESTARNEXT
    slash("list")
    said = "\n".join(game.g.SAID.values())
    assert "WARRIOR, level 14, no talents spent, two-hander" in said, said
    assert "Rend" in said and "[3]" in said and "15 damage" in said and "when target and combat and not debuff Rend" in said, said
    slash("lock")
    assert game.ns.db.locked is True
    slash("")
    assert game.ns.db.shown is False
    print("ok  a saved list is used, a broken one ignored; /pnext list explains the order")


def check_stances():
    """A warrior has a rotation for each stance, and walking in is not met with silence."""
    # The real case: level 15, Protection talents, a two-hander, in Defensive Stance,
    # no rage, an enemy targeted from a distance.
    game = Game("WARRIOR", 15).wear(16, *TWO_HANDER)
    game.learn(6603, 78, 772, 6673, 2687, 100, 7386, 7384, 71, 2457)
    game.talents((0, 0, 6), Improved_Thunder_Clap=1, Improved_Bloodrage=2, Shield_Specialization=3)
    W = game.g.W
    W.stance, W.power = 2, 0
    for spell in (100, 7384):  # Charge and Overpower cannot be used in Defensive Stance
        W.usable[spell] = False
    W.usable[6673] = False  # Battle Shout: no rage
    game.g.target(game.lua.table(**MOB))
    W.range[6603] = False  # too far to swing
    game.rebuild()
    assert game.ns.Engine.Title() == "Protection, Defensive Stance" and "Charge" not in game.order()
    assert "Defensive Stance has no Charge" in game.notes()

    # Bloodrage for the rage to open with, where the old list had nothing to say.
    assert game.next() == "Bloodrage"
    # Bloodrage used: now only the walk in is left, and the panel says so instead of going blank.
    W.cooldowns[2687], W.power = game.lua.table(99, 60), 10
    assert game.next() is None and game.waiting() == "Attack"
    W.usable[6673] = None
    assert game.next() == "Battle Shout", "something usable always comes before something out of range"
    W.auras.player["Battle Shout"] = True
    # In reach: attack, then the tank's filler.
    W.range[6603], W.combat = True, True
    assert game.next() == "Attack"
    W.current[6603], W.power = True, 30
    assert game.next() == "Sunder Armor"
    assert game.queue() == ["Sunder Armor", "Rend", "Heroic Strike"], game.queue()

    # The fight goes on. Sunder Armor is the filler: to five stacks, not once.
    game.ns.Rules.SawCast(772)
    for stack in range(1, 5):
        game.ns.Rules.SawCast(7386)
        assert game.next() == "Sunder Armor", f"{stack} stacks is not five"
    game.ns.Rules.SawCast(7386)
    W.power = 12
    assert game.next() is None and game.waiting() is None, "five stacks, Rend on, 12 rage: nothing to do but swing"
    # The record of that moment says why, ability by ability.
    for _ in range(4):
        game.display.scripts.OnUpdate(game.display, 0.11)
    idle = game.ns.Engine.idle
    assert idle.times >= 1 and idle.power == 12 and idle.rotation == "Protection, Defensive Stance"
    why = list(idle.why.values())
    assert "Sunder Armor: condition not met" in why and "Heroic Strike: condition not met" in why and "Rend: condition not met" in why, why
    assert game.ns.db.report.nothingToSuggest.times == idle.times
    # Twenty-two seconds on, Sunder Armor is due again before it fades...
    W.time += 25
    W.auras.target["Rend"] = True
    assert game.next() == "Sunder Armor", "due again before it fades"

    # ...and when the game says there is not the rage for it, the panel says that
    # rather than nothing.
    short = Game("WARRIOR", 15).wear(16, *TWO_HANDER)
    short.learn(6603, 7386, 772).talents((0, 0, 6))
    short.g.target(short.lua.table(**MOB))
    short.g.W.stance, short.g.W.combat, short.g.W.current[6603] = 2, True, True
    short.g.W.auras.target["Rend"] = True
    short.g.W.shortOf[7386] = True
    short.rebuild()
    rule, state, _, blocked = short.ns.Engine.Suggest()
    assert state.name == "Sunder Armor" and blocked == "power" and short.next() is None
    assert short.ns.Engine.Why(rule) == "not enough rage" and short.ns.Engine.PowerName() == "rage"
    short.g.W.shortOf[7386] = None
    assert short.next() == "Sunder Armor"

    # A stack count the game shows is believed over the add-on's own.
    short.g.W.auras.target["Sunder Armor"] = 5
    assert short.next() is None
    short.g.W.auras.target["Sunder Armor"] = 3
    assert short.next() == "Sunder Armor"

    # Battle Stance, Arms: Charge opens. Berserker Stance: Intercept, with Bloodrage first when dry.
    arms = Game("WARRIOR", 40).wear(16, *TWO_HANDER)
    arms.learn(6603, 78, 100, 20252, 2687, 1680).talents((31, 0, 0))
    arms.g.target(arms.lua.table(**MOB))
    arms.g.W.auras.player["Battle Shout"] = True
    arms.g.W.stance = 1
    arms.rebuild()
    assert arms.next() == "Charge" and arms.ns.Engine.key == "WARRIOR:1:1"
    arms.g.W.stance = 3
    arms.rebuild()
    assert "Charge" not in arms.order() and "Berserker Stance: Intercept opens" in arms.notes()
    assert arms.next() == "Bloodrage"
    arms.g.W.power = 15
    assert arms.next() == "Intercept"
    print("ok  stances: each has its own opener and order, and walking into range shows a dimmed suggestion, not nothing")


def check_enemies_around():
    """Enemies in reach are counted from their nameplates, and the area abilities follow the count."""
    game = Game("WARRIOR", 30).wear(16, *TWO_HANDER)
    game.learn(6603, 78, 772, 6343, 845, 1680, 12328, 1160, 7386, 71)
    game.talents((0, 0, 11), Improved_Thunder_Clap=3)
    W = game.g.W
    W.stance, W.combat, W.power = 2, True, 60
    W.current[6603] = True
    W.auras.player["Battle Shout"] = True
    W.auras.target["Rend"], W.auras.target["Sunder Armor"] = True, 5
    game.g.target(game.lua.table(**MOB))
    game.rebuild()
    assert "With two or more enemies in reach" in game.notes() and "Improved Thunder Clap" in game.notes()
    rules = game.ns.Rules

    # One enemy: the single-target order, Heroic Strike for the spare rage.
    game.enemies(True)
    assert game.next() == "Whirlwind" and rules.Enemies() == 1
    W.cooldowns[1680] = game.lua.table(99, 10)
    assert game.next() == "Heroic Strike"

    # Two in reach (and one far off that does not count): the area abilities, in order.
    game.enemies(True, True, False)
    game.ns.Rules.Recount()
    assert rules.Enemies() == 2
    assert game.queue(4) == ["Sweeping Strikes", "Thunder Clap", "Cleave", "Heroic Strike"], game.queue(4)
    game.ns.Rules.SawCast(12328)
    W.cooldowns[12328] = game.lua.table(99, 30)
    game.ns.Rules.SawCast(6343)
    assert game.next() == "Cleave", "Thunder Clap is on them: Cleave takes the spare rage, not Heroic Strike"
    W.cooldowns[1680] = None
    assert game.next() == "Whirlwind"
    # Three: the tank's shout joins in.
    game.enemies(True, True, True)
    assert game.next() == "Demoralizing Shout"

    # Dead ones and friendly ones are not enemies.
    game.enemies(True, True, True)
    W.plates[2].dead, W.plates[3].friendly = True, True
    game.ns.Rules.Recount()
    assert rules.Enemies() == 1

    # Nameplates off: nothing to count, the target still counts as one, and the notes say why.
    game.enemies()
    W.nameplates = "0"
    game.rebuild()
    game.ns.Rules.Recount()
    assert rules.Enemies() == 1 and "Enemy nameplates are off" in game.notes()
    assert game.ns.db.report.enemyNameplates == "0" and game.ns.db.report.mostEnemiesCounted == 3

    # A class with no melee ability to measure with counts the enemies that are on it.
    mage = Game("MAGE", 30)
    mage.g.W.powerType = 0
    mage.learn(116, 1449, 122, 1459)
    mage.g.W.power, mage.g.W.combat = 100, True
    mage.g.W.auras.player["Arcane Intellect"] = True
    mage.g.target(mage.lua.table(**MOB))
    mage.rebuild()
    mage.enemies(False, False, False, onMe=(1,))
    assert mage.next() == "Frostbolt"
    mage.enemies(False, False, False, onMe=(1, 2))
    assert mage.next() == "Frost Nova"
    mage.g.W.cooldowns[122] = mage.lua.table(99, 25)
    mage.enemies(False, False, False, onMe=(1, 2, 3))
    assert mage.next() == "Arcane Explosion"
    print("ok  enemies around: counted from nameplates, and Thunder Clap, Cleave, Sweeping Strikes and the rest follow the count")


def check_what_the_game_hides():
    """As the real client turned out: rage and health hidden in a fight, nameplate frames
    unreadable, and an assistant of the game's own."""
    game = fighter((7386, 772, 78, 2687, 6343, 71), (0, 0, 6), stance=2, level=15)  # Sunder 15, Rend 10, Heroic Strike 15, Bloodrage, Thunder Clap
    game.spell(6343, "Blasts nearby enemies with thunder, slowing their attacks. Lasts 30 sec.", cost=20)
    game.spell(2687, "Generates 10 rage at the cost of health.", cd=60000, off=True)
    game.rebuild()
    W, rules = game.g.W, game.ns.Rules
    W.secret = True  # the bar, the health and the effects are all hidden

    # Everything affordable: at least 20 is proved (Thunder Clap), which is as much as can be told.
    assert rules.Proved() == (20, None, 20)
    check = lambda *c: rules.Check(game.lua.table(*c))
    assert check("power>=", 15) is True and check("power>=", 30) is True and check("power<", 20) is False
    # The game says there is not enough for Thunder Clap, but there is for Sunder Armor: 15 to 19.
    W.shortOf[6343] = True
    rules.Recount()
    assert rules.Proved() == (15, 20, 20)
    assert check("power>=", 15) is True and check("power>=", 18) is None and check("power>=", 20) is False and check("power>=", 30) is False
    assert check("power<", 20) is True and check("power<", 15) is False
    # Nothing but Rend affordable: under 15, so Bloodrage's "rage is low" holds though the bar is hidden,
    # and its check on the player's health, hidden too, does not stand in the way.
    W.shortOf[7386], W.shortOf[78] = True, True
    game.ns.Rules.SawCast(772)
    assert game.next() == "Bloodrage"
    # Bloodrage is used. Its cooldown is hidden too: the add-on saw the cast and knows how long it runs.
    game.ns.Rules.SawCast(2687)
    assert game.next() is None and game.held() == ("Sunder Armor", "power"), "next up, once there is the rage"
    # Rage arrives: Sunder Armor, and with everything affordable again, Heroic Strike beside it.
    W.shortOf[7386], W.shortOf[78], W.shortOf[6343] = None, None, None
    assert game.queue(3)[0] == "Sunder Armor" and "Heroic Strike" in [name for name, _, _ in game.plan(4)]

    # Enemies are counted by nameplate unit, with the list of nameplate frames giving nothing.
    game.enemies(True, True, False)
    rules.Recount()
    assert rules.Enemies() == 2 and rules.mostPlates == 3
    W.shortOf[6343] = None
    assert "Thunder Clap" in game.queue(4), game.queue(4)

    # The game's own assistant. As a fallback its pick is shown when the rotation has nothing...
    quiet = fighter((772, 78, 7386), (0, 0, 6), stance=2, level=15)
    Q = quiet.g.W
    assistant = lambda: quiet.ns.Engine.Assistant()
    assert assistant().available is False and assistant().pick is None
    quiet.spell(1229376, name="Single-Button Assistant")
    Q.assist = quiet.lua.table(next=78, button=1229376)
    assert assistant().available and assistant().pick[2] == "Heroic Strike" and assistant().button[2] == "Single-Button Assistant"
    upcoming = lambda: [(e.state.name, bool(e.game)) for e in quiet.ns.Engine.Upcoming(4).values()]
    Q.auras.target["Rend"], Q.auras.target["Sunder Armor"] = True, 5
    Q.power = 5
    assert quiet.next() is None and upcoming() == [("Heroic Strike", True)], upcoming()
    # ...and not when the rotation has something for now, unless the player wants it always.
    Q.auras.target["Sunder Armor"], Q.power = 2, 100
    assert upcoming()[0] == ("Sunder Armor", False) and all(not game_pick for _, game_pick in upcoming())
    quiet.g.SlashCmdList.POLESTARNEXT("assist always")
    assert quiet.ns.db.assist == "always" and upcoming()[0] == ("Heroic Strike", True) and upcoming()[1] == ("Sunder Armor", False)
    Q.assist.next = 7386  # agreeing with the plan: nothing to add
    assert upcoming()[0] == ("Sunder Armor", False)
    quiet.g.SlashCmdList.POLESTARNEXT("assist off")
    Q.assist.next, Q.auras.target["Sunder Armor"], Q.power = 78, 5, 5
    Q.time += 20  # long enough that the rage of a moment ago no longer counts as income
    assert upcoming() == [], upcoming()
    # /pnext assist says what the one button is called and how to use it.
    quiet.g.SlashCmdList.POLESTARNEXT("assist fallback")
    said = "\n".join(quiet.g.SAID.values())
    assert "Single-Button Assistant" in said and "drag it to a bar" in said and "Heroic Strike" in said, said
    print("ok  what the game hides: rage proved from what is usable, health margins waived, enemies by nameplate unit, the game's own pick")


def check_tree_points():
    """Which tree the talents are in, read the three ways the add-on knows."""
    # The real case: a level 15 warrior, six points, all in the third column. The
    # character sheet's call counts none of them (as on Forever 1.60.1).
    game = Game("WARRIOR", 15).wear(16, *TWO_HANDER)
    game.learn(6603, 78, 772, 71)
    game.talents((0, 0, 6), Improved_Thunder_Clap=1, Improved_Bloodrage=2, Shield_Specialization=3)
    game.rebuild()
    scan = game.ns.Scan
    assert [scan.points[i] for i in (1, 2, 3)] == [0, 0, 6] and scan.spec == 3
    assert scan.pointsFrom == "where the talents sit in the tree"
    assert "Protection talents" in game.notes()
    assert "Protection (0/0/6, by where the talents sit in the tree)" in game.ns.Summary(), game.ns.Summary()
    assert game.ns.db.report.pointsFrom == scan.pointsFrom

    # Polestar loaded: its map of the tree decides, by node, by spell or by name,
    # whatever the positions say. Here it puts the same talents in the first tree.
    game.g.Polestar = game.lua.eval("""{ Talents = { Data = function(class)
        assert(class == "WARRIOR")
        return { nodes = {
            [7] = { spec = 1 },
            a = { name = "Improved Bloodrage", spec = 1 },
            b = { name = "Shield Specialization", spec = 1 },
        } }
    end } }""")
    game.rebuild()
    assert [scan.points[i] for i in (1, 2, 3)] == [6, 0, 0] and scan.spec == 1
    assert scan.pointsFrom == "Polestar's map of the tree"

    # A client whose character sheet does count per tree is believed first.
    game.g.W.gameCounts = True
    game.g.W.points[1], game.g.W.points[2], game.g.W.points[3] = 0, 6, 0
    game.rebuild()
    assert scan.spec == 2 and scan.pointsFrom == "the game's count"

    # No talents spent: no tree, and nothing claimed about one.
    fresh = Game("WARRIOR", 9)
    fresh.learn(6603).talents((0, 0, 0)).rebuild()
    assert fresh.ns.Scan.spec is None and fresh.ns.Scan.pointsFrom is None and "no talents spent" in fresh.ns.Summary()
    assert len(list(fresh.ns.Scan.problems.values())) == 0
    print("ok  talent trees: read from where the talents sit, from Polestar's map, or from the game's count")


def check_realtime():
    """Talents, gear and stance changing mid-session change the list within a second or two."""
    game = Game("WARRIOR", 40).wear(16, *TWO_HANDER)
    game.learn(6603, 78, 772, 12294, 6572, 23922, 2565, 71, 2457).talents((31, 0, 0))
    W = game.g.W

    def play(seconds):
        for _ in range(int(seconds / 0.11) + 1):
            game.display.scripts.OnUpdate(game.display, 0.11)

    play(1)
    for name in ("Battle Shout",):
        W.auras.player[name] = True
    game.g.target(game.lua.table(**MOB))
    W.range[100] = False
    assert game.ns.Scan.spec == 1 and "Protection" not in game.notes()
    first = game.order()

    # Respec to Protection. No event reaches the add-on: only the game's answers change.
    game.talents((0, 0, 31))
    play(2)
    assert game.ns.Scan.spec == 3 and "Protection talents" in game.notes(), game.notes()
    assert game.order() != first and game.next() == "Defensive Stance"
    order = game.order()
    assert order.index("Revenge") < order.index("Shield Slam") < order.index("Mortal Strike")
    # Into Defensive Stance: asked for no longer.
    W.stance = 2
    play(2)
    assert game.next() == "Attack" and "Protection, Defensive Stance" in game.ns.Summary(), game.ns.Summary()
    assert game.ns.Engine.key == "WARRIOR:3:2"

    # Back to Arms, still in Defensive Stance: Battle Stance is asked for before the pull.
    game.talents((31, 0, 0))
    play(2)
    assert game.ns.Scan.spec == 1 and game.next() == "Battle Stance"
    W.stance = 1

    # A shield goes on: this time the game says so with an event.
    game.wear(16, *ONE_HANDER).wear(17, *SHIELD)
    game.events.scripts.OnEvent(game.events, "PLAYER_EQUIPMENT_CHANGED")
    play(0.7)
    assert game.ns.Scan.gear.shield and "Shield equipped" in game.notes()

    # A new spell learned, announced or not, joins the list.
    assert "Whirlwind" not in game.order()
    game.learn(1680)
    play(2)
    assert "Whirlwind" in game.order()

    # A stance swaps what is on the buttons: the key shown follows.
    revenge = game.lua.eval('{ 6572, "Revenge" }')
    assert game.ns.Engine.State(revenge).key == "5"
    game.g.bar(1, 6572, "1")
    game.events.scripts.OnEvent(game.events, "UPDATE_SHAPESHIFT_FORM")
    play(0.3)
    game.ns.Engine.Suggest()
    assert game.ns.Engine.State(revenge).key == "1"
    print("ok  live changes: respec, stance, gear, a new spell and swapped buttons all reach the list, with or without an event")


def check_editor():
    game = warrior()
    E, lua = game.ns.Edit, game.lua
    own = E.List()

    def names():
        return [game.ns.SpellName(r.spell) for r in own.values()]

    built = names()
    assert not game.ns.Engine.custom and len(built) > 10

    # Reorder, remove, add.
    assert E.Move(built.index("Rend") + 1, 1) is None
    assert names()[0] == "Rend" and game.ns.Engine.custom and game.order()[0] == "Rend"
    assert E.Move(1, 999) is None and names()[-1] == "Rend"
    assert E.RemoveRule(len(names())) is None and "Rend" not in names()
    assert E.AddRule("heroic") is None and names()[-1] == "Heroic Strike", "a typed part of a name finds the spell"
    assert own[len(names())].when[1] == "target"
    assert E.AddRule("  ") == "name a spell"
    assert E.AddRule("Made Up Spell") is None and names()[-1] == "Made Up Spell"

    # A condition, built up from nothing and taken apart again.
    rule = own[1]
    rule.when = None
    path = lambda *steps: lua.table(*steps)
    E.AddPart(rule, path())
    assert list(rule.when.values()) == ["target"]
    E.AddPart(rule, path())  # beside a test: the two go into an ALL-of group
    assert rule.when[1] == "and" and rule.when[2][1] == "target" and rule.when[3][1] == "target"
    E.StepTest(rule, path(3), 1)
    assert rule.when[3][1] == "combat"
    E.StepTest(rule, path(3), -1)
    assert rule.when[3][1] == "target"
    E.StepTest(rule, path(3), 1)
    E.ToggleNot(rule, path(3))
    assert rule.when[3][1] == "not" and rule.when[3][2][1] == "combat"
    labels = [E.Label(row.node) for row in E.Rows(rule).values()]
    assert labels == ["ALL of:", "I have something to attack targeted", "NOT:", "I am in combat"], labels
    assert [row.depth for row in E.Rows(rule).values()] == [0, 1, 1, 2]
    E.ToggleNot(rule, path(3, 2))  # NOT comes off from the row it negates
    assert rule.when[3][1] == "combat"
    E.ToggleGroup(rule, path())
    assert rule.when[1] == "or" and game.ns.Rules.Describe(rule.when) == "target or combat"

    # Values: a number where a number goes, a spell found by part of its name.
    while rule.when[3][1] != "power>=":
        E.StepTest(rule, path(3), 1)
    assert rule.when[3][2] == 30
    assert E.SetValue(rule, path(3), "lots") is False and rule.when[3][2] == 30
    assert E.SetValue(rule, path(3), "45") is True and rule.when[3][2] == 45
    while rule.when[3][1] != "debuff":
        E.StepTest(rule, path(3), -1)
    assert game.ns.SpellName(rule.when[3][2]) == game.ns.SpellName(rule.spell), "a new spell test starts on the rule's own spell"
    assert E.SetValue(rule, path(3), "rend") is True and rule.when[3][2][1] == 772
    assert E.Label(rule.when[3]) == "the target has my effect Rend"
    E.AddPart(rule, path(), lua.eval('{ "and", { "elite" } }'))  # a group inside the group
    assert rule.when[4][1] == "and" and E.Commit() is None

    # Taking parts out: an emptied group goes too, and the last part leaves "always".
    E.RemovePart(rule, path(4, 2))
    assert len(rule.when) == 3, "the group that was left empty is gone"
    E.RemovePart(rule, path(3))
    E.RemovePart(rule, path(2))
    assert rule.when is None and E.Commit() is None and len(E.Rows(rule)) == 0

    # The window opens, draws and closes on the stand-in's frames without a fault.
    slash = game.g.SlashCmdList.POLESTARNEXT
    slash("edit")
    E.Refresh()

    # Opening the editor is not editing: a fresh character's list stays the built one,
    # and a list saved by the version that froze it on opening is dropped at login.
    looker = warrior()
    looker.g.SlashCmdList.POLESTARNEXT("edit")
    looker.ns.Edit.Refresh()
    assert not looker.ns.Engine.custom and looker.ns.db.lists is None
    frozen = LuaRuntime(unpack_returned_tuples=True)
    stale = Game("WARRIOR", 14)
    stale.g.PolestarNextDB = stale.lua.eval('''{
        lists = { WARRIOR = { 1 }, ["WARRIOR:0:0"] = { 2 }, ["WARRIOR:3:2"] = { 3 } },
        edited = { WARRIOR = true, ["WARRIOR:3:2"] = true },
    }''')
    stale.events.scripts.OnEvent(stale.events, "ADDON_LOADED", "PolestarNext")
    kept = sorted(stale.ns.db.lists.keys())
    assert kept == ["WARRIOR:3:2"], kept
    del frozen

    # A rotation for each tree and stance: edit the Protection, Defensive Stance one
    # while standing in no stance with no talents. It is saved under its own name,
    # leaves the rotation in use alone, and takes over when the character gets there.
    other = Game("WARRIOR", 30).wear(16, *TWO_HANDER)
    other.learn(6603, 78, 772, 2687, 100, 7386, 71).rebuild()
    O = other.ns.Edit
    assert O.InUse() and other.ns.Engine.Title() == "No talents yet"
    O.Pick(3, 2)
    assert not O.InUse() and O.Key() == "WARRIOR:3:2"
    shown = [other.ns.SpellName(r.spell) for r in O.Current().values()]
    assert "Charge" not in shown and shown.index("Bloodrage") < shown.index("Attack"), shown
    assert O.AddRule("rend") is None
    assert other.ns.db.lists["WARRIOR:3:2"] is not None and other.ns.db.lists["WARRIOR:0:0"] is None
    assert not other.ns.Engine.custom and "Charge" in other.order(), "the rotation in use is untouched"
    mine = O.List()
    O.SetTest(mine[len(mine)], other.lua.table(), "combat")
    assert mine[len(mine)].when[1] == "combat" and O.Commit() is None
    O.Pick()
    assert O.InUse()
    other.talents((0, 0, 11))
    other.g.W.stance = 2
    other.rebuild()
    assert other.ns.Engine.custom and other.ns.Engine.key == "WARRIOR:3:2" and other.ns.Engine.Title() == "Protection, Defensive Stance"
    assert other.order()[-1] == "Rend"
    other.g.W.stance = 1
    other.rebuild()
    assert not other.ns.Engine.custom, "Battle Stance has its own rotation, still the built one"

    # Every edit was checked before use, and the built list is one click away.
    assert game.ns.Engine.Lint(own) is None
    E.Reset()
    assert not game.ns.Engine.custom and game.ns.db.lists["WARRIOR:0:0"] is None and game.order()[0] == "Battle Shout"
    assert game.ns.db.edited["WARRIOR:0:0"] is None
    print("ok  editor: reorder, add, remove; conditions built from ALL / ANY / NOT and taken apart again")


def check_editor_essentials():
    """Off without deleting, a second copy, the picker's list of spells, and undo and redo through all of it."""
    make = lambda: fighter((7386, 772, 78, 2687, 71), (0, 0, 11), stance=2, level=30)
    game = make()
    E, lua, engine = game.ns.Edit, game.lua, game.ns.Engine
    key = engine.key
    names = lambda: [game.ns.SpellName(r.spell) for r in E.Current().values()]
    built = names()
    assert not E.CanUndo() and not E.CanRedo() and E.Undo() is False and E.Redo() is False

    # Switched off: passed over everywhere, and still in its place with its condition.
    game.ns.Rules.Recount()
    rule, state, index, _ = engine.Suggest()
    first = state.name
    # (Sunder Armor has a second place in the order, for elites only: it does not come up here.)
    assert E.ToggleRule(index) is None and E.Current()[index].off is True and engine.custom
    assert names() == built and engine.Why(E.Current()[index]) == "switched off"
    assert game.next() != first and first not in game.queue(8) and first not in [name for name, _, _ in game.plan(8)]
    assert first not in [entry.state.name for entry in engine.Tracked().values()]
    # It travels in a share string as it is.
    other = make()
    assert other.ns.Edit.Import(E.Export())[0] is True and other.ns.Edit.Current()[index].off is True
    assert other.next() != first
    assert other.ns.Edit.Undo() is True and other.ns.Engine.Own(key) is None, "taking a rotation in can be undone"
    # And back on.
    assert E.ToggleRule(index) is None and E.Current()[index].off is None and game.next() == first

    # Undo and redo: back through both changes to the built rotation, and forward again.
    assert E.Undo() is True and E.Current()[index].off is True
    assert E.Undo() is True and not engine.custom and engine.Own(key) is None and not E.CanUndo() and E.CanRedo()
    assert E.Redo() is True and engine.custom and E.Current()[index].off is True
    assert E.Redo() is True and E.Current()[index].off is None and not E.CanRedo()
    assert E.Undo() is True and E.CanRedo()

    # A second copy, straight after the first, and its own from then on. A new change ends redo.
    assert E.Duplicate(index) is None and not E.CanRedo()
    assert len(names()) == len(built) + 1 and names()[index - 1] == names()[index] == first
    was = game.ns.Rules.Describe(E.Current()[index].when)
    assert E.Change(index + 1, E.AddPart, lua.table(), lua.eval('{ "elite" }')) is None
    assert game.ns.Rules.Describe(E.Current()[index].when) == was != game.ns.Rules.Describe(E.Current()[index + 1].when)
    assert E.Current()[index + 1].mine is True and E.Current()[index].mine is None
    assert E.Undo() is True and game.ns.Rules.Describe(E.Current()[index + 1].when) == was
    assert E.Undo() is True and len(names()) == len(built)

    # A change that does not take leaves nothing behind: no version of the player's own, nothing to undo.
    fresh = make()
    F = fresh.ns.Edit
    strike = next(i for i, r in fresh.ns.Engine.list.items() if fresh.ns.SpellName(r.spell) == "Heroic Strike")
    rage = next(row.path for row in F.Rows(fresh.ns.Engine.list[strike]).values() if row.node[1] == "power>=")
    assert F.Change(strike, F.SetValue, rage, "lots") == "That needs a number."
    assert not fresh.ns.Engine.custom and fresh.ns.Engine.Own(key) is None and not F.CanUndo()
    assert F.Change(99, F.SetValue, rage, "45") == "no ability is selected"
    assert F.Change(strike, F.SetValue, rage, "45") is None and fresh.ns.Engine.custom and F.CanUndo()
    assert "45" in fresh.ns.Rules.Describe(F.Current()[strike].when)

    # Adding goes after the selected ability, or at the end; moving, removing and going back to the built one undo too.
    assert F.AddRule("rend", 1) is None and [fresh.ns.SpellName(r.spell) for r in F.Current().values()][1] == "Rend"
    assert F.AddRule("rend", 0) is None and fresh.ns.SpellName(F.Current()[1].spell) == "Rend"
    count = len(F.Current())
    assert F.AddRule("rend") is None and fresh.ns.SpellName(F.Current()[count + 1].spell) == "Rend"
    assert F.RemoveRule(1) is None and F.Move(1, 3) is None
    kept = [fresh.ns.SpellName(r.spell) for r in F.Current().values()]
    F.Reset()
    assert not fresh.ns.Engine.custom and F.Undo() is True and fresh.ns.Engine.custom
    assert [fresh.ns.SpellName(r.spell) for r in F.Current().values()] == kept
    for _ in range(6):
        assert F.Undo() is True
    assert not fresh.ns.Engine.custom and not F.CanUndo()
    # Each rotation has its own history.
    assert F.AddRule("rend") is None and F.CanUndo()
    F.Pick(1, 1)
    assert not F.CanUndo()
    F.Pick()

    # The picker's list: the character's spells by name, those starting with what was typed first.
    every = [spell.name for spell in E.Spells("").values()]
    assert every == sorted(every) and {"Sunder Armor", "Rend", "Heroic Strike", "Bloodrage"} <= set(every)
    typed = [spell.name for spell in E.Spells("  S ").values()]
    assert typed == sorted(n for n in every if n.lower().startswith("s")) + sorted(n for n in every if "s" in n.lower() and not n.lower().startswith("s"))
    assert typed[0] == "Sunder Armor" and len(E.Spells("zzz")) == 0

    # The picker itself, on the stand-in's frames: typing narrows it, a click adds after the selected ability,
    # and Enter with nothing found adds what was typed.
    game.g.SlashCmdList.POLESTARNEXT("edit")
    E.OpenPicker()
    picker = next(f for f in game.g.FRAMES.values() if lua_type(f.rows) == "table" and lua_type(f.search) == "table")
    picker.search.GetText = lambda _self: "sun"
    picker.search.scripts.OnTextChanged(picker.search)
    assert picker.rows[1].spell.name == "Sunder Armor" and "Sunder Armor" in picker.rows[1].text.text
    before = names()
    picker.rows[1].scripts.OnClick(picker.rows[1])
    assert names() == before[:1] + ["Sunder Armor"] + before[1:], names()
    E.OpenPicker()
    picker.search.GetText = lambda _self: "Made Up Spell"
    picker.search.scripts.OnTextChanged(picker.search)
    assert len(picker.spells) == 0 and lua_type(picker.rows[1].spell) != "table"  # a stand-in frame answers nil with a function
    picker.search.scripts.OnEnterPressed(picker.search)
    assert "Made Up Spell" in names()
    E.Refresh()
    game.g.SlashCmdList.POLESTARNEXT("list")
    print("ok  editor essentials: off and on, duplicate, the spell picker, and undo and redo through every kind of change")


def check_update():
    """A kept rotation takes the built one's newer conditions, and keeps the player's order and their own changes."""
    make = lambda: fighter((7386, 772, 78, 2687, 6343, 71, 6673, 100, 7384), (0, 0, 6), stance=2, level=15)

    def aged(game):
        """The player's version as an earlier version of the add-on left it: Rend moved above
        Sunder Armor by the player, and four conditions as they were built back then."""
        E = game.ns.Edit
        order = [game.ns.SpellName(r.spell) for r in E.Current().values()]
        assert E.Move(order.index("Rend") + 1, order.index("Sunder Armor") + 1) is None
        own = E.List()
        by = lambda name, note=None: next(r for r in own.values() if game.ns.SpellName(r.spell) == name and note in (None, r.note))
        by("Bloodrage", "rage is low").when = game.lua.eval('{ "and", { "and", { "target" }, { "combat" } }, { "power<", 20 }, { "health%>=", 50 } }')
        by("Revenge").react, by("Overpower").react = None, None
        sunder = by("Sunder Armor")
        fading = next(row.node for row in E.Rows(sunder).values() if row.node[1] == "fading")
        assert fading[3] == 4.5
        fading[3] = 8
        assert E.Commit() is None
        return by

    game = make()
    E, rules = game.ns.Edit, game.ns.Rules
    names = lambda: [game.ns.SpellName(r.spell) for r in E.Current().values()]
    assert E.Behind() == 0 and E.Update() == 0, "the built rotation has nothing to catch up on"
    by = aged(game)
    assert E.Behind() == 4

    # The player's own doing is left alone: a condition they changed, an ability they added, one they switched off.
    order = names()
    strike = order.index("Heroic Strike") + 1
    rage = next(row.path for row in E.Rows(E.Current()[strike]).values() if row.node[1] == "power>=")
    assert E.Change(strike, E.SetValue, rage, "45") is None
    assert E.ToggleRule(order.index("Overpower") + 1) is None and E.AddRule("rend") is None
    order = names()
    assert E.Behind() == 4

    assert E.Update() == 4 and E.Behind() == 0 and names() == order, "the order is the player's still"
    fresh = {(game.ns.SpellName(r.spell), r.note): r for r in E.Built()[0].values()}
    for rule in E.Current().values():
        source = fresh.get((game.ns.SpellName(rule.spell), rule.note))
        if source is not None and not rule.mine:
            assert rules.Describe(rule.when) == rules.Describe(source.when), game.ns.SpellName(rule.spell)
            assert (rule.react or False) == (source.react or False) and (rule.toggle or False) == (source.toggle or False)
    assert "maybe" in [row.node[1] for row in E.Rows(by("Bloodrage", "rage is low")).values()]
    assert by("Overpower").react is True and by("Overpower").off is True and by("Revenge").react is True
    assert "45" in rules.Describe(by("Heroic Strike").when) and by("Heroic Strike").mine is True
    assert names()[-1] == "Rend" and names().index("Rend") < names().index("Sunder Armor")
    # It is one change, and Undo takes it back.
    assert E.Undo() is True and E.Behind() == 4 and E.Redo() is True and E.Behind() == 0

    # Once, for a rotation kept by a version before this one, it happens by itself at login, and says so.
    old = make()
    aged(old)
    assert old.ns.db.fresh is None
    for _ in range(8):
        old.display.scripts.OnUpdate(old.display, 0.11)
    said = "\n".join(old.g.SAID.values())
    assert old.ns.db.fresh == 8 and old.ns.Edit.Behind() == 0, said
    assert "Protection, Defensive Stance rotation is up to date" in said and "changed in 4 places" in said, said
    assert old.ns.Edit.Key() == old.ns.Engine.key and old.ns.Edit.CanUndo()
    # Only once: what the player does after that is theirs to keep or to update.
    old.ns.Edit.Undo()
    old.ns.Edit.Migrate()
    assert old.ns.Edit.Behind() == 4
    old.g.SlashCmdList.POLESTARNEXT("update")
    assert old.ns.Edit.Behind() == 0 and "up to date in 4 places" in old.g.SAID[len(old.g.SAID)]
    old.g.SlashCmdList.POLESTARNEXT("update")
    assert "nothing to bring up to date" in old.g.SAID[len(old.g.SAID)]

    # The built rotation moves on as well: an ability new to it goes into the player's version where it
    # belongs, one it no longer has comes out, and what the player took out or added themselves is left alone.
    moved = make()
    M = moved.ns.Edit
    order = [moved.ns.SpellName(r.spell) for r in M.Current().values()]
    assert M.Move(order.index("Rend") + 1, 1) is None  # the player's own order: Rend first
    kept = M.List()
    spot = lambda name: [moved.ns.SpellName(r.spell) for r in M.Current().values()].index(name) + 1
    was = [moved.ns.SpellName(r.spell) for r in kept.values()]
    # As an earlier version left it: no Sunder Armor yet, and an ability the built rotation has since dropped.
    moved.lua.globals().table.remove(kept, spot("Sunder Armor"))
    moved.lua.globals().table.remove(kept, spot("Sunder Armor"))
    moved.lua.globals().table.insert(kept, 3, moved.lua.eval('{ spell = { 78, "Heroic Strike" }, when = { "target" }, note = "an old place for it" }'))
    assert M.AddRule("heroic") is None and M.RemoveRule(spot("Thunder Clap")) is None  # the player's own doing
    assert M.Drift() == (2, 1) and M.Behind() == 3
    assert M.Update() == 3 and M.Behind() == 0 and M.Drift() == (0, 0)
    now = [(moved.ns.SpellName(r.spell), r.note) for r in M.Current().values()]
    names = [n for n, _ in now]
    assert names[0] == "Rend" and ("Heroic Strike", "an old place for it") not in now and now[-1] == ("Heroic Strike", "yours")
    sunders = [i for i, n in enumerate(names) if n == "Sunder Armor"]
    assert len(sunders) == 2 and names[sunders[0] - 1] == "Shield Slam" and names[sunders[1] + 1] == "Cleave", names
    assert names.count("Thunder Clap") == was.count("Thunder Clap") - 1, "what the player took out stays out"
    assert M.Undo() is True and M.Behind() == 3
    # Said once at login when the rotation in use is the player's own and the built one has moved on.
    moved.g.W.stance = 2
    moved.ns.db.fresh = 8  # the one-time update of old rotations is behind this character
    for _ in range(8):
        moved.display.scripts.OnUpdate(moved.display, 0.11)
    told = [line for line in moved.g.SAID.values() if "has moved on in 3 places" in line]
    assert len(told) == 1 and "(2 new abilities)" in told[0] and "/pnext update" in told[0], list(moved.g.SAID.values())[-3:]

    # A rotation taken in from someone else is all their doing: nothing in it is behind.
    sender, taker = make(), make()
    aged(sender)
    assert taker.ns.Edit.Import(sender.ns.Edit.Export())[0] is True and taker.ns.Edit.Behind() == 0

    # The window shows the button for it without a fault.
    old.ns.Edit.Undo()
    old.g.SlashCmdList.POLESTARNEXT("edit")
    old.ns.Edit.Refresh()
    print("ok  update: a kept rotation takes the newer conditions, in the player's order, their own changes untouched; once by itself")


BLOODRAGE = "Generates 10 rage at the cost of health, and then generates an additional 10 rage over 10 sec."


def check_preview():
    """The editor's timeline: the rotation shown, played out on paper from the start of a fight."""
    def make(stance=2, level=15, spells=(7386, 772, 78, 2687, 6343, 71, 6673, 7384, 6572, 5308)):
        game = fighter(spells, (0, 0, 6), stance=stance, level=level)
        game.spell(2687, BLOODRAGE, cd=60000, off=True)
        game.spell(6673, "The warrior shouts, increasing the attack power of the party. Lasts 2 min.", cost=10)
        game.rebuild()
        return game

    game = make()
    E, W, engine = game.ns.Edit, game.g.W, game.ns.Engine
    steps = lambda: [(e.state.name, round(e.at, 1), bool(e.free)) for e in E.Preview().steps.values()]
    names = lambda: [name for name, _, _ in steps()]
    presses = lambda: [(name, at) for name, at, free in steps() if not free]
    lane = lambda name: next((l for l in E.Preview().lanes.values() if l.name == name), None)

    # What it assumes, by the kind of bar: rage from nothing at five a second, one enemy.
    options = E.PreviewOptions()
    assert (options.bar, options.power, options.income, options.enemies, options.seconds) == ("rage", 0, 5, 1, 30)
    assert options.stance == 2 and options.inUse is True

    # The fight starts now: Bloodrage, whose rage pays for the shout above it in the order, the
    # attack beside them, then Sunder Armor to five as the rage comes in, each press a global
    # cooldown or more after the last.
    first = steps()
    assert first[:3] == [("Bloodrage", 0, True), ("Battle Shout", 0, False), ("Attack", 0, True)], first
    times = [at for _, at in presses()]
    assert times == sorted(times) and all(b - a >= 1.5 for a, b in zip(times, times[1:])) and times[-1] <= 30
    assert names().count("Sunder Armor") == 5 and names().count("Bloodrage") == 1 and names().count("Battle Shout") == 1
    sunder = lane("Sunder Armor")
    fifth = [at for name, at in presses() if name == "Sunder Armor"][4]
    assert (sunder.unit, sunder.cap, sunder.most, sunder.full) == ("target", 5, 5, fifth)
    assert len(sunder.spans) == 1 and sunder.spans[1].to == fifth + 30, "one unbroken bar, thirty seconds past the last one"
    assert lane("Battle Shout").unit == "player" and lane("Rend").unit == "target"
    # Bloodrage's ten rage is counted, and the shout spends it.
    entries = list(E.Preview().steps.values())
    assert [e.power for e in entries[:2]] == [10, 0]
    assert game.ns.Numbers.Parse(BLOODRAGE).gain == 10 and engine.Gain(2687) == 10 and engine.Gain(772) is None

    # Reactions have nothing to answer yet, usable or not; Execute waits for the enemy's last fifth.
    assert not {"Overpower", "Revenge"} & set(names())
    assert "Execute" in names() and all(at >= 24 for name, at, _ in steps() if name == "Execute")

    # It is a fight on paper: what is true of the real target, the real cooldowns and the real bar changes nothing.
    before = steps()
    game.effect("target", "Sunder Armor", 20, 30, stacks=5)
    game.effect("target", "Rend", 9, 12)
    W.cooldowns[2687], W.power, W.combat = game.lua.table(W.time - 5, 60), 77, True
    game.ns.Rules.Recount()
    assert steps() == before
    # ...and looking at it changes nothing about the real plan.
    real = game.plan(5)
    E.Preview()
    assert game.plan(5) == real and "Sunder Armor" not in [name for name, _, _ in real]
    # The player's own buffs are as they stand: with the shout up there is no shout to give.
    game.effect("player", "Battle Shout", 100, 120)
    game.ns.Rules.Recount()
    assert "Battle Shout" not in names() and names()[0] in ("Bloodrage", "Attack")

    # The two things the player sets: how fast the bar fills, and how many enemies.
    count = lambda: len(presses())
    stacked = lambda: [at for name, at in presses() if name == "Sunder Armor"][4]
    middling, slow = count(), stacked()
    E.StepPreview("income", -5)
    assert game.ns.db.preview.income.rage == 0 and count() < middling
    E.StepPreview("income", -1)
    assert E.PreviewOptions().income == 0, "not below nothing"
    for _ in range(40):
        E.StepPreview("income", 1)
    assert E.PreviewOptions().income == 30 and stacked() < slow, "more rage: five Sunder Armors sooner"
    assert "Thunder Clap" not in names()
    E.StepPreview("enemies", 1)
    assert E.PreviewOptions().enemies == 2 and "Thunder Clap" in names() and lane("Thunder Clap") is not None
    E.StepPreview("enemies", -5)
    assert E.PreviewOptions().enemies == 1

    # It is the rotation being edited: an ability moved, switched off, or given another condition shows at once.
    order = [game.ns.SpellName(r.spell) for r in E.Current().values()]
    assert E.Move(order.index("Rend") + 1, 1) is None and presses()[0] == ("Rend", 0)
    assert E.ToggleRule(1) is None and "Rend" not in names()
    assert E.Undo() and E.Undo() and not engine.custom

    # Another stance's rotation is played in that stance, with the abilities this stance does not allow.
    battle = make(stance=1, spells=(7386, 772, 78, 2687, 71, 2457, 6673, 100))
    B = battle.ns.Edit
    B.Pick(battle.ns.Scan.spec, 2)
    assert B.PreviewOptions().stance == 2 and B.PreviewOptions().inUse is False
    there = [e.state.name for e in B.Preview().steps.values()]
    assert "Sunder Armor" in there and "Defensive Stance" not in there, there
    B.Pick()

    # A rogue's bar starts full and fills by ten a second.
    rogue = Game("ROGUE", 20)
    rogue.g.W.powerType = 3
    rogue.learn(1752).rebuild()
    assert (lambda o: (o.bar, o.power, o.income))(rogue.ns.Edit.PreviewOptions()) == ("energy", 100, 10)

    # Execute and Hammer of Wrath no longer lean on the game's answer alone: a target seen to be healthy rules them out.
    finisher = make()
    F = finisher.g.W
    F.auras.player["Battle Shout"], F.auras.target["Rend"], F.auras.target["Sunder Armor"], F.power = True, True, 5, 15
    assert "Execute" not in finisher.queue(8)
    F.target.health = 10
    finisher.ns.Rules.Recount()
    assert "Execute" in finisher.queue(8), finisher.queue(8)
    F.secret = True  # hidden in a fight: the game's own "usable" decides, as before
    assert "Execute" in finisher.queue(8)
    F.usable[5308] = False
    assert "Execute" not in finisher.queue(8)

    # The band draws on the stand-in's frames; a click on an icon goes to its ability; the steppers step.
    game.g.SlashCmdList.POLESTARNEXT("edit")
    E.DrawPreview()
    icons = [f for f in game.g.FRAMES.values() if isinstance(f.words, str) and lua_type(f.tex) == "table"]
    assert len(icons) == len(steps()) and icons[0].words.startswith("|cffffd1000.0s|r  ")
    assert any("stack 3 of 5" in f.words for f in icons) and any("rage after it" in f.words for f in icons)
    icons[-1].scripts.OnEnter(icons[-1])
    icons[-1].scripts.OnLeave(icons[-1])
    icons[-1].scripts.OnClick(icons[-1])
    print("ok  preview: the rotation being edited played out on paper, with the bar, the enemies and the effects kept up")


# A character of each other class around level 30 to 40, with the game's figures for its spells:
# what each costs, how long it takes to cast, its cooldown, and the description the add-on reads.
KITS = {
    "ROGUE": dict(level=30, bar=(3, 100), weapon=ONE_HANDER, points=(0, 21, 0), spells={
        6603: {},
        1752: dict(cost=45, desc="An instant strike that causes 15 damage in addition to your normal weapon damage. Awards 1 combo point."),
        2098: dict(cost=35, desc="Finishing move that causes damage per combo point: 1 point: 30-46 damage 2 points: 54-70 damage"),
        5171: dict(cost=25, desc="Finishing move that increases melee attack speed by 20%. Lasts longer per combo point: 1 point : 9 seconds 2 points: 12 seconds"),
        1766: dict(cost=25, cd=10000, desc="A quick kick that interrupts spellcasting."),
        5277: dict(cd=300000, desc="Increases your dodge chance by 50%. Lasts 15 sec."),
    }),
    "MAGE": dict(level=30, bar=(0, 1800), points=(0, 0, 21), spells={
        1459: dict(cost=150, desc="Increases the target's Intellect by 7 for 30 min."),
        7302: dict(cost=100, desc="Increases your armor by 290. Lasts 30 min."),
        116: dict(cost=100, cast=2500, desc="Launches a bolt of frost at the enemy, causing 126 to 138 Frost damage and slowing movement speed by 40% for 7 sec."),
        2136: dict(cost=115, cd=8000, desc="Blasts the enemy for 103 to 127 Fire damage."),
        122: dict(cost=80, cd=25000, desc="Blasts enemies near the caster for 33 to 37 Frost damage and freezes them in place for up to 8 sec."),
        2139: dict(cost=100, cd=30000, desc="Counters the enemy's spellcast."),
        12051: dict(cd=480000, desc="While channeling this spell, your mana regeneration is active and increased."),
    }),
    "WARLOCK": dict(level=30, bar=(0, 1500), points=(21, 0, 0), spells={
        706: dict(cost=110, desc="Protects the caster, increasing armor by 210. Lasts 30 min."),
        172: dict(cost=100, cast=2000, desc="Corrupts the target, causing 222 Shadow damage over 18 sec."),
        980: dict(cost=90, desc="Curses the target with agony, causing 504 Shadow damage over 24 sec."),
        686: dict(cost=110, cast=3000, desc="Sends a shadowy bolt at the enemy, causing 150 to 170 Shadow damage."),
        1454: dict(desc="Converts 100 health into 100 mana."),
    }),
    "PRIEST": dict(level=40, bar=(0, 2500), wand=True, points=(0, 0, 31), spells={
        1243: dict(cost=400, desc="Power infuses the target, increasing their Stamina by 32 for 30 min."),
        588: dict(cost=200, desc="A burst of Holy energy fills the caster, increasing attack power by 20. Lasts 10 min."),
        17: dict(cost=250, cd=4000, desc="Draws on the soul of the party member to shield them, absorbing 381 damage. Lasts 30 sec."),
        589: dict(cost=190, desc="A word of darkness that causes 330 Shadow damage over 18 sec."),
        8092: dict(cost=150, cast=1500, cd=8000, desc="Blasts the target for 217 to 231 Shadow damage."),
        15407: dict(cost=100, desc="Assault the target's mind with Shadow energy, causing 186 Shadow damage over 3 sec and slowing their movement speed."),
        5019: {},
    }),
    "HUNTER": dict(level=30, bar=(0, 1400), bow=True, points=(0, 21, 0), spells={
        13165: dict(cost=50, desc="The hunter takes on the aspects of a hawk, increasing ranged attack power by 50. Lasts 30 min."),
        1130: dict(cost=30, desc="Places the Hunter's Mark on the target, increasing the ranged attack power of all attackers. Lasts 2 min."),
        75: {}, 6603: {}, 2973: dict(cost=15, cd=6000, desc="A strong attack that increases melee damage by 5."),
        1978: dict(cost=80, desc="Stings the target, causing 140 Nature damage over 15 sec."),
        3044: dict(cost=50, cd=6000, desc="An instant shot that causes 59 Arcane damage."),
        2643: dict(cost=100, cd=10000, desc="Fires several missiles, hitting 3 targets for an additional 40 damage."),
        19434: dict(cost=115, cast=3000, cd=6000, desc="An aimed shot that increases ranged damage by 70."),
    }),
    "PALADIN": dict(level=30, bar=(0, 1500), weapon=TWO_HANDER, points=(0, 0, 21), spells={
        6603: {},
        19740: dict(cost=85, desc="Places a Blessing on the friendly target, increasing attack power by 55 for 5 min."),
        21084: dict(cost=60, desc="Fills the Paladin with holy spirit, granting each melee attack additional Holy damage. Lasts 30 sec."),
        20271: dict(cost=70, cd=10000, desc="Unleashes the energy of a Seal spell upon an enemy."),
        853: dict(cost=50, cd=60000, desc="Stuns the target for 3 sec."),
        24275: dict(cost=295, cast=1000, cd=6000, desc="Hurls a hammer that strikes an enemy for 304 to 336 Holy damage. Only usable on enemies that have 20% or less health."),
    }),
    "SHAMAN": dict(level=40, bar=(0, 2200), weapon=TWO_HANDER, points=(0, 31, 0), imbue=True, spells={
        6603: {},
        324: dict(cost=110, desc="The caster is surrounded by 3 balls of lightning. Lasts 10 min."),
        8232: dict(cost=115, desc="Imbue the Shaman's weapon with wind."),
        403: dict(cost=105, cast=3000, desc="Casts a bolt of lightning at the target for 128 to 154 Nature damage."),
        17364: dict(cost=180, cd=12000, desc="Gives you an extra attack."),
        8050: dict(cost=160, cd=6000, desc="Instantly sears the target with fire, causing 86 Fire damage immediately and 96 Fire damage over 12 sec."),
        8042: dict(cost=145, cd=6000, desc="Instantly shocks the target with concussive force, causing 235 to 249 Nature damage."),
    }),
    "DRUID": dict(level=30, bar=(3, 100), points=(0, 21, 0), forms=(5487, 768), stance=2, form=1, spells={
        6603: {},
        768: dict(cost=100, desc="Shapeshift into cat form."),
        5487: dict(cost=100, desc="Shapeshift into bear form."),
        1822: dict(cost=35, desc="Rake the target for 19 damage and an additional 39 damage over 9 sec. Awards 1 combo point."),
        1082: dict(cost=40, desc="Claw the enemy, causing 27 additional damage. Awards 1 combo point."),
        22568: dict(cost=35, desc="Finishing move that causes damage per combo point and converts each extra point of energy into additional damage."),
    }),
}
BOW = ("INVTYPE_RANGED", 2, 2)


def hero(cls):
    """A character of `cls` with its kit learned, its bar full, and nothing targeted."""
    kit = KITS[cls]
    game = Game(cls, kit["level"])
    if kit.get("weapon"):
        game.wear(16, *kit["weapon"])
    if kit.get("wand"):
        game.wear(18, *WAND)
    if kit.get("bow"):
        game.wear(18, *BOW)
    for spell_id, facts in kit["spells"].items():
        game.spell(spell_id, **facts)
    W = game.g.W
    W.powerType, W.powerMax = kit["bar"]
    W.power = kit["bar"][1]
    if kit.get("forms"):
        game.lua.execute("function GetNumShapeshiftForms() return %d end function GetShapeshiftFormInfo(place) return 0, W.stance == place, true, ({ %s })[place] end"
                         % (len(kit["forms"]), ", ".join(str(i) for i in kit["forms"])))
        W.stance, W.form = kit["stance"], kit["form"]
    W.imbue = kit.get("imbue", False)
    game.learn(*kit["spells"].keys()).talents(kit["points"])
    game.rebuild()
    return game


def check_class_plans():
    """Every class's rotation played out on paper with the game's real figures: casts and channels
    take their time, combo points are built and spent, energy and mana are counted."""
    played = {}
    for cls, kit in KITS.items():
        game = hero(cls)
        options = game.ns.Edit.PreviewOptions()
        steps = list(game.ns.Edit.Preview().steps.values())
        played[cls] = (game, steps, options)
        assert len(steps) >= 8, (cls, len(steps))
        presses = [e for e in steps if not e.free]
        pause = options.pause or 1.5
        # A press takes its slot: the global cooldown, or its own cast or channel where that is longer.
        for a, b in zip(presses, presses[1:]):
            assert b.at - a.at >= max(pause, a.cast or 0, a.channel or 0) - 0.01, (cls, a.state.name, a.at, b.state.name, b.at)
        # The bar is never overdrawn, and what is spent is what the game says the spell costs.
        bar = options.power
        for e in steps:
            cost = game.ns.Engine.Cost(e.state.id) or 0
            assert e.power is not None and 0 <= e.power <= options.ceiling, (cls, e.state.name, e.power)
        # An effect is not put back while it has more than a moment left.
        last = {}
        for e in steps:
            if game.ns.Engine.Kind(e.rule).spends:
                last.clear()  # what it uses up (a seal) is rightly put back at once
            if e.puts and e.puts.cap == 1:
                assert e.at >= last.get(e.state.name, -99) - 1.05 - (e.cast or 0), (cls, e.state.name, e.at, last)
                last[e.state.name] = e.puts.to

    def line(cls):
        return [(e.state.name, round(e.at, 1)) for e in played[cls][1]]

    def times(cls, name):
        return [at for n, at in line(cls) if n == name]

    def entries(cls, name):
        return [e for e in played[cls][1] if e.state.name == name]

    # Rogue: energy, a one-second global cooldown, and combo points built and spent.
    game, steps, options = played["ROGUE"]
    assert (options.bar, options.power, options.income, options.pause) == ("energy", 100, 10, 1)
    assert line("ROGUE")[:4] == [("Attack", 0), ("Sinister Strike", 0), ("Slice and Dice", 1), ("Sinister Strike", 2)], line("ROGUE")[:4]
    points = 0
    for e in steps:
        kind = game.ns.Engine.Kind(e.rule).combo
        if kind == "spend":
            assert points >= 1 and e.combo == 0, (e.state.name, e.at, points)
            points = 0
        elif kind:
            points = min(5, points + kind)
            assert e.combo == points
    assert [e.power for e in steps[:4]] == [100, 55, 40, 5], "100 energy, ten more a second, 45 a strike"
    gaps = [b - a for a, b in zip(times("ROGUE", "Sinister Strike")[1:], times("ROGUE", "Sinister Strike")[2:])]
    assert all(gap >= 3.5 for gap in gaps), "after the first two, a strike only as fast as the energy comes in"
    assert len(times("ROGUE", "Slice and Dice")) >= 2 and times("ROGUE", "Eviscerate") and times("ROGUE", "Eviscerate")[0] > 15, "kept up; Eviscerate once the enemy is going down"

    # Mage: the filler takes its cast time, the mana goes down, and the instant finisher comes at the end.
    game, steps, options = played["MAGE"]
    assert line("MAGE")[:3] == [("Arcane Intellect", 0), ("Ice Armor", 1.5), ("Frostbolt", 3)]
    bolts = times("MAGE", "Frostbolt")
    assert len(bolts) >= 9 and all(abs(b - a - 2.5) < 0.01 or b - a >= 2.5 for a, b in zip(bolts, bolts[1:])) and bolts[1] - bolts[0] == 2.5
    assert all(e.cast == 2.5 for e in entries("MAGE", "Frostbolt")) and times("MAGE", "Fire Blast") and min(times("MAGE", "Fire Blast")) >= 22.5
    assert steps[0].power == 1650 and steps[-1].power < 600 and "Evocation" not in dict(line("MAGE"))

    # Warlock: the effects go on once each and are not wasted on a dying enemy; Life Tap when the mana is low.
    game, steps, options = played["WARLOCK"]
    assert line("WARLOCK")[:4] == [("Demon Armor", 0), ("Bane of Agony", 1.5), ("Corruption", 3), ("Shadow Bolt", 5)], line("WARLOCK")[:4]
    assert entries("WARLOCK", "Corruption")[0].puts.to == 23, "two seconds to cast, eighteen on the target"
    assert len(times("WARLOCK", "Corruption")) == 1 and len(times("WARLOCK", "Bane of Agony")) == 1
    bolts = times("WARLOCK", "Shadow Bolt")
    assert all(b - a >= 3 for a, b in zip(bolts, bolts[1:])) and times("WARLOCK", "Life Tap")
    # Under 40% mana: a Life Tap, whose mana the plan counts, then back to casting.
    order = [n for n, _ in line("WARLOCK")]
    tap = entries("WARLOCK", "Life Tap")[0]
    assert all(e.power / options.ceiling >= 0.4 for e in steps if e.at < tap.at - 3.1) and tap.power == 640
    assert all(order[i + 1] != "Life Tap" for i, n in enumerate(order[:-1]) if n == "Life Tap"), "never twice running"

    # Priest: a channel holds its three seconds, Mind Blast has its cooldown, and the wand is for
    # when the mana is better kept, not beside the casts.
    game, steps, options = played["PRIEST"]
    assert [n for n, _ in line("PRIEST")[:6]] == ["Power Word: Fortitude", "Inner Fire", "Power Word: Shield", "Shadow Word: Pain", "Mind Blast", "Mind Flay"]
    flays = entries("PRIEST", "Mind Flay")
    assert flays and all(e.channel == 3 and e.cast is None for e in flays)
    blasts = times("PRIEST", "Mind Blast")
    assert len(blasts) >= 2 and blasts[1] - blasts[0] >= 9.5, "a second and a half to cast, eight to come back"
    wand = entries("PRIEST", "Shoot")
    assert len(wand) == 1 and not wand[0].free and wand[0].at > 10 and all(e.power / options.ceiling < 0.4 for e in steps if e.at >= wand[0].at)
    pain = times("PRIEST", "Shadow Word: Pain")
    assert len(pain) == 2 and 17 <= pain[1] - pain[0] <= 18.01, "put back in the last moment before it drops"

    # Hunter: the shot that repeats runs beside the others; at range nothing of the melee comes up.
    game, steps, options = played["HUNTER"]
    assert ("Auto Shot", 0) in line("HUNTER") and entries("HUNTER", "Auto Shot")[0].free and options.melee is False
    assert not {"Attack", "Raptor Strike"} & {n for n, _ in line("HUNTER")}
    # Forever: Aimed Shot opens (its cast costs nothing before the fight) and shares its cooldown
    # with Multi-Shot, which is the one used once the fight is on.
    aimed, multi = times("HUNTER", "Aimed Shot"), times("HUNTER", "Multi-Shot")
    shots = [n for n, _ in line("HUNTER") if n in ("Aimed Shot", "Multi-Shot", "Arcane Shot", "Serpent Sting")]
    assert len(aimed) == 1 and shots[0] == "Aimed Shot" and entries("HUNTER", "Aimed Shot")[0].cast == 3
    assert len(multi) >= 2 and multi[0] - aimed[0] >= 9, "three seconds to aim, then the six they share"
    assert len(times("HUNTER", "Serpent Sting")) == 2 and all(b - a >= 10 for a, b in zip(multi, multi[1:]))

    # Paladin: Judgement uses the seal up, so the seal goes straight back on; the hammer waits for the end.
    game, steps, options = played["PALADIN"]
    order = [n for n, _ in line("PALADIN")]
    judged = [i for i, n in enumerate(order) if n == "Judgement"]
    assert len(judged) >= 3 and all(order[i - 1] == "Seal of Righteousness" and order[i + 1] == "Seal of Righteousness" for i in judged), order
    assert all(b - a >= 10 for a, b in zip(times("PALADIN", "Judgement"), times("PALADIN", "Judgement")[1:]))
    assert times("PALADIN", "Hammer of Wrath") and min(times("PALADIN", "Hammer of Wrath")) >= 24 and entries("PALADIN", "Hammer of Wrath")[0].cast == 1

    # Shaman: the shocks share their cooldown.
    game, steps, options = played["SHAMAN"]
    shocks = sorted(times("SHAMAN", "Flame Shock") + times("SHAMAN", "Earth Shock"))
    assert len(shocks) >= 3 and times("SHAMAN", "Earth Shock") and all(b - a >= 6 for a, b in zip(shocks, shocks[1:])), shocks
    assert all(b - a >= 12 for a, b in zip(times("SHAMAN", "Stormstrike"), times("SHAMAN", "Stormstrike")[1:])) and len(times("SHAMAN", "Stormstrike")) == 3
    # The shield goes up first, and the pull is still a pull: the attack being on does not spend the opener.
    assert line("SHAMAN")[:3] == [("Lightning Shield", 0), ("Attack", 0), ("Lightning Bolt", 1.5)], line("SHAMAN")[:3]

    # Druid: the Cat Form rotation is played in Cat Form, on energy, whatever bar the druid has now.
    game, steps, options = played["DRUID"]
    assert (options.form, options.bar, options.power, options.pause) == (1, "energy", 100, 1)
    assert line("DRUID")[:3] == [("Attack", 0), ("Rake", 0), ("Claw", 1)], line("DRUID")[:3]
    bites = entries("DRUID", "Ferocious Bite")
    assert bites and all(e.combo == 0 for e in bites)
    before = [e for e in steps if e.at < bites[0].at and e.combo is not None][-1]
    assert before.combo == 5, "the bite waits for five points while the enemy is healthy"
    caster = hero("DRUID")
    caster.g.W.stance, caster.g.W.form, caster.g.W.powerType, caster.g.W.powerMax = 0, 0, 0, 1200
    caster.rebuild()
    caster.ns.Edit.Pick(2, 2)  # looking at the Cat Form rotation from out of form
    there = caster.ns.Edit.PreviewOptions()
    assert (there.form, there.bar, there.ceiling, there.inUse) == (1, "energy", 100, False)
    assert "Rake" in [e.state.name for e in caster.ns.Edit.Preview().steps.values()]

    # What a spell is, where its name does not say: read from its description.
    probe = hero("ROGUE")
    probe.learn("Shadow Step Strike", "Garrote Finish")
    probe.spell(probe.id_of("Shadow Step Strike"), "Strike from the shadows. Awards 2 combo points.", cost=40)
    probe.spell(probe.id_of("Garrote Finish"), "Finishing move that strangles the enemy.", cost=30)
    probe.rebuild()
    kind = lambda name: probe.ns.Engine.Kind(probe.lua.table(spell=probe.lua.table(probe.id_of(name), name)))
    assert kind("Shadow Step Strike").combo == 2 and kind("Garrote Finish").combo == "spend" and kind("Sinister Strike").combo == 1
    assert played["PRIEST"][0].ns.Engine.Kind(played["PRIEST"][0].lua.eval('{ spell = { 15407, "Mind Flay" } }')).channel == 3

    # In a real fight, with the bar hidden as Forever hides it, every class still has something to press:
    # mana kept in reserve is a margin, not a wall.
    fillers = {"MAGE": "Frostbolt", "WARLOCK": "Shadow Bolt", "PRIEST": "Mind Blast", "HUNTER": "Multi-Shot",
               "PALADIN": "Seal of Righteousness", "SHAMAN": "Stormstrike", "ROGUE": "Sinister Strike", "DRUID": "Rake"}
    for cls, filler in fillers.items():
        game = hero(cls)
        W = game.g.W
        W.combat, W.secret = True, True
        game.g.target(game.lua.table(**MOB))
        assert game.next() is not None and filler in game.queue(8), (cls, game.queue(8))

    # A hidden mana bar is pinned down by what the game still says can be cast.
    mage = hero("MAGE")
    W = mage.g.W
    W.combat, W.secret = True, True
    mage.g.target(mage.lua.table(**MOB))
    check = lambda *c: mage.ns.Rules.Check(mage.lua.table(*c))
    assert check("mana%>=", 5) is True, "Arcane Intellect at 150 of 1800 can be cast: at least 8%"
    assert check("mana%>=", 50) is None and check("mana%<", 15) is None
    for spell in (116, 2136, 122, 2139, 1459, 7302):
        W.shortOf[spell] = True
    mage.ns.Rules.Recount()
    assert check("mana%<", 15) is True and check("mana%>=", 15) is False, "nothing down to 80 mana can be cast: under 5%"
    assert mage.next() == "Evocation"

    # With the bar shown, the live plan counts the same things: casts, energy coming in, combo points.
    live = hero("MAGE")
    live.g.W.combat = True
    live.g.target(live.lua.table(**MOB))
    live.g.W.auras.player["Arcane Intellect"], live.g.W.auras.player["Ice Armor"] = True, True
    assert [(n, at) for n, at, _ in live.plan(3)] == [("Frostbolt", 0), ("Frostbolt", 2.5), ("Frostbolt", 5)]
    live = hero("ROGUE")
    live.g.W.combat, live.g.W.combo, live.g.W.power = True, 4, 100
    live.g.target(live.lua.table(**MOB))
    live.g.W.auras.player["Slice and Dice"] = True
    plan = [n for n, _, _ in live.plan(4)]
    assert plan[:3] == ["Attack", "Sinister Strike", "Eviscerate"], plan

    # The timeline says how long a press takes and what it leaves.
    game = played["MAGE"][0]
    game.g.SlashCmdList.POLESTARNEXT("edit")
    words = [f.words for f in game.g.FRAMES.values() if isinstance(f.words, str) and lua_type(f.tex) == "table"]
    assert any("(2.5s cast)" in w and "mana after it" in w for w in words), words[:4]
    game = played["ROGUE"][0]
    game.g.SlashCmdList.POLESTARNEXT("edit")
    words = [f.words for f in game.g.FRAMES.values() if isinstance(f.words, str) and lua_type(f.tex) == "table"]
    assert any("1 combo point" in w and "energy after it" in w for w in words), words[:4]
    print("ok  every class planned: casts and channels, combo points, energy and mana, shared cooldowns, and a hidden bar")


def check_forever():
    """The rotations follow World of Warcraft: Forever where it differs from Classic."""
    ELITE = dict(MOB, kind="elite")

    def fight(game, mob=MOB):
        game.g.W.combat = True
        game.g.W.current[6603] = True
        game.g.target(game.lua.table(**mob))
        return game

    # Nothing Forever does not have is listed any more.
    for gone in ("Tiger's Fury", "Mangle", "Starsurge", "Crusader Strike", "Divine Storm", "Kill Command", "Chimera Shot", "Explosive Shot", "Haunt", "Lava Lash", "Curse of Agony"):
        assert '"%s"' % gone not in CLASSES_SOURCE, gone

    # Warrior. Victory Rush: free and healing, there when the game lights it after a kill.
    tank = Game("WARRIOR", 40).wear(16, *ONE_HANDER).wear(17, *SHIELD)
    for spell_id, facts in WARRIOR_FACTS.items():
        tank.spell(spell_id, **facts)
    tank.spell(2565, "Increases chance to block by 75% for 5 sec.", cost=10, cd=5000, off=True)
    tank.spell(6343, "Blasts nearby enemies, slowing their attacks. Lasts 30 sec.", cost=20, cd=6000)
    tank.learn(6603, 7386, 78, 6572, 23922, 2565, 34428, 6343, 100, 71, 2687, 6673).talents((0, 0, 31), Vanguard=1)
    W = tank.g.W
    W.stance, W.power, W.auras.player["Battle Shout"] = 2, 100, True
    W.usable[34428], W.usable[6572] = False, False
    tank.rebuild()
    # Vanguard: Charge opens from Defensive Stance.
    tank.g.target(tank.lua.table(**MOB))
    assert tank.next() == "Charge" and "Vanguard" in tank.notes()
    fight(tank)
    # A shield: Shield Block whenever it is up, beside the press, to set Revenge up; Shield Slam the press.
    assert "40 rage" in tank.notes() and "Shield Block whenever it is up" in tank.notes()
    plan = tank.plan(4)
    assert ("Shield Block", 0, False) in plan and ("Shield Slam", 0, False) in plan, plan
    W.usable[34428] = None
    assert tank.next() == "Victory Rush" and [n for n, _, _ in tank.plan(8)].count("Victory Rush") == 1, "once: it answers a kill"
    assert "Victory Rush" not in [e.state.name for e in tank.ns.Edit.Preview().steps.values()], "nothing has been killed on paper"
    W.usable[34428] = False
    # A normal enemy: Sunder Armor to five and no more; Thunder Clap is for crowds.
    W.cooldowns[23922], W.auras.target["Sunder Armor"] = tank.lua.table(W.time - 1, 6), 5
    tank.effect("target", "Sunder Armor", 25, 30, stacks=5)
    assert "Thunder Clap" not in tank.queue(8) and "Sunder Armor" not in tank.queue(8), tank.queue(8)
    # An elite: slow its attacks, and keep sundering for threat while there is the rage.
    fight(tank, ELITE)
    tank.effect("target", "Sunder Armor", 25, 30, stacks=5)
    assert tank.queue(8)[:3] == ["Shield Block", "Thunder Clap", "Sunder Armor"], tank.queue(8)
    # Protection talents with a two-hander: no shield abilities, and the notes say what that costs.
    bare = fighter((7386, 772, 78, 2687, 71, 2565), (0, 0, 6), stance=2, level=15, Shield_Specialization=3)
    assert "need a shield" in bare.notes() and "Shield Specialization gives nothing without one" in bare.notes()
    assert "Shield Block" not in [bare.ns.SpellName(r.spell) for r in bare.ns.Engine.list.values()]
    assert "30 rage" in bare.notes()
    # Arms with Improved Slam: Slam between Mortal Strikes; without the talent it is left out.
    arms = fighter((12294, 1464, 772, 78, 2457), (31, 0, 0), stance=1, level=40, Improved_Slam=2)
    arms.spell(1464, "Slams the opponent, causing weapon damage plus 32.", cost=15, cast=1500)
    arms.g.W.auras.target["Rend"] = True
    arms.rebuild()
    names = [n for n, _, _ in arms.plan(6)]
    assert "Slam" in names and names.index("Mortal Strike") < names.index("Slam") and "60 rage" in arms.notes(), (names, arms.notes())
    plain = fighter((12294, 1464, 772, 78, 2457), (31, 0, 0), stance=1, level=40)
    assert "Slam" not in [plain.ns.SpellName(r.spell) for r in plain.ns.Engine.list.values()]

    # Procs: what the game lights up, or the effect that makes it worth pressing, comes before the filler.
    mage = hero("MAGE")
    mage.learn(30455, 11366, "Fingers of Frost", "Heating Up").rebuild()
    M = fight(mage).g.W
    M.auras.player["Arcane Intellect"], M.auras.player["Ice Armor"] = True, True
    assert mage.next() == "Frostbolt" and "Ice Lance" not in mage.queue(8) and "Pyroblast" not in mage.queue(8)
    M.auras.player["Fingers of Frost"] = True
    assert mage.next() == "Ice Lance"
    M.auras.player["Fingers of Frost"], M.auras.player["Heating Up"] = None, 2
    assert mage.next() == "Frostbolt"
    M.auras.player["Heating Up"] = 3
    assert mage.next() == "Pyroblast"
    # Hidden in a fight, the effect cannot be read: the game's own glow on the button still can.
    M.secret = True
    mage.ns.Rules.Recount()
    assert "Pyroblast" not in mage.queue(8) and "Ice Lance" not in mage.queue(8)
    M.lit[30455] = True
    lit = mage.queue(8)
    assert "Ice Lance" in lit and lit.index("Ice Lance") < lit.index("Frostbolt"), lit
    M.secret, M.lit[30455], M.auras.player["Heating Up"] = False, None, None
    assert "Ice Lance" not in [e.state.name for e in mage.ns.Edit.Preview().steps.values()], "a proc cannot be planned for"

    shaman = hero("SHAMAN")
    shaman.learn("Maelstrom Weapon").rebuild()
    S = fight(shaman).g.W
    S.auras.player["Lightning Shield"] = True
    S.auras.player["Maelstrom Weapon"] = 4
    assert shaman.next() == "Stormstrike"
    S.auras.player["Maelstrom Weapon"] = 5
    assert shaman.next() == "Lightning Bolt"

    # Warlock: banes, the Nightfall proc, and Wrack once the effects it hurries are on.
    lock = hero("WARLOCK")
    lock.learn(603, "Wrack").rebuild()
    lock.spell(lock.id_of("Wrack"), "Channels dark energy into the target for 6 sec.", cost=100)
    lock.rebuild()
    L = fight(lock).g.W
    L.auras.player["Demon Armor"] = True
    assert lock.next() == "Bane of Agony" and "Bane of Doom" not in lock.queue(8)
    L.auras.target["Bane of Agony"] = True
    assert lock.next() == "Corruption"
    L.auras.target["Corruption"] = True
    assert lock.next() == "Wrack" and lock.ns.Engine.Kind(next(r for r in lock.ns.Engine.list.values() if lock.ns.SpellName(r.spell) == "Wrack")).channel == 6
    L.auras.player["Shadow Trance"] = True
    assert lock.next() == "Shadow Bolt", "Nightfall: the instant one first"
    L.auras.player["Shadow Trance"], L.auras.target["Bane of Agony"] = None, None
    fight(lock, ELITE)
    assert lock.next() == "Bane of Doom", "on something that will live the minute"
    L.auras.target["Bane of Doom"] = True
    assert "Bane of Agony" not in lock.queue(8), "one bane at a time"

    # Druid: a bear stacks Lacerate and bites; a cat turns mana into energy when it runs low; Balance is Eclipse.
    bear = Game("DRUID", 45)
    bear.lua.execute("function GetNumShapeshiftForms() return 2 end function GetShapeshiftFormInfo(place) return 0, W.stance == place, true, ({ 5487, 768 })[place] end")
    bear.learn(6603, 5487, 768, 6807, "Lacerate", "Primal Bite", "Shifting Power", 1082).talents((0, 31, 0))
    B = bear.g.W
    B.stance, B.form, B.powerType, B.power = 1, 5, 1, 60
    bear.rebuild()
    fight(bear)
    assert bear.next() == "Lacerate"
    B.auras.target["Lacerate"] = 5
    bear.effect("target", "Lacerate", 12, 15, stacks=5)
    assert bear.next() == "Primal Bite"
    B.stance, B.form, B.powerType, B.power = 2, 1, 3, 30
    bear.rebuild()
    assert "Shifting Power" in bear.queue(8)
    B.power = 90
    bear.ns.Rules.Recount()
    assert "Shifting Power" not in bear.queue(8) and bear.next() == "Claw"
    owl = Game("DRUID", 40)
    owl.g.W.powerType = 0
    owl.learn(5176, 2912, 8921, "Eclipse").talents((31, 0, 0), Eclipse=1).rebuild()
    O = fight(owl).g.W
    O.auras.target["Moonfire"] = True
    for name in ("Mark of the Wild", "Thorns", "Moonkin Form"):
        O.auras.player[name] = True
    assert owl.next() == "Wrath" and "Eclipse" in owl.notes()
    O.auras.player["Eclipse"] = 2
    assert owl.next() == "Starfire"

    # Rogue: Shank when the energy runs low; Subtlety keeps Rupture on anything; Death Mark at five points.
    rogue = hero("ROGUE")
    rogue.learn("Shank", "Death Mark", 1943).talents((0, 0, 21)).rebuild()
    R = fight(rogue).g.W
    R.auras.player["Slice and Dice"] = True
    R.power = 100
    assert "Shank" not in rogue.queue(8)
    R.power = 40
    rogue.ns.Rules.Recount()
    assert rogue.next() == "Shank"
    R.power, R.combo = 100, 5
    rogue.ns.Rules.Recount()
    assert rogue.queue(8)[:2] == ["Rupture", "Death Mark"], rogue.queue(8)

    # Priest: Shadow Word: Death in a fight, after Mind Blast. Paladin: Holy Strike before Judgement, and
    # Swift Judgement while Judgement is on cooldown; a tank takes Seal of Fury.
    priest = hero("PRIEST")
    priest.learn(32379).rebuild()
    P = fight(priest).g.W
    for name in ("Power Word: Fortitude", "Inner Fire", "Power Word: Shield"):
        P.auras.player[name] = True
    P.auras.target["Shadow Word: Pain"] = True
    order = priest.queue(8)
    assert order.index("Mind Blast") < order.index("Shadow Word: Death") < order.index("Mind Flay"), order
    paladin = hero("PALADIN")
    paladin.learn("Holy Strike", "Swift Judgement", "Seal of Fury").rebuild()
    A = fight(paladin).g.W
    A.auras.player["Blessing of Might"], A.auras.player["Seal of Righteousness"] = True, True
    order = paladin.queue(8)
    assert order.index("Holy Strike") < order.index("Judgement") and "Swift Judgement" not in order, order
    A.cooldowns[20271] = paladin.lua.table(A.time - 1, 10)
    paladin.ns.Rules.Recount()
    assert "Swift Judgement" in paladin.queue(8)
    A.auras.player["Seal of Righteousness"] = None
    assert paladin.next() == "Seal of Righteousness"
    paladin.wear(17, *SHIELD).rebuild()
    assert paladin.next() == "Seal of Fury" and "Seal of Fury" in paladin.notes()

    # The new tests read as words, and show in the editor.
    E = mage.ns.Edit
    assert E.Plain(mage.lua.eval('{ "or", { "lit", { 30455, "Ice Lance" } }, { "charges>=", { nil, "Heating Up" }, 3 } }')) \
        == "the game lights Ice Lance up or you have 3 or more stacks of Heating Up"
    assert E.Label(mage.lua.eval('{ "charges>=", { nil, "Heating Up" }, 3 }')) == "I have 3 or more stacks of Heating Up"
    assert E.Label(mage.lua.eval('{ "charges>=", { nil, "Fingers of Frost" }, 1 }')) == "I have a stack or more of Fingers of Frost"
    print("ok  forever: Victory Rush, shield and elite tanking, procs, banes, Wrack, Lacerate, Eclipse, Shank and the rest as Forever has them")


def check_plain_words():
    """Each rule summed up in a sentence, and the ready-made conditions to pick from."""
    game = fighter((7386, 772, 78, 2687, 6343, 71, 6673, 7384, 5308), (0, 0, 6), stance=2, level=15)
    E, lua = game.ns.Edit, game.lua
    plain = lambda source, own=None: E.Plain(lua.eval(source), own)

    # Tests said both ways, so a NOT is never read as one; groups run together; the rule's own spell is "it".
    assert plain('{ "target" }') == "you have a target" and E.Plain(None) == "always"
    assert plain('{ "not", { "moving" } }') == "you are standing still"
    assert plain('{ "and", { "target" }, { "combat" } }') == "you are fighting something"
    assert plain('{ "and", { "target" }, { "not", { "combat" } } }') == "you are about to start a fight"
    assert plain('{ "and", { "and", { "target" }, { "combat" } }, { "power>=", 30 } }') == "you are fighting something and rage is 30 or more"
    assert plain('{ "not", { "debuff", { 772, "Rend" } } }', "Rend") == "it is not on the target"
    assert plain('{ "not", { "debuff", { 772, "Rend" } } }', "Sunder Armor") == "Rend is not on the target"
    assert plain('{ "not", { "or", { "buff", { 6673, "Battle Shout" } }, { "elite" } } }') == "you do not have Battle Shout and the target is not elite"
    assert plain('{ "not", { "and", { "moving" }, { "stealth" } } }') == "you are standing still or you are not stealthed"
    assert plain('{ "maybe", { "health%>=", 50 } }') == "your health is 50% or more (as far as the game shows)"
    assert plain('{ "and", { "or", { "stacks<", { 7386, "Sunder Armor" }, 5, 30 }, { "fading", { 7386, "Sunder Armor" }, 4.5, 30 } }, { "target" }, { "combat" } }', "Sunder Armor") \
        == "you are fighting something and either it is stacked fewer than 5 times or it has under 4.5 seconds left"
    assert plain('{ "or", { "combo>=", 5 }, { "and", { "combo>=", 1 }, { "target%<", 35 } } }') \
        == "you have at least 5 combo points or both you have at least 1 combo point and the target's health is under 35%"
    assert plain('{ "and", { "stance", 2 }, { "not", { "enemies>=", 2 } }, { "power<", 20 } }') \
        == "you are in Defensive Stance, fewer than 2 enemies are in reach and rage is under 20"
    # Every test the editor offers has its words, both ways round.
    for entry in E.TESTS.values():
        argument = '{ 772, "Rend" }' if entry[2] == "spell" else ("3" if entry[2] == "number" else "nil")
        bare = game.ns.Rules.Describe(lua.eval('{ "%s", %s }' % (entry[1], argument)))  # what an unknown test falls back on
        both = [plain(source) for source in ('{ "%s", %s }' % (entry[1], argument), '{ "not", { "%s", %s } }' % (entry[1], argument))]
        assert all(both) and both[0] != both[1] and not {bare, "not " + bare} & set(both), (entry[1], both)
    assert len({plain('{ "%s", 3 }' % e[1]) for e in E.TESTS.values() if e[2] == "number"}) == len([e for e in E.TESTS.values() if e[2] == "number"])

    # A whole rule, with what else there is to say about it.
    by = lambda name, note=None: next(r for r in E.Current().values() if game.ns.SpellName(r.spell) == name and note in (None, r.note))
    assert E.Summary(by("Battle Shout")) == "Use Battle Shout when you do not have it."
    assert E.Summary(by("Rend")) == "Use Rend when you are fighting something, it is not on the target and the target's health is 35% or more (as far as the game shows)."
    assert E.Summary(by("Heroic Strike")) == "Use Heroic Strike when you are fighting something and rage is 30 or more. It is switched on once and left on."
    assert E.Summary(by("Overpower")).endswith("It answers a dodge, block or parry: it comes up when the game lights it.")
    assert E.Summary(lua.eval('{ spell = { 78, "Heroic Strike" }, off = true }')) == "Use Heroic Strike whenever it can be used. Switched off for now."
    # Every class's every rule can be said, in words only.
    for cls in KITS:
        other = hero(cls)
        for rule in other.ns.Edit.Current().values():
            said = other.ns.Edit.Summary(rule)
            assert said.startswith("Use ") and not re.search(r"[<>]=?|\bdebuff\b|\bbuff\b|\bnot not\b|%%", said), (cls, said)

    # Ready-made conditions: added to what the ability asks already, without saying anything twice.
    names = [E.PresetName(i) for i in range(1, len(E.PRESETS) + 1)]
    assert len(names) >= 15 and len(set(names)) == len(names) and "Only with rage to spare (30 or more)" in names
    index = lambda name: names.index(name) + 1
    order = [game.ns.SpellName(r.spell) for r in E.Current().values()]
    rend = order.index("Rend") + 1
    was = E.Summary(E.Current()[rend])
    assert E.Change(rend, E.AddPreset, index("In a fight")) is None and E.Summary(E.Current()[rend]) == was, "it asks that already"
    assert E.Change(rend, E.AddPreset, index("Two or more enemies in reach")) is None
    assert E.Summary(E.Current()[rend]) == was[:-1].replace(" and the target's", ", the target's") + " and 2 or more enemies are in reach."
    assert E.Current()[rend].mine is True and E.Undo() and E.Undo() and not game.ns.Engine.custom
    # On an ability with no condition, or one that is not a list of ALLs, and one that starts again.
    bare = lua.eval('{ spell = { 7386, "Sunder Armor" } }')
    E.AddPreset(bare, index("Stack it to five and keep it from dropping"))
    assert E.Summary(bare) == "Use Sunder Armor when you have a target and either it is stacked fewer than 5 times or it has under 4.5 seconds left."
    E.AddPreset(bare, index("In a fight"))
    assert E.Summary(bare).startswith("Use Sunder Armor when you are fighting something and either")
    either = lua.eval('{ spell = { 772, "Rend" }, when = { "or", { "elite" }, { "moving" } } }')
    E.AddPreset(either, index("Keep it on the target"))
    assert E.Summary(either) == "Use Rend when you have a target, it is not on the target and either the target is elite or you are moving."
    E.AddPreset(either, index("Start again: whenever there is a target"))
    assert E.Summary(either) == "Use Rend when you have a target."
    # Whatever is picked, on whatever ability, what comes out is a condition the engine takes.
    for i in range(1, len(names) + 1):
        for start in ("nil", '{ "target" }', '{ "or", { "elite" }, { "moving" } }', '{ "and", { "and", { "target" }, { "combat" } }, { "power>=", 30 } }'):
            rule = lua.eval('{ spell = { 772, "Rend" }, when = %s }' % start)
            E.AddPreset(rule, i)
            E.AddPreset(rule, i)
            assert game.ns.Rules.Lint(rule.when) is None and isinstance(E.Summary(rule), str), (names[i - 1], start)
            once = E.Summary(rule)
            E.AddPreset(rule, i)
            assert E.Summary(rule) == once, "picking one twice changes nothing"

    # In the window: the summary over the tests, and the menu, on the stand-in's frames.
    game.g.SlashCmdList.POLESTARNEXT("edit")
    E.Refresh()
    assert any(isinstance(f.text, str) and f.text.startswith("Use Battle Shout when you do not have it.") for f in all_frames(game)), "the first ability's summary is shown"
    E.OpenPresets()
    # (A Lua table's own "items" has to be asked for by key: lupa keeps the attribute for itself.)
    menu = next(f for f in game.g.FRAMES.values() if lua_type(f["items"]) == "table" and len(f["items"]) == len(names))
    assert [item.text.text for item in menu["items"].values()] == names
    pick = menu["items"][index("Two or more enemies in reach")]
    pick.scripts.OnClick(pick)
    assert "2 or more enemies are in reach" in E.Summary(E.Current()[1]) and game.ns.Engine.custom
    print("ok  plain words: every rule summed up in a sentence; ready-made conditions added without repeating what is asked")


def all_frames(game):
    """Every frame the add-on made, and every text and texture made on one."""
    return list(game.g.FRAMES.values()) + list(game.g.REGIONS.values())


def notation(value):
    """A value in the share string's notation, written here independently of the add-on."""
    if value is None:
        return "Z"
    if value is True:
        return "T"
    if value is False:
        return "F"
    if isinstance(value, (int, float)):
        return f"N{value};"
    if isinstance(value, str):
        return f"S{len(value.encode())}:{value}"
    return "[" + "".join(notation(v) for v in value) + "]"


def share_string(root, raw=None, version=1):
    """A share string holding `root` (or the raw notation `raw`), with a correct check."""
    payload = base64.urlsafe_b64encode((raw if raw is not None else notation(root)).encode()).decode().rstrip("=")
    a = b = 0
    for byte in payload.encode():
        a = (a + byte) % 255
        b = (b + a) % 255
    return f"PNR{version}:{payload}:{a:02x}{b:02x}"


def check_share():
    """A rotation goes out as a string and comes back the same; anything else is turned away, and nothing in a string can run."""
    # Every class's rotation, every tree, and each warrior stance: out, into a fresh character, and out again unchanged.
    trips = 0
    for cls in list(Game("WARRIOR", 1).ns.Classes.ORDER.values()):
        for spec in (0, 1, 2, 3):
            for stance in ((0, 1, 2, 3) if cls == "WARRIOR" else (0,)):
                sender = Game(cls, 60).wear(16, *TWO_HANDER)
                sender.learn(*NAMED.keys(), *sorted(NAME_ONLY)).talents([30 if i == spec - 1 else 0 for i in range(3)])
                sender.g.W.stance = stance
                sender.rebuild()
                text = sender.ns.Edit.Export()
                assert text.startswith("PNR1:") and re.fullmatch(r"[\w:-]+", text), text[:40]
                taker = Game(cls, 60)
                taker.rebuild()
                ok, message = taker.ns.Edit.Import(text)
                assert ok is True, (cls, spec, stance, message)
                key = f"{cls}:{spec}:{stance}"
                assert taker.ns.db.lists[key] is not None and taker.ns.db.edited[key] is True
                taker.ns.Edit.Pick(spec, stance)
                assert taker.ns.Edit.Export() == text, (cls, spec, stance)
                trips += 1
    assert trips == 9 * 4 + 3 * 4

    # Taking one in: it becomes the rotation it was made for, the one in use is left alone until
    # the character is there, and what it replaced can be brought back.
    sender = fighter((7386, 772, 78, 2687, 71), (0, 0, 11), stance=2, level=30)
    assert sender.ns.Edit.Move(1, 3) is None  # the sender's own order
    text = sender.ns.Edit.Export()
    mine = fighter((7386, 772, 78, 2687, 71), (31, 0, 0), stance=1, level=30)
    assert mine.ns.Edit.AddRule("rend") is None  # a version of my own for Arms, Battle Stance
    ok, message = mine.ns.Edit.Import(text)
    assert ok and "Protection, Defensive Stance" in message and "kept" not in message, message
    assert mine.ns.Edit.Key() == "WARRIOR:3:2" and mine.ns.Engine.key == "WARRIOR:1:1"
    assert mine.ns.db.lists["WARRIOR:1:1"] is not None, "my own Arms rotation is untouched"
    shown = [mine.ns.SpellName(r.spell) for r in mine.ns.Edit.Current().values()]
    assert shown == [sender.ns.SpellName(r.spell) for r in sender.ns.Edit.Current().values()]
    mine.talents((0, 0, 11))
    mine.g.W.stance = 2
    mine.rebuild()
    assert mine.ns.Engine.custom and mine.ns.Engine.key == "WARRIOR:3:2"
    # "Into the one shown": the same string as my Arms rotation instead, and Restore undoes that.
    mine.ns.Edit.Pick(1, 1)
    before = mine.ns.Edit.Export()
    ok, message = mine.ns.Edit.Import(text, True)
    assert ok and "Arms, Battle Stance" in message and "kept" in message and mine.ns.Edit.Export() != before
    assert mine.ns.Edit.Restore() is True and mine.ns.Edit.Export() == before and mine.ns.Edit.Restore() is False

    # Pasted with line breaks and spaces in it, as mail and chat programs leave it: still read.
    broken = "\n".join(text[i:i + 60] for i in range(0, len(text), 60)) + "  \n"
    assert mine.ns.Edit.Decode(broken) is not None

    # Turned away, each with a reason, and nothing kept or changed.
    probe = fighter((772,), (0, 0, 0), stance=0)
    decode = probe.ns.Edit.Decode

    def refused(string, word):
        result = decode(string)
        assert isinstance(result, tuple) and result[0] is None and word in result[1], (string[:50], result)
        assert probe.ns.Edit.Import(string)[0] is False

    refused("hello there", "not a Polestar Next rotation")
    refused("", "not a Polestar Next rotation")
    refused(text[:-9], "not a Polestar Next rotation")                       # the end missing
    refused(text[:200] + text[260:], "damaged or cut short")                 # a piece missing from the middle
    flipped = text[:300] + ("A" if text[300] != "A" else "B") + text[301:]
    refused(flipped, "damaged or cut short")                                 # one character wrong
    refused(share_string([1, "WARRIOR", 0, 0, "x", [[78, "Heroic Strike", None, None, 0]]], version=2), "newer version")
    refused("PNR1:" + "A" * 70000 + ":0000", "far too long")
    rogue = Game("ROGUE", 30)
    rogue.learn(1752).rebuild()
    assert probe.ns.Edit.Import(rogue.ns.Edit.Export()) == (False, "that rotation is for a rogue; this character is a warrior")

    good = [78, "Heroic Strike", ["and", ["target"], ["power>=", 30]], "spare rage", 1]
    assert decode(share_string([1, "WARRIOR", 3, 2, "Mine", [good]])) is not None, "the independent writer and the add-on agree"
    hostile = {
        "nested past any rotation": share_string(None, raw="[" * 40 + "]" * 40),
        "more values than any rotation": share_string(None, raw="[" + "N1;" * 7000 + "]"),
        "a length that lies": share_string(None, raw="[N1;S7:WARRIORN0;N0;S999:x]"),
        "a negative length": share_string(None, raw="[N1;S-4:WARR]"),
        "a number that is not one": share_string(None, raw="[Nnan;S7:WARRIORN0;N0;Z[]]"),
        "a number too big to be one": share_string([1, "WARRIOR", 1e999, 0, "x", [good]]),
        "a class there is not": share_string([1, "DEATHKNIGHT", 0, 0, "x", [good]]),
        "a tree there is not": share_string([1, "WARRIOR", 9, 0, "x", [good]]),
        "no abilities": share_string([1, "WARRIOR", 0, 0, "x", []]),
        "too many abilities": share_string([1, "WARRIOR", 0, 0, "x", [good] * 81]),
        "a test there is not": share_string([1, "WARRIOR", 0, 0, "x", [[78, "Heroic Strike", ["os.execute", 1], None, 0]]]),
        "a condition that is not one": share_string([1, "WARRIOR", 0, 0, "x", [[78, "Heroic Strike", [42, "target"], None, 0]]]),
        "text where a number goes": share_string([1, "WARRIOR", 0, 0, "x", [[78, "Heroic Strike", ["power>=", "print('x')"], None, 0]]]),
        "an ability with no spell": share_string([1, "WARRIOR", 0, 0, "x", [[None, None, None, None, 0]]]),
        "a spell number that is not one": share_string([1, "WARRIOR", 0, 0, "x", [[-5.5, "X", None, None, 0]]]),
        "the wrong shape": share_string([1, "WARRIOR", 0, 0, "x"]),
        "something after the end": share_string(None, raw=notation([1, "WARRIOR", 0, 0, "x", [good]]) + "N1;"),
        "not the notation at all": share_string(None, raw="return os.execute('calc')"),
    }
    for what, string in hostile.items():
        result = decode(string)
        assert isinstance(result, tuple) and result[0] is None and isinstance(result[1], str), (what, result)
        assert probe.ns.Edit.Import(string)[0] is False, what
    assert probe.ns.db.lists is None or len(list(probe.ns.db.lists.keys())) == 0, "nothing was kept"

    # Words in a string are only ever shown: the game's mark-up and control characters are taken out.
    marked = decode(share_string([1, "WARRIOR", 0, 0, "|cffff0000Red|r\ttitle", [[None, "|TInterface\\Icons\\x:64|tNot a spell", ["target"], "|Hlink|hclick|h", 6]]]))
    assert marked.title == "cffff0000Redrtitle" and "|" not in marked.rules[1].spell[2] and "|" not in marked.rules[1].note
    assert marked.rules[1].react is True and marked.rules[1].off is True and marked.rules[1].toggle is None

    # The box in the editor opens for both, on the stand-in's frames.
    probe.g.SlashCmdList.POLESTARNEXT("share")
    probe.g.SlashCmdList.POLESTARNEXT("import")
    print(f"ok  share strings: {trips} rotations out and back unchanged; damaged, foreign and hostile strings turned away")


def check_panel_menu():
    """A click on the panel opens its menu; the panel lets the mouse through only while invisible."""
    game = warrior()
    W, db = game.g.W, game.ns.db
    panel = game.display
    mouse = []
    panel.EnableMouse = lambda _self, on: mouse.append(bool(on))

    def play(seconds=0.3):
        for _ in range(int(seconds / 0.11) + 1):
            panel.scripts.OnUpdate(panel, 0.11)

    # Unlocked: always there to be clicked and dragged.
    play()
    assert mouse[-1] is True
    # Locked with nothing to suggest: invisible, and out of the mouse's way.
    db.locked = True
    W.usable[6673] = False
    play()
    assert panel.alpha == 0 and mouse[-1] is False
    # Something to suggest: visible, and clickable even though locked.
    W.usable[6673] = None
    play()
    assert panel.alpha == 1 and mouse[-1] is True

    # A click opens the menu without a fault; the end of a drag does not count as one.
    panel.scripts.OnMouseUp(panel, "RightButton")
    panel.scripts.OnMouseUp(panel, "LeftButton")
    db.locked = False
    panel.scripts.OnDragStart(panel)
    panel.scripts.OnMouseUp(panel, "LeftButton")
    panel.scripts.OnDragStop(panel)
    panel.scripts.OnMouseUp(panel, "LeftButton")

    # What the menu offers, and that each entry does what it says.
    menu = {entry.say(): entry for entry in game.ns.PanelMenu.values()}
    assert list(menu) == ["Edit the rotations...", "Options...", "Print this rotation in chat", "Lock in place", "Coming up: 4 shown (click for more)",
                          "Show the icons only", "The game's own pick: when mine has nothing", "Stop glowing the button on my bars",
                          "Hide the panel, keep the glow", "Bigger", "Smaller",
                          "Back to the middle of the screen", "Hide (type /pnext to bring it back)"], list(menu)
    menu["Coming up: 4 shown (click for more)"].run()
    assert db.coming == 5 and menu["Coming up: 4 shown (click for more)"].say() == "Coming up: 5 shown (click for more)"
    menu["Lock in place"].run()
    assert db.locked is True and [e.say() for e in game.ns.PanelMenu.values()][3] == "Unlock, so it can be dragged"
    menu["Show the icons only"].run()
    assert db.compact is True
    pick = menu["The game's own pick: when mine has nothing"]
    pick.run()
    assert db.assist == "always" and pick.say() == "The game's own pick: always shown first"
    pick.run()
    assert db.assist == "off" and pick.say() == "The game's own pick: not shown"
    menu["Bigger"].run()
    menu["Bigger"].run()
    menu["Smaller"].run()
    assert abs(db.scale - 1.1) < 1e-9 and menu["Bigger"].stay and not menu["Lock in place"].stay
    db.point = game.lua.table("TOP", "TOP", 5, -5)
    menu["Back to the middle of the screen"].run()
    assert db.point is None
    menu["Print this rotation in chat"].run()
    assert any("WARRIOR, level 14" in line for line in game.g.SAID.values())
    menu["Edit the rotations..."].run()
    menu["Options..."].run()
    menu["Hide (type /pnext to bring it back)"].run()
    assert db.shown is False
    print("ok  panel menu: a click opens it, every entry does what it says, and an invisible panel takes no clicks")


def check_options():
    """The wait for the next press drawn over the big icon, and the options window."""
    game = fighter((7386, 772, 78, 2687, 71), (0, 0, 6), stance=2, level=15)
    W, db, ns = game.g.W, game.ns.db, game.ns
    panel = game.display

    def play(seconds=0.3):
        for _ in range(int(seconds / 0.11) + 1):
            panel.scripts.OnUpdate(panel, 0.11)

    def big():
        panel.scripts.OnUpdate(panel, 0.001)  # one frame: the icons are drawn every frame
        return next(t for t in ns.Strip.tiles.values() if t.place == 1 and not t.leaving)

    # The global cooldown: a shade over the big icon, as tall as there is left to wait.
    play()
    tall = 54 - 2
    assert big().wipe.up is False, "nothing to wait for"
    W.cooldowns[61304] = game.lua.table(W.time - 0.5, 1.5)
    assert big().wipe.up is True and abs(big().wipe.height - tall * 1.0 / 1.5) < 0.01
    assert all(t.wipe.up is False for t in ns.Strip.tiles.values() if t.place != 1), "only on the big one"
    W.time += 0.75
    assert abs(big().wipe.height - tall * 0.25 / 1.5) < 0.01
    W.time += 0.5
    assert big().wipe.up is False
    # A cast in progress is the same kind of wait, by its own length.
    W.casting = game.lua.table(W.time - 1, W.time + 2)
    assert big().wipe.up is True and abs(big().wipe.height - tall * 2 / 3) < 0.01
    assert ns.Rules.Busy() == (2, 3)
    game.g.SlashCmdList.POLESTARNEXT("gcd")
    assert db.gcd is False and big().wipe.up is False
    game.g.SlashCmdList.POLESTARNEXT("gcd")
    assert db.gcd is True and big().wipe.up is True
    W.casting = None

    # The options, as data: every row has what its kind needs.
    rows = list(ns.Options.items())
    said = lambda: [o.say() for _, o in rows]
    use = ns.UseOption
    find = lambda start: next(i for i, o in rows if o.say().startswith(start))
    assert [o.say() for _, o in rows if o.kind == "header"] == ["The panel", "On my bars", "The game's own pick", "Rotations"]
    for i, o in rows:
        assert o.kind in ("header", "check", "step", "cycle", "action") and isinstance(o.say(), str)
        assert (o.kind != "check" or (o.get is not None and o.set is not None)) and (o.kind != "step" or o.step is not None)
    # Each switch goes over and comes back.
    for i, o in rows:
        if o.kind == "check":
            before = o.get()
            use(i)
            assert o.get() is (not before), o.say()
            use(i)
            assert o.get() is before, o.say()
    assert "Show what is being kept track of (effects, rage)" in said()
    # The numbers step and stop at their ends.
    size = find("Size:")
    use(size, 1)
    assert abs(db.scale - 1.1) < 1e-9 and said()[size - 1] == "Size: 110%"
    for _ in range(12):
        use(size, -1)
    assert db.scale == 0.5 and said()[size - 1] == "Size: 50%"
    for _ in range(40):
        use(size, 1)
    assert db.scale == 3
    see = find("Opacity:")
    use(see, 1)
    assert db.alpha == 1
    for _ in range(12):
        use(see, -1)
    assert abs(db.alpha - 0.3) < 1e-9 and said()[see - 1] == "Opacity: 30%"
    play()
    assert abs(panel.alpha - 0.3) < 1e-9, "the panel is as see-through as it was set"
    for _ in range(12):
        use(see, 1)
    play()
    assert panel.alpha == 1
    coming = find("Coming up:")
    use(coming, 1)
    assert db.coming == 5
    for _ in range(9):
        use(coming, -1)
    assert db.coming == 0 and said()[coming - 1] == "Coming up: 0 shown"
    for _ in range(9):
        use(coming, 1)
    assert db.coming == 6
    # The choice that goes round, and the buttons.
    pick = find("Shown when my rotation has nothing")
    use(pick)
    assert db.assist == "always" and said()[pick - 1] == "Always shown first"
    use(pick)
    use(pick)
    assert db.assist == "fallback"
    db.point = game.lua.table("TOP", "TOP", 5, -5)
    use(find("Put it back"))
    assert db.point is None
    use(find("Print this rotation"))
    assert any("WARRIOR, level 15" in line for line in game.g.SAID.values())
    use(find("Edit the rotations"))

    # What the switches do to the panel.
    play()
    assert "rage" in ns.Strip.tracker.text
    use(find("Show what is being kept track of"))
    play()
    assert db.tracking is False and ns.Strip.tracker.text == ""
    use(find("Show what is being kept track of"))
    use(find("Only the glow"))
    assert db.hidePanel is True and db.glow is True
    play()
    assert panel.alpha == 0
    use(find("Only the glow"))
    play()
    assert db.hidePanel is None and panel.alpha == 1

    # The window: it opens from /pnext options, and its rows are the same switches.
    game.g.SlashCmdList.POLESTARNEXT("options")
    window = next(f for f in game.g.FRAMES.values() if lua_type(f.rows) == "table" and len(f.rows) == len(rows))
    assert [row.text.text for row in window.rows.values()] == said()
    lock = find("Lock it in place")
    window.rows[lock].scripts.OnClick(window.rows[lock])
    assert db.locked is True
    window.rows[lock].scripts.OnClick(window.rows[lock])
    assert db.locked is False
    window.rows[coming].less.scripts.OnClick(window.rows[coming].less)
    assert db.coming == 5 and window.rows[coming].text.text == "Coming up: 5 shown"
    window.rows[pick].press.scripts.OnClick(window.rows[pick].press)
    assert db.assist == "always" and window.rows[pick].press.text == "Always shown first"
    print("ok  options: the wait for the next press on the big icon, and every setting in one window")


def check_glow():
    """The suggested ability's own button glows on the bars, in the colour of what is holding it up."""
    game = warrior()  # Attack 1, Heroic Strike 2, Rend 3, Charge 4, Battle Shout 5
    W, glow, panel = game.g.W, game.ns.Glow, game.display

    def play(seconds=0.3):
        game.ns.Rules.Recount()
        for _ in range(int(seconds / 0.11) + 1):
            panel.scripts.OnUpdate(panel, 0.11)

    play()
    assert glow.button.name == "ActionButton5" and glow.kind == "now", "Battle Shout, on button five"
    W.auras.player["Battle Shout"] = True
    game.g.target(game.lua.table(**MOB))
    W.range[100] = True
    play()
    assert glow.button.name == "ActionButton4"
    # In a fight, out of reach of everything: the button to head for glows red.
    W.combat, W.range[100], W.range[6603], W.range[772] = True, False, False, False
    play()
    assert glow.button.name == "ActionButton1" and glow.kind == "range"
    # In reach, Rend next but not the rage for it: blue.
    W.range[6603], W.range[772], W.current[6603] = True, None, True
    W.shortOf[772] = True
    play()
    assert glow.button.name == "ActionButton3" and glow.kind == "power"
    W.shortOf[772] = None
    play()
    assert glow.button.name == "ActionButton3" and glow.kind == "now"

    # Nothing to suggest, a button on a hidden bar, the glow switched off: no glow.
    game.ns.Rules.SawCast(772)
    play()
    assert glow.button is None
    W.power = 60
    play()
    assert glow.button.name == "ActionButton2"
    game.g.ActionButton2.hidden = True
    play()
    assert glow.button is None
    game.g.ActionButton2.hidden = False
    slash = game.g.SlashCmdList.POLESTARNEXT
    slash("glow")
    play()
    assert glow.button is None and game.ns.db.glow is False
    slash("glow")
    play()
    assert glow.button.name == "ActionButton2"

    # The panel put away, the glow stays; /pnext panel brings it back; off stops both.
    menu = {entry.say(): entry for entry in game.ns.PanelMenu.values()}
    menu["Hide the panel, keep the glow"].run()
    play()
    assert panel.alpha == 0 and glow.button.name == "ActionButton2"
    slash("panel")
    play()
    assert panel.alpha == 1
    slash("")
    assert glow.button is None and game.ns.db.shown is False
    print("ok  glow: the suggested ability's own button is marked on the bars, gold now, red for range, blue for rage")


WARRIOR_FACTS = {
    772: dict(desc="Wounds the target causing them to bleed for 25 damage over 12 sec.", cost=10),
    7386: dict(desc="Sunders the target's armor, reducing it by 90. Can be applied up to 5 times. Lasts 30 sec.", cost=15),
    6572: dict(desc="Instantly counterattack an enemy for 20 to 24 damage.", cost=5, cd=5000),
    78: dict(desc="A strong attack that increases melee damage by 44 and causes a high amount of threat.", cost=15),
    12294: dict(desc="A vicious strike that deals weapon damage plus 85 and wounds the target.", cost=30, cd=6000),
    1680: dict(desc="In a whirlwind of steel you attack up to 4 enemies within 8 yards, causing weapon damage to each enemy.", cost=25, cd=10000),
}


def fighter(spells, points, stance, power=100, level=40, **talents):
    """A warrior in a fight, attacking, with the game's real figures for the spells above."""
    game = Game("WARRIOR", level).wear(16, *TWO_HANDER)
    for spell_id, facts in WARRIOR_FACTS.items():
        game.spell(spell_id, **facts)
    game.learn(6603, *spells).talents(points, **talents)
    W = game.g.W
    W.stance, W.combat, W.power = stance, True, power
    W.current[6603] = True
    game.g.target(game.lua.table(**MOB))
    game.rebuild()
    return game


def check_plan():
    """The next presses laid out in time: effects renewed before they drop, strikes where their
    cooldowns end, rage counted, and the gaps filled."""
    # Arms. Rend is on the target with four seconds left; Mortal Strike is ready.
    arms = fighter((12294, 772, 78), (31, 0, 0), stance=1, Improved_Rend=3)
    arms.effect("target", "Rend", left=4, lasts=12)
    assert arms.plan() == [
        ("Mortal Strike", 0, False),   # now
        ("Heroic Strike", 0, False),   # with it: no slot of its own, and the rage is there
        ("Rend", 3.0, True),           # in the last slot before it would drop, not after
        ("Mortal Strike", 6.0, True),  # the moment its cooldown ends
    ], arms.plan()
    # The same fight a moment later, the global cooldown half run: the plan starts when it ends.
    arms.g.W.cooldowns[61304] = arms.lua.table(99, 1.5)
    assert arms.plan(1) == [("Mortal Strike", 0.5, False)]

    # A tank. Sunder Armor is at five with seven seconds left, Rend has plenty: Whirlwind
    # goes in now, Sunder Armor is renewed with time to spare, Whirlwind again when it is back.
    tank = fighter((7386, 772, 78, 1680, 71), (0, 0, 31), stance=2)
    tank.effect("target", "Sunder Armor", left=7, lasts=30, stacks=5)
    tank.effect("target", "Rend", left=20, lasts=12)
    plan = tank.plan()
    assert plan == [("Whirlwind", 0, False), ("Heroic Strike", 0, False), ("Sunder Armor", 3.0, True), ("Whirlwind", 10.0, True)], plan
    assert plan[2][1] < 7, "renewed before it fades"
    # What it is going by is there to be seen: each effect's time and stacks, and the rage.
    tracked = {e.name: (round(e.left), e.stacks, e.sure) for e in tank.ns.Engine.Tracked().values()}
    assert tracked == {"Sunder Armor": (7, 5, True), "Rend": (20, None, True)}, tracked
    for _ in range(3):
        tank.display.scripts.OnUpdate(tank.display, 0.11)
    line = tank.ns.Strip.tracker.text
    assert "Sunder Armor x5" in line and "7s" in line and "Rend" in line and "20s" in line and "rage 100" in line, line
    # From nothing: Sunder Armor press after press to five, never a sixth, then the bleed.
    tank.g.W.auras.target["Sunder Armor"], tank.g.W.auras.target["Rend"] = None, None
    tank.g.W.cooldowns[1680] = tank.lua.table(99, 60)
    names = [name for name, _, _ in tank.plan(8) if name != "Heroic Strike"]
    assert names == ["Sunder Armor"] * 5 + ["Rend"], names

    # Rage is counted. Four a second is coming in, there are twelve, and Sunder Armor costs
    # fifteen: each one is placed where the rage for it will have arrived.
    poor = fighter((7386, 71), (0, 0, 31), stance=2, power=0)
    poor.plan()
    poor.g.W.time, poor.g.W.power = 104, 32
    poor.plan()
    assert poor.ns.Rules.rate == 4
    poor.g.W.power = 12
    poor.g.W.shortOf[7386] = True
    assert poor.plan(3) == [("Sunder Armor", 1.0, True), ("Sunder Armor", 4.5, True), ("Sunder Armor", 8.5, True)], poor.plan(3)
    # With the rage hidden by the game there is nothing to count: no guess is made.
    poor.g.W.secret = True
    assert poor.plan(3) == []

    # How long an effect lasts comes from the game when it shows one, else from the
    # spell's own description, not from the rotation's rough figure.
    seen = fighter((772,), (31, 0, 0), stance=1, Improved_Rend=3)
    seen.g.W.secret = True  # nothing visible: Rend's twelve seconds are read off its description
    seen.ns.Rules.SawCast(772)
    seen.g.W.time += 10.5
    assert seen.next() is None
    estimate = next(iter(seen.ns.Engine.Tracked().values()))
    assert estimate.name == "Rend" and round(estimate.left, 1) == 1.5 and estimate.sure is False
    seen.g.W.time += 1  # eleven and a half seconds in: half a second left, so it is due
    assert seen.next() == "Rend"
    print("ok  the plan: effects renewed in the last slot before they drop, cooldowns and rage counted, gaps filled")


def check_strip():
    """The row is the plan: what to press now, big, then the presses after it. Each one slides
    over and grows into the big one as its turn comes."""
    game = fighter((78, 772, 7386, 6572, 71), (0, 0, 11), stance=2, power=60, level=30)  # keys: Attack 1, Heroic Strike 2, Rend 3, Sunder Armor 4, Revenge 5
    W, strip, panel = game.g.W, game.ns.Strip, game.display

    def play(seconds):
        """Frames at fifty a second, the way the game would call it."""
        for _ in range(int(seconds / 0.02)):
            game.ns.Rules.Recount()
            panel.scripts.OnUpdate(panel, 0.02)

    def order():
        return list(strip.order.values())

    def near(value, wanted, slack=1.0):
        return abs(value - wanted) <= slack

    # Sixty rage: Revenge (it is lit), Heroic Strike with it, Sunder Armor twice, and Rend
    # with the ten that is left.
    play(1.5)
    assert order() == ["Revenge", "Heroic Strike", "Sunder Armor", "Sunder Armor", "Rend"], order()
    hero, third, fourth = strip.tiles["Revenge"], strip.tiles["Sunder Armor"], strip.tiles["Sunder Armor#2"]
    assert near(hero.size, 54) and near(hero.x, 0) and near(hero.alpha, 1, 0.05), "the one to use now: big, at the left"
    assert near(strip.tiles["Heroic Strike"].x, 64) and near(third.size, 32) and near(third.x, 100) and near(fourth.x, 136)
    assert hero.key.text == "5" and third.key.text == "4"
    third.mark = "the first Sunder Armor"

    # Revenge is used. The first Sunder Armor's own tile is the one that becomes the big one...
    W.usable[6572], W.power = False, 55
    play(0.12)
    assert order() == ["Sunder Armor", "Heroic Strike", "Sunder Armor", "Rend"], order()
    assert strip.tiles["Sunder Armor"].mark == "the first Sunder Armor" and third.tsize == 54 and third.tx == 0
    # ...and it is on its way: part grown, part way across, not there yet.
    assert 32 < third.size < 54 and 0 < third.x < 100, (third.size, third.x)
    # The one just used is swelling and fading; the one behind is shuffling up.
    assert hero.leaving and hero.tsize > 54 and hero.alpha < 1 and 100 < fourth.x < 136
    play(1.5)
    assert near(third.size, 54) and near(third.x, 0) and near(fourth.x, 100)
    assert strip.tiles["Revenge"] is None, "the faded tile is put away"

    # A press the plan had to leave a gap for carries its seconds, and sits back in the row.
    W.power = 100
    game.effect("target", "Sunder Armor", left=25, lasts=30, stacks=5)
    game.effect("target", "Rend", left=4, lasts=12)
    play(0.5)
    assert order() == ["Heroic Strike", "Rend"], order()
    assert strip.tiles["Rend"].count.text == "3" and strip.tiles["Rend"].talpha < 1

    # When the only thing to come is still seconds off, it is shown dimmed, and no button glows for it.
    # (Twenty seconds on, so the rage that arrived a moment ago no longer counts as income.)
    W.time += 20
    game.effect("target", "Sunder Armor", left=25, lasts=30, stacks=5)
    game.effect("target", "Rend", left=4, lasts=12)
    W.power = 20
    play(0.5)
    assert order() == ["Rend"] and game.ns.Glow.button is None and game.next() is None

    # How many are shown is the player's to choose: none, or more.
    W.power = 100
    W.auras.target["Sunder Armor"], W.auras.target["Rend"] = None, None
    game.g.SlashCmdList.POLESTARNEXT("next 0")
    play(0.3)
    assert order() == ["Sunder Armor"]
    game.g.SlashCmdList.POLESTARNEXT("next 2")
    play(0.3)
    assert order() == ["Sunder Armor", "Heroic Strike", "Sunder Armor"] and game.ns.db.coming == 2, order()
    print("ok  the row: the plan in order, each tile sliding and growing into the big one, gaps counted in seconds")


def check_only_shows():
    """The add-on must not be able to act: no call that casts, targets, moves or runs a macro."""
    banned = ["CastSpell", "UseAction", "RunMacro", "TargetUnit", "TargetNearest", "AttackTarget", "MoveForward", "TurnLeft", "JumpOrAscend",
              "SecureActionButton", "SetOverrideBinding", "RunBinding", "StartAttack", "SpellStopCasting", "InteractUnit", "SendChatMessage",
              "SendAddonMessage"]
    for name in FILES:
        source = (ADDON / name).read_text(encoding="utf-8")
        for word in banned:
            # A call or mention of the function itself, by its own name: C_AssistedCombat's
            # GetNextCastSpell, which only reads the game's pick, is not CastSpell.
            assert not re.search(r"(?<![A-Za-z_])" + re.escape(word), source), f"{name} mentions {word}"
    print("ok  nothing in the add-on casts, targets, moves, binds or sends")


if __name__ == "__main__":
    check_rules(warrior())
    check_warrior()
    check_gear_and_talents()
    check_numbers()
    check_secret_values()
    check_every_class()
    check_own_list_and_commands()
    check_stances()
    check_what_the_game_hides()
    check_enemies_around()
    check_tree_points()
    check_realtime()
    check_editor()
    check_editor_essentials()
    check_update()
    check_preview()
    check_class_plans()
    check_forever()
    check_plain_words()
    check_share()
    check_panel_menu()
    check_options()
    check_glow()
    check_plan()
    check_strip()
    check_only_shows()
