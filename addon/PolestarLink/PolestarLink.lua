-- Polestar Link: paints Polestar's guide and arrow state as a thin strip of
-- coloured cells along the top edge of the game window, from its left corner
-- (750 x 6 pixels). The polestar-plus desktop program reads the strip from the
-- screen. Nothing here writes to Polestar or to the game: it calls Polestar's
-- getters and colours textures.
--
-- Wire format (kept in step with src/protocol.rs):
--   A grid of COLS x ROWS cells, each CELL physical pixels square, anchored at
--   the window's top-left pixel. A cell carries three bytes as its R, G, B.
--     cell 0   magic 0x50 0x4C 0x4B ("PLK")
--     cell 1   magic 0xFF 0x00 0xFF
--     cell 2   COLS, ROWS, VERSION
--     cell 3   sequence (counts every publish), payload length low, high
--     cell 4   Fletcher-16 of the payload (a, b), 0
--     cell 5.. payload, three bytes a cell, unused cells black
--   The payload is a run of fields: tag byte, length byte, that many bytes.
--   Numbers are written as text. Tags are listed where they are written below.

local ADDON = ...

local COLS, ROWS, CELL, VERSION = 250, 2, 3, 1
local CELLS = COLS * ROWS
local HEADER_CELLS = 5
local CAPACITY = (CELLS - HEADER_CELLS) * 3
local FAST, SLOW = 0.1, 1.0 -- seconds: arrow and position; step, goals and texts
local MAX_GOALS = 12

local byte, char, floor, min = string.byte, string.char, math.floor, math.min

---------------------------------------------------------------------------
-- Reading values safely. Forever can hand back secret values that throw when
-- compared or formatted, so everything read from the game goes through these.
---------------------------------------------------------------------------

local function plain(v)
	if v ~= nil and issecretvalue ~= nil and issecretvalue(v) then return nil end
	return v
end

local function num(v)
	v = plain(v)
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
	return v
end

local function str(v)
	v = plain(v)
	if type(v) == "string" and v ~= "" then return v end
	return nil
end

local function keep(ok, ...)
	if ok then return ... end
	return nil
end

local function call(fn, ...)
	if type(fn) ~= "function" then return nil end
	return keep(pcall(fn, ...))
end

local function field(t, k)
	t = plain(t)
	if type(t) ~= "table" then return nil end
	return plain(t[k])
end

-- At most n bytes of s, never cutting a UTF-8 character in half.
local function clip(s, n)
	if #s <= n then return s end
	local e = n
	while e > 0 do
		local b = byte(s, e + 1)
		if not b or b < 128 or b >= 192 then break end
		e = e - 1
	end
	return s:sub(1, e)
end

-- Text without the game's colour, texture and line-break codes.
local function clean(s)
	s = str(s)
	if not s then return nil end
	s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
	s = s:gsub("|r", "")
	s = s:gsub("|T.-|t", "")
	s = s:gsub("|A.-|a", "")
	s = s:gsub("|n", " ")
	s = s:gsub("%c+", " ")
	return s
end

