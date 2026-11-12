-- Polestar Next: which ability to use next, shown inside the game.
--
-- It reads the character through the add-on API (class, level, spellbook,
-- talents, gear, action bars, key bindings), builds a priority list for the
-- class from them, and shows the first ability on the list that can be used
-- now, with its key. That is all it does: nothing here casts, targets, moves
-- or presses anything, and nothing about the suggestion leaves the game.
--
--   Core.lua     reading values safely, spell names
--   Scan.lua     what the character has: spells, bars and keys, talents, gear
--   Rules.lua    the tests a rule can ask, and AND / OR / NOT over them
--   Numbers.lua  each spell's cost, cooldown and damage, and the order they give
--   Classes.lua  each class's priority list, built from the scan
--   Engine.lua   scan -> list -> the suggestion for this moment
--   Edit.lua     /pnext edit: reorder the list and edit the conditions
--   Display.lua  the icon, the key, the slash command

local ADDON, ns = ...
ns.ADDON = ADDON

---------------------------------------------------------------------------
-- Reading values safely. Forever can hand back secret values that throw when
-- compared or used in arithmetic, so everything read from the game goes
-- through these, and a secret reads as "unknown" (nil).
---------------------------------------------------------------------------

local function secret(v)
	return v ~= nil and issecretvalue ~= nil and issecretvalue(v) and true or false
end
ns.secret = secret

function ns.plain(v)
	if secret(v) then return nil end
	return v
end
local plain = ns.plain

function ns.num(v)
	v = plain(v)
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
	return v
end

function ns.str(v)
	v = plain(v)
	if type(v) == "string" and v ~= "" then return v end
	return nil
end

local function keep(ok, ...)
	if ok then return ... end
	return nil
end

-- fn(...) or nothing, when fn is missing or throws.
function ns.call(fn, ...)
	if type(fn) ~= "function" then return nil end
	return keep(pcall(fn, ...))
end
local call = ns.call

function ns.field(t, k)
	t = plain(t)
	if type(t) ~= "table" then return nil end
	return plain(t[k])
end

-- A yes/no question to the game with three answers: true, false, or nil
-- when the function is missing, throws, or keeps its answer secret.
function ns.tri(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if not ok or secret(v) then return nil end
	return v and true or false
end

-- A function from a namespace table (C_Spell.GetSpellName) or, failing
-- that, the old global of the same name.
function ns.fn(space, name)
	local t = _G[space]
	local f = type(t) == "table" and t[name] or nil
	if type(f) ~= "function" then f = _G[name] end
	return type(f) == "function" and f or nil
end

ns.wipe = wipe or function(t)
	for k in pairs(t) do t[k] = nil end
	return t
end

---------------------------------------------------------------------------
-- Spell names. Rules name a spell by its first rank's ID (the same in every
-- language) with its English name as a fallback for spells whose ID this
-- client does not have; everything is matched by the name the client gives.
---------------------------------------------------------------------------

local names = {}

function ns.SpellNameOf(id)
	if type(id) ~= "number" then return nil end
	local cached = names[id]
	if cached ~= nil then return cached or nil end
	local name = ns.str((call(ns.fn("C_Spell", "GetSpellName"), id)))
	if not name then
		local info = C_Spell and call(C_Spell.GetSpellInfo, id)
		name = ns.str(ns.field(info, "name"))
	end
	if not name then name = ns.str((call(GetSpellInfo, id))) end
	names[id] = name or false
	return name
end

-- A rule's spell reference is { id, english } (either may be nil).
function ns.SpellName(ref)
	if type(ref) == "number" then return ns.SpellNameOf(ref) end
	if type(ref) == "string" then return ref end
	if type(ref) ~= "table" then return nil end
	return (ref[1] and ns.SpellNameOf(ref[1])) or ref[2]
end

function ns.say(text)
	print("|cff7fb8ffPolestar Next|r: " .. text)
end

---------------------------------------------------------------------------
-- The look the icon and the editor share: dark panels with a hairline edge,
-- gold for what matters now.
---------------------------------------------------------------------------

local UI = { GOLD = { 1, 0.82, 0 }, RED = { 1, 0.42, 0.35 }, GREEN = { 0.45, 0.85, 0.5 }, UNKNOWN_ICON = 134400 }
ns.UI = UI

-- A hairline edge round `frame`; the returned function recolours it.
function UI.Edge(frame, r, g, b, a)
	local edges = {}
	for i, at in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
		local edge = frame:CreateTexture(nil, "BORDER")
		edge:SetPoint(at[1])
		edge:SetPoint(at[2])
		if i <= 2 then edge:SetHeight(1) else edge:SetWidth(1) end
		edges[i] = edge
	end
	local function colour(cr, cg, cb, ca)
		for _, edge in ipairs(edges) do edge:SetColorTexture(cr, cg, cb, ca or 1) end
	end
	colour(r or 1, g or 1, b or 1, a or 0.14)
	return colour
end

-- A dark panel behind `frame`.
function UI.Panel(frame, alpha)
	local fill = frame:CreateTexture(nil, "BACKGROUND")
	fill:SetAllPoints()
	fill:SetColorTexture(0.04, 0.05, 0.07, alpha or 0.9)
	return fill, UI.Edge(frame)
end

-- Text at `size`, outlined when it sits over the game world.
function UI.Text(parent, size, outline)
	local text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	local font = text:GetFont()
	if font then text:SetFont(font, size, outline and "OUTLINE" or "") end
	text:SetJustifyH("LEFT")
	return text
end

-- A spell's icon, the question mark when the client has none.
function UI.Icon(id)
	local file = id and (ns.call(ns.fn("C_Spell", "GetSpellTexture"), id))
	return ns.plain(file) or UI.UNKNOWN_ICON
end