local function chunk(tag, value, limit)
	if value == nil then return nil end
	if type(value) ~= "string" then value = tostring(value) end
	value = clip(value, min(limit or 255, 255))
	return tag .. char(#value) .. value
end

local function put(buf, tag, value, limit)
	local c = chunk(tag, value, limit)
	if c then buf[#buf + 1] = c end
end

local function fmt(pattern, ...)
	for i = 1, select("#", ...) do
		if select(i, ...) == nil then return nil end
	end
	return pattern:format(...)
end

---------------------------------------------------------------------------
-- What Polestar says
---------------------------------------------------------------------------

local function polestar()
	local P = plain(_G.Polestar)
	if type(P) ~= "table" then return nil end
	return P, field(P, "Engine"), field(P, "Nav"), field(P, "Compat")
end

-- Every Polestar function this file calls. One that is gone after a Polestar
-- update is named in the strip, so data that went missing is not mistaken for
-- Polestar having nothing to show.
local PARTS = { "Engine", "Nav", "Compat" }
local CALLS = {
	Engine = { "GetGuide", "GetStepIndex", "StepNumber", "StepTotal", "GetLiveStep", "GetProgress", "GetStepView" },
	Nav = { "Sample", "FloorHint", "GetTarget", "GetTargetWorld", "GetTargetZoneName", "GetRouteGeometry" },
	Compat = { "GetPlayerWorldPosition", "GetPlayerMapPosition", "GetQuestTitle" },
}

-- "Nav.Sample,Compat.GetQuestTitle", a whole part as just "Engine"; nil when
-- everything is there.
local function missing(P)
	local gone = {}
	for _, part in ipairs(PARTS) do
		local t = field(P, part)
		if type(t) ~= "table" then
			gone[#gone + 1] = part
		else
			for _, name in ipairs(CALLS[part]) do
				if type(field(t, name)) ~= "function" then gone[#gone + 1] = part .. "." .. name end
			end
		end
	end
	return #gone > 0 and table.concat(gone, ",") or nil
end

-- Ten times a second: where the arrow points and where the player stands.
--   S  arrow state (Polestar's Nav.Sample: travel, arrived, far, taxi, ...)
--   D  yards to what the arrow points at      M  "1" when D is along a path
--   A  radians from facing to the arrow, counter-clockwise positive
--   N  "dNorth,dWest" yards to what the arrow points at
--   f  "up" or "down" when the target is a floor away
--   F  facing in radians, 0 north, counter-clockwise positive
--   P  "continent,x,y" world position, x north, y west
--   Z  "uiMapID,x,y" map position in percent
local function buildFast()
	local buf = {}
	local _, _, N, C = polestar()
	if N then
		local state, dist, rel, dn, dw, measured = call(N.Sample)
		put(buf, "S", str(state))
		put(buf, "D", fmt("%.1f", num(dist)))
		put(buf, "A", fmt("%.4f", num(rel)))
		put(buf, "N", fmt("%.1f,%.1f", num(dn), num(dw)))
		if plain(measured) == true then put(buf, "M", "1") end
		put(buf, "f", str(call(N.FloorHint)))
	end
	put(buf, "F", fmt("%.4f", num(call(GetPlayerFacing))))
	if C then
		local pc, px, py = call(C.GetPlayerWorldPosition)
		put(buf, "P", fmt("%d,%.1f,%.1f", num(pc), num(px), num(py)))
		local map, x, y = call(C.GetPlayerMapPosition)
		put(buf, "Z", fmt("%d,%.2f,%.2f", num(map), num(x), num(y)))
	end
	return buf
end

-- Field w for goal view `gv`, goal `g`: the NPC it names and where its item
-- comes from (Polestar's `source`), or nil when it names neither.
local function who(g, gv)
	local npc = clean(field(gv, "npcName"))
	local source = plain(field(gv, "source"))
	local from, also, kind, enemy
	if type(source) == "table" then
		from, also, kind = clean(field(source, "name")), clean(field(source, "also")), str(field(source, "kind"))
		enemy = field(source, "enemy") == true
	end
	if not (npc or from) then return nil end
	return chunk("w", ("%d|%s|%s|%s|%s|%s"):format(g, npc or "", from or "", also or "", kind or "", enemy and "1" or "0"), 200)
end

-- The walking path Polestar draws on the map (Nav.GetRouteGeometry's current
-- leg), from the player's place on it onwards: fields r and p, or nothing
-- when the current leg is not a walk.
local MAX_ROUTE_POINTS = 120
local function route(buf, N, C)
	local legs = field(call(N.GetRouteGeometry), "legs")
	if type(legs) ~= "table" then return end
	local pts
	for _, leg in ipairs(legs) do
		leg = plain(leg)
		if type(leg) == "table" and field(leg, "current") == true then
			if field(leg, "kind") == "walk" then pts = field(leg, "pts") end
			break
		end
	end
	if type(pts) ~= "table" or #pts < 2 then return end
	local continent = num(field(pts[1], 1))
	if not continent then return end

	-- Start one point before the one nearest the player, so the stretch the
	-- player is on is always included.
	local first = 1
	local pc, px, py
	if C then pc, px, py = call(C.GetPlayerWorldPosition) end
	pc, px, py = num(pc), num(px), num(py)
	if pc == continent and px and py then
		local least
		for i = 1, #pts do
			local x, y = num(field(pts[i], 2)), num(field(pts[i], 3))
			if x and y then
				local d = (x - px) * (x - px) + (y - py) * (y - py)
				if not least or d < least then least, first = d, i end
			end
		end
		if first > 1 then first = first - 1 end
	end

	local x, y = num(field(pts[first], 2)), num(field(pts[first], 3))
	if not (x and y) then return end
	local qx, qy = floor(x + 0.5), floor(y + 0.5)
	local steps, n = {}, 0
	for i = first + 1, #pts do
		local tx, ty = num(field(pts[i], 2)), num(field(pts[i], 3))
		if num(field(pts[i], 1)) ~= continent or not (tx and ty) then break end
		tx, ty = floor(tx + 0.5), floor(ty + 0.5)
		-- A stretch longer than a byte holds goes out as several steps.
		while (tx ~= qx or ty ~= qy) and n < MAX_ROUTE_POINTS do
			local dx = math.max(-127, min(127, tx - qx))
			local dy = math.max(-127, min(127, ty - qy))
			qx, qy, n = qx + dx, qy + dy, n + 1
			steps[n] = char(dx + 128, dy + 128)
		end
		if n >= MAX_ROUTE_POINTS then break end
	end
	if n == 0 then return end
	put(buf, "r", ("%d,%d,%d"):format(continent, floor(x + 0.5), floor(y + 0.5)))
	buf[#buf + 1] = "p" .. char(n * 2) .. table.concat(steps)
end

-- Once a second, and at once when Polestar says the step changed.
--   E  "ok", "no-guide", "no-engine", "no-polestar" or "error: ..."
--   V  Polestar's version           X  Polestar functions that are gone (missing)
--   U  "name|level"                 z  "zone|subzone"
--   G  guide id                     g  guide title
--   R  "done,total" guide progress
--   I  "index,number,total,live" step: its index, the number the window shows,
--      how many steps the character sees, and the live step's index
--   H  step title                   n  step note
--   C  index of the goal the arrow leads to
--   Q  "questID|title" of that goal's quest
--   L  target label   K  target kind   W  target zone name
--   t  "uiMapID,x,y" target on its map   T  "continent,x,y,z" target in the world
--   O  one per goal: "index|type|status|questID|cur|max|text"
--   w  who or what the goal the arrow leads to needs:
--      "index|NPC|source|other source|source kind|enemy (1 or 0)"
--   r  "continent,north,west": where the walking path Polestar draws on the
--      map is picked up, in whole yards (the point before the player's place on it)
--   p  the path from there on, two bytes a point: yards north and yards west
--      of the point before, each plus 128
local function buildSlow()
	local buf = {}
	local P, E, N, C = polestar()

	local name, level = str(call(UnitName, "player")), num(call(UnitLevel, "player"))
	put(buf, "U", (name or "") .. "|" .. (level and tostring(level) or ""))
	local zone, sub = call(GetZoneText), call(GetSubZoneText)
	put(buf, "z", (str(zone) or "") .. "|" .. (str(sub) or ""))

	if not P then
		table.insert(buf, 1, chunk("E", "no-polestar"))
		return buf
	end
	put(buf, "V", str(field(P, "version")), 40)
	put(buf, "X", missing(P))
	if not E then
		table.insert(buf, 1, chunk("E", "no-engine"))
		return buf
	end

	if N then
		local target = plain(call(N.GetTarget))
		if type(target) == "table" then
			put(buf, "L", clean(field(target, "label")), 80)
			put(buf, "K", str(field(target, "kind")))
			put(buf, "t", fmt("%d,%.2f,%.2f", num(field(target, "map")), num(field(target, "x")), num(field(target, "y"))))
			put(buf, "W", clean(call(N.GetTargetZoneName)), 60)
			local tc, tx, ty, tz = call(N.GetTargetWorld)
			tc, tx, ty, tz = num(tc), num(tx), num(ty), num(tz)
			if tc and tx and ty then
				put(buf, "T", ("%d,%.1f,%.1f,%s"):format(tc, tx, ty, tz and ("%.1f"):format(tz) or ""))
			end
		end
	end

	local guide = plain(call(E.GetGuide))
	if type(guide) ~= "table" then
		table.insert(buf, 1, chunk("E", "no-guide"))
		return buf
	end
	table.insert(buf, 1, chunk("E", "ok"))
	put(buf, "G", str(field(guide, "id")), 120)
	put(buf, "g", clean(field(guide, "title")), 80)
	local done, total = call(E.GetProgress)
	put(buf, "R", fmt("%d,%d", num(done), num(total)))

	local index = num(call(E.GetStepIndex))
	if not index then return buf end
	local number, count, live = num((call(E.StepNumber, index))), num(call(E.StepTotal)), num(call(E.GetLiveStep))
	put(buf, "I", ("%d,%s,%s,%s"):format(index, number and tostring(number) or "", count and tostring(count) or "",
		live and tostring(live) or ""))

	local view = plain(call(E.GetStepView, index))
	if type(view) ~= "table" then return buf end
	put(buf, "H", clean(field(view, "title")), 100)
	local current = num(field(view, "current"))
	put(buf, "C", current and tostring(current) or nil)

	local goals, questID = plain(field(view, "goals")), nil
	local lines, needs = {}, nil
	if type(goals) == "table" then
		for g, gv in ipairs(goals) do
			gv = plain(gv)
			if type(gv) == "table" and not field(gv, "folded") then
				local status = str(field(gv, "status")) or ""
				local quest = num(field(gv, "quest"))
				if quest and (g == current or (not questID and not current and status == "active")) then questID = quest end
				if g == current then needs = who(g, gv) end
				if status ~= "na" and #lines < MAX_GOALS then
					local progress = field(gv, "progress")
					local cur, max = num(field(progress, "cur")), num(field(progress, "max"))
					lines[#lines + 1] = chunk("O", ("%d|%s|%s|%s|%s|%s|%s"):format(g, str(field(gv, "t")) or "", status,
						quest and tostring(quest) or "", cur and tostring(cur) or "", max and tostring(max) or "",
						clip(clean(field(gv, "text")) or "", 110)))
				end
			end
		end
	end
	if questID then
		local title = C and clean(call(C.GetQuestTitle, questID))
		if not title then
			local Names = field(P, "Names")
			title = clean(call(field(Names, "Quest"), questID))
		end
		put(buf, "Q", questID .. "|" .. (title or ""), 100)
	end
	if needs then buf[#buf + 1] = needs end
	-- Goals, then the path, then the note: when the strip runs out of room the
	-- note goes first.
	for _, line in ipairs(lines) do buf[#buf + 1] = line end
	if N then route(buf, N, C) end
	put(buf, "n", clean(field(view, "note")), 200)
	return buf
end

---------------------------------------------------------------------------
-- The strip
---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "PolestarLinkFrame")
local cells, shown = {}, {}
local seq, dirty = 0, true
local slowParts = {}
local db

-- One frame unit is one physical pixel: the root of the UI is 768 units tall
-- whatever the resolution. Without a parent the strip also stays up while the
-- interface is hidden (Alt-Z).
local function layout()
	local _, height = call(GetPhysicalScreenSize)
	height = num(height)
	frame:SetScale(height and height > 0 and 768 / height or 1)
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", 0, 0)
	frame:SetSize(COLS * CELL, ROWS * CELL)
end

local function create()
	frame:SetFrameStrata("TOOLTIP")
	frame:SetFrameLevel(9999)
	layout()
	local back = frame:CreateTexture(nil, "BACKGROUND")
	back:SetAllPoints()
	back:SetColorTexture(0, 0, 0, 1)
	for i = 0, CELLS - 1 do
		local cell = frame:CreateTexture(nil, "ARTWORK")
		if cell.SetSnapToPixelGrid then cell:SetSnapToPixelGrid(false) end
		if cell.SetTexelSnappingBias then cell:SetTexelSnappingBias(0) end
		cell:SetPoint("TOPLEFT", (i % COLS) * CELL, -floor(i / COLS) * CELL)
		cell:SetSize(CELL, CELL)
		cell:SetColorTexture(0, 0, 0, 1)
		cells[i], shown[i] = cell, 0
	end
end

-- A quarter step above the byte: the client lands on the byte whether it
-- rounds or truncates the colour to eight bits.
local function level(b)
	return min(1, (b + 0.25) / 255)
end

local function publish(fast)
	local parts, size = {}, 0
	for _, list in ipairs({ fast, slowParts }) do
		for _, c in ipairs(list) do
			if size + #c <= CAPACITY then
				parts[#parts + 1] = c
				size = size + #c
			end
		end
	end
	local payload = table.concat(parts)
	local a, b = 0, 0
	for i = 1, size do
		a = (a + byte(payload, i)) % 255
		b = (b + a) % 255
	end
	seq = (seq + 1) % 256
	local full = char(0x50, 0x4C, 0x4B, 0xFF, 0x00, 0xFF, COLS, ROWS, VERSION, seq, size % 256, floor(size / 256), a, b, 0)
		.. payload
	for i = 0, CELLS - 1 do
		local r, g, bl = byte(full, i * 3 + 1, i * 3 + 3)
		r, g, bl = r or 0, g or 0, bl or 0
		local key = r * 65536 + g * 256 + bl
		if shown[i] ~= key then
			shown[i] = key
			cells[i]:SetColorTexture(level(r), level(g), level(bl), 1)
		end
	end
end

local sinceFast, sinceSlow = 0, SLOW
frame:SetScript("OnUpdate", function(_, dt)
	if not cells[0] then return end
	sinceFast, sinceSlow = sinceFast + dt, sinceSlow + dt
	if sinceFast < FAST then return end
	sinceFast = 0
	if dirty or sinceSlow >= SLOW then
		sinceSlow, dirty = 0, false
		local ok, parts = pcall(buildSlow)
		slowParts = ok and parts or { chunk("E", "error: " .. tostring(parts)) }
	end
	local ok, fast = pcall(buildFast)
	publish(ok and fast or {})
end)

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

local function say(text)
	print("|cff7fb8ffPolestar Link|r: " .. text)
end

local function apply()
	frame:SetShown(db.enabled ~= false)
end

frame:SetScript("OnEvent", function(_, event, arg)
	if event == "ADDON_LOADED" then
		if arg ~= ADDON then return end
		if type(PolestarLinkDB) ~= "table" then PolestarLinkDB = {} end
		db = PolestarLinkDB
	elseif event == "PLAYER_LOGIN" then
		db = db or {}
		create()
		apply()
		local P = plain(_G.Polestar)
		local on = field(P, "On")
		for _, msg in ipairs({ "STEP_CHANGED", "GUIDE_CHANGED", "WAYPOINT_CHANGED" }) do
			call(on, msg, function() dirty = true end)
		end
	else
		layout()
	end
end)
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "DISPLAY_SIZE_CHANGED", "UI_SCALE_CHANGED" }) do
	pcall(frame.RegisterEvent, frame, event)
end

SLASH_POLESTARLINK1, SLASH_POLESTARLINK2 = "/plk", "/polestarlink"
SlashCmdList.POLESTARLINK = function(text)
	text = (text or ""):lower():match("^%s*(.-)%s*$")
	if not db then return end
	if text == "on" or text == "off" then
		db.enabled = text == "on"
	elseif text == "" then
		db.enabled = db.enabled == false
	else
		say("/plk on, /plk off, or /plk to toggle the strip.")
		return
	end
	apply()
	say(db.enabled ~= false and "strip on (top edge, from the left corner)." or "strip off.")
end
