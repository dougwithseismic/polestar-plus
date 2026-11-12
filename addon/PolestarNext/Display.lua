-- The panel: the ability to use now, large, with its key; the ones coming up
-- in a row beside it, each sliding along and growing into the big one as its
-- turn comes; and under them why, and which rotation is in use. Plain frames
-- with textures and text. A click on the panel opens its own menu; nothing
-- here can be clicked to cast, and the panel does nothing to the game but show.

local ADDON, ns = ...
local Scan, Engine, Rules, UI = ns.Scan, ns.Engine, ns.Rules, ns.UI

local HERO, SMALL = 54, 32 -- the ability to use now, and the ones coming up
local GAP, SPACE = 10, 4 -- between the big one and the row, and along the row
local WORDS = 56 -- the height of the words under the icons
local TICK = 0.1
local COMING = 4 -- how many are shown coming up, unless the player says otherwise

local frame = CreateFrame("Frame", "PolestarNextFrame", UIParent)
local strip, panel, title, note, rotation, tracker
local dirty, barsDirty, sinceTick, sinceBuild, sinceCheck = true, false, 0, 0, 0
local shownRule
local menu, dragging, draggedAt, mouseOn
local list, place, toggleMenu, stopGlow, toggleOptions -- defined further down

-- How see-through the panel is, as the player set it.
local function opacity()
	return math.max(0.3, math.min(1, tonumber(ns.db.alpha) or 1))
end

local function coming()
	return math.max(0, math.min(6, tonumber(ns.db.coming) or COMING))
end

---------------------------------------------------------------------------
-- The icons. Each ability on show has a tile, kept for as long as it stays
-- on show, so when its place changes the same tile travels: the next one up
-- slides left and grows into the big one, the rest shuffle along, a new one
-- comes in from the right, and the one just used swells and fades.
---------------------------------------------------------------------------

local tiles, spare, order = {}, {}, {}
-- For the tests: the tiles by ability name, and the names in the order shown.
ns.Strip = { tiles = tiles, order = order }

local function newTile()
	local t = table.remove(spare)
	if t then
		t:Show()
		return t
	end
	t = CreateFrame("Frame", nil, strip)
	t:SetSize(HERO, HERO)
	local back = t:CreateTexture(nil, "BACKGROUND")
	back:SetAllPoints()
	back:SetColorTexture(0, 0, 0, 0.9)
	t.icon = t:CreateTexture(nil, "ARTWORK")
	t.icon:SetPoint("TOPLEFT", 1, -1)
	t.icon:SetPoint("BOTTOMRIGHT", -1, 1)
	t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	t.edge = UI.Edge(t, 1, 1, 1, 0.3)
	-- The global cooldown, or a cast, running out: a shade over the icon
	-- that draws up from the bottom as the next press comes due.
	t.wipe = t:CreateTexture(nil, "ARTWORK", nil, 2)
	t.wipe:SetColorTexture(0, 0, 0, 0.62)
	t.wipe:SetPoint("TOPLEFT", 1, -1)
	t.wipe:SetPoint("TOPRIGHT", -1, -1)
	t.wipe:Hide()
	t.wipeEdge = t:CreateTexture(nil, "ARTWORK", nil, 3)
	t.wipeEdge:SetColorTexture(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3], 0.9)
	t.wipeEdge:SetHeight(1)
	t.wipeEdge:SetPoint("TOPLEFT", t.wipe, "BOTTOMLEFT")
	t.wipeEdge:SetPoint("TOPRIGHT", t.wipe, "BOTTOMRIGHT")
	t.wipeEdge:Hide()
	-- The key, on a dark patch in the corner.
	t.keyBack = t:CreateTexture(nil, "OVERLAY")
	t.keyBack:SetColorTexture(0, 0, 0, 0.75)
	t.key = UI.Text(t, 18, true)
	t.key:SetPoint("BOTTOMRIGHT", -3, 3)
	t.key:SetJustifyH("RIGHT")
	t.keyBack:SetPoint("TOPLEFT", t.key, "TOPLEFT", -3, 2)
	t.keyBack:SetPoint("BOTTOMRIGHT", t.key, "BOTTOMRIGHT", 2, -2)
	-- Seconds until it is off cooldown, across the middle.
	t.count = UI.Text(t, 22, true)
	t.count:SetPoint("CENTER", 0, 4)
	return t
end

local EDGES = { range = { 1, 0.35, 0.3 }, power = { 0.5, 0.6, 0.9 }, cooldown = { 0.6, 0.6, 0.6 } }
local GAME = { 0.35, 0.85, 0.8 } -- the edge of an icon that is the game's own pick

-- Makes tile `t` look like `entry`: its icon, key, and what is holding it up.
local function dress(t, entry, hero)
	local state = entry.state
	t.icon:SetTexture(entry.placeholder and UI.UNKNOWN_ICON or UI.Icon(state.id))
	t.icon:SetDesaturated(entry.blocked ~= nil or entry.placeholder == true)
	t.key:SetText(Scan.ShortKey(state.key) or "")
	t.keyBack:SetShown(state.key ~= nil)
	t.count:SetText(entry.blocked == "cooldown" and ("%d"):format(math.ceil(entry.left or 0)) or "")
	local c = EDGES[entry.blocked or ""]
	if entry.game then
		t.edge(GAME[1], GAME[2], GAME[3], 1)
	elseif c then
		t.edge(c[1], c[2], c[3], hero and 1 or 0.6)
	elseif hero and not entry.placeholder then
		t.edge(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3], 1)
	else
		t.edge(1, 1, 1, 0.3)
	end
end

-- Where the tile in place `i` belongs: its left edge and its size.
local function spot(i)
	if i == 1 then return 0, HERO end
	return HERO + GAP + (i - 2) * (SMALL + SPACE), SMALL
end

-- Sets where every tile is headed for the list `entries` (the first is the
-- one to use now). The moving itself happens a little every frame (animate).
local function arrange(entries)
	for _, t in pairs(tiles) do t.wanted = false end
	ns.wipe(order)
	local times = {}
	for i, entry in ipairs(entries) do
		local name = entry.state.name or "?"
		order[i] = name
		-- The plan may hold the same ability more than once (Sunder Armor to
		-- five): the first keeps its name, the rest are told apart by number.
		times[name] = (times[name] or 0) + 1
		local key = times[name] == 1 and name or (name .. "#" .. times[name])
		local x, size = spot(i)
		local t = tiles[key]
		if not t then
			-- New: it comes in from the right, small and faint.
			t = newTile()
			tiles[key], t.name = t, key
			t.x, t.size, t.alpha = x + 34, size * 0.6, 0
		end
		t.wanted, t.leaving, t.place, t.placeholder = true, false, i, entry.placeholder == true
		t.tx, t.tsize = x, size
		-- Ones still waiting on something sit back a little in the row.
		t.talpha = (entry.blocked and i > 1) and 0.6 or 1
		t:SetFrameLevel(strip:GetFrameLevel() + (i == 1 and 6 or 3))
		dress(t, entry, i == 1)
	end
	for _, t in pairs(tiles) do
		if not t.wanted and not t.leaving then
			t.leaving, t.talpha = true, 0
			-- The one just used swells as it goes; the others fade where they are.
			if t.place == 1 then
				t.tx, t.tsize = t.x - HERO * 0.15, HERO * 1.3
			end
			t:SetFrameLevel(strip:GetFrameLevel() + 1)
		end
	end
end

-- Moves every tile a step towards where it is headed, and draws the wait
-- for the next press over the big one.
local function animate(dt)
	local step = 1 - math.exp(-dt * 12)
	local left, total = 0, 0
	if ns.db.gcd ~= false then left, total = Rules.Busy() end
	for name, t in pairs(tiles) do
		local waiting = t.place == 1 and not t.leaving and not t.placeholder and left > 0.05 and total > 0
		if waiting then
			t.wipe:SetHeight(math.max(1, (HERO - 2) * math.min(1, left / total)))
			t.wipe:Show()
			t.wipeEdge:Show()
		elseif t.wiped ~= false then
			t.wipe:Hide()
			t.wipeEdge:Hide()
		end
		t.wiped = waiting
		t.x = t.x + (t.tx - t.x) * step
		t.size = t.size + (t.tsize - t.size) * step
		t.alpha = t.alpha + (t.talpha - t.alpha) * step
		if t.leaving and t.alpha < 0.04 then
			t:Hide()
			tiles[name] = nil
			spare[#spare + 1] = t
		else
			-- Scaled rather than resized, so its key and its count grow with it.
			local scale = math.max(0.05, t.size / HERO)
			t:SetScale(scale)
			t:ClearAllPoints()
			t:SetPoint("LEFT", strip, "LEFT", t.x / scale, 0)
			t:SetAlpha(t.alpha)
		end
	end
end

---------------------------------------------------------------------------
-- The panel itself
---------------------------------------------------------------------------

local function create()
	frame:SetFrameStrata("MEDIUM")
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		if ns.db.locked then return end
		dragging = true
		self:StartMoving()
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		dragging, draggedAt = false, GetTime()
		local point, _, relative, x, y = self:GetPoint(1)
		ns.db.point = { point, relative, x, y }
	end)
	-- A click, left or right, opens the menu. The end of a drag is not a click.
	frame:SetScript("OnMouseUp", function()
		if dragging or (draggedAt and GetTime() - draggedAt < 0.25) then return end
		toggleMenu()
	end)

	-- The row of icons along the top.
	strip = CreateFrame("Frame", nil, frame)
	strip:SetPoint("TOPLEFT")
	strip:SetPoint("TOPRIGHT")
	strip:SetHeight(HERO)

	-- The words on a dark panel under it.
	panel = CreateFrame("Frame", nil, frame)
	panel:SetPoint("TOPLEFT", 0, -(HERO + 4))
	panel:SetPoint("BOTTOMRIGHT")
	UI.Panel(panel, 0.72)
	title = UI.Text(panel, 14, true)
	title:SetPoint("TOPLEFT", 8, -5)
	title:SetWordWrap(false)
	title:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
	note = UI.Text(panel, 11, true)
	note:SetPoint("LEFT", title, "RIGHT", 8, 0)
	note:SetPoint("RIGHT", panel, "RIGHT", -6, 0)
	note:SetWordWrap(false)
	rotation = UI.Text(panel, 9, true)
	rotation:SetPoint("BOTTOMLEFT", 8, 5)
	rotation:SetTextColor(0.62, 0.62, 0.62)
	-- What is being kept track of: each effect's time left, stacks, the rage.
	tracker = UI.Text(panel, 10, true)
	tracker:SetPoint("BOTTOMLEFT", rotation, "TOPLEFT", 0, 3)
	tracker:SetPoint("RIGHT", panel, "RIGHT", -6, 0)
	tracker:SetWordWrap(false)
	ns.Strip.tracker = tracker

	frame:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Polestar Next: " .. Engine.Title())
		for i, rule in ipairs(Engine.list) do
			if i > 16 then break end
			local state = Engine.State(rule.spell)
			if state.known then
				local why = rule == shownRule and "now" or Engine.Why(rule)
				GameTooltip:AddDoubleLine(("%d. %s"):format(i, state.name or "?"), why, 1, 1, 1, 0.7, 0.7, 0.7)
			end
		end
		GameTooltip:AddLine(ns.db.locked and "Click for the menu." or "Click for the menu, drag to move.", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- The panel takes the mouse while there is something on it to click, and
-- lets it through while it is invisible: an unseen patch in the middle of
-- the screen must not swallow clicks meant for the world.
local function mouse(on)
	if mouseOn ~= on then
		mouseOn = on
		frame:EnableMouse(on)
	end
end

place = function()
	frame:ClearAllPoints()
	local p = ns.db.point
	if type(p) == "table" and p[1] then
		frame:SetPoint(p[1], UIParent, p[2] or p[1], p[3] or 0, p[4] or 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, -170)
	end
	frame:SetScale(ns.db.scale or 1)
	-- Wide enough for the row, and for the words when they are shown.
	local row = HERO + (coming() > 0 and GAP + coming() * (SMALL + SPACE) or 0)
	frame:SetSize(ns.db.compact and row or math.max(row, 230), HERO + (ns.db.compact and 0 or 4 + WORDS))
	-- Compact: the icons alone.
	panel:SetShown(not ns.db.compact)
end

---------------------------------------------------------------------------
-- The menu a click opens. Each entry is what it says now and what it does;
-- `stay` keeps the menu open for another click.
---------------------------------------------------------------------------

local MENU = {
	{ say = function() return "Edit the rotations..." end, run = function() ns.Edit.Toggle() end },
	{ say = function() return "Options..." end, run = function() toggleOptions() end },
	{ say = function() return "Print this rotation in chat" end, run = function()
		Engine.Rebuild()
		list()
	end },
	{ say = function() return ns.db.locked and "Unlock, so it can be dragged" or "Lock in place" end, run = function() ns.db.locked = not ns.db.locked end },
	{ say = function() return ("Coming up: %d shown (click for more)"):format(coming()) end, stay = true, run = function()
		ns.db.coming = (coming() + 1) % 7
	end },
	{ say = function() return ns.db.compact and "Show the words too" or "Show the icons only" end, run = function() ns.db.compact = not ns.db.compact end },
	{ say = function()
		local mode = Engine.AssistMode()
		return "The game's own pick: " .. (mode == "always" and "always shown first" or (mode == "off" and "not shown" or "when mine has nothing"))
	end, stay = true, run = function()
		local mode = Engine.AssistMode()
		ns.db.assist = mode == "fallback" and "always" or (mode == "always" and "off" or "fallback")
	end },
	{ say = function() return ns.db.glow ~= false and "Stop glowing the button on my bars" or "Glow the button on my bars" end, run = function()
		ns.db.glow = ns.db.glow == false
		if ns.db.glow == false then stopGlow() end
	end },
	{ say = function() return "Hide the panel, keep the glow" end, run = function()
		ns.db.hidePanel, ns.db.glow = true, true
		ns.say("the panel is put away and the glow stays. /pnext panel brings it back.")
	end },
	{ say = function() return "Bigger" end, stay = true, run = function() ns.db.scale = math.min(3, (ns.db.scale or 1) + 0.1) end },
	{ say = function() return "Smaller" end, stay = true, run = function() ns.db.scale = math.max(0.5, (ns.db.scale or 1) - 0.1) end },
	{ say = function() return "Back to the middle of the screen" end, run = function() ns.db.point = nil end },
	{ say = function() return "Hide (type /pnext to bring it back)" end, run = function()
		ns.db.shown = false
		stopGlow()
		frame:Hide()
	end },
}
ns.PanelMenu = MENU

local function relabel()
	for i, entry in ipairs(MENU) do menu.items[i].text:SetText(entry.say()) end
end

toggleMenu = function()
	if not menu then
		menu = CreateFrame("Frame", nil, UIParent)
		menu:SetFrameStrata("DIALOG")
		menu:SetSize(260, #MENU * 22 + 10)
		menu:EnableMouse(true)
		menu:SetClampedToScreen(true)
		UI.Panel(menu, 0.96)
		menu.items = {}
		for i, entry in ipairs(MENU) do
			local item = CreateFrame("Button", nil, menu)
			item:SetSize(250, 22)
			item:SetPoint("TOPLEFT", 5, -5 - (i - 1) * 22)
			item.glow = item:CreateTexture(nil, "BACKGROUND")
			item.glow:SetAllPoints()
			item.glow:SetColorTexture(1, 0.82, 0, 0)
			item.text = UI.Text(item, 12)
			item.text:SetPoint("LEFT", 8, 0)
			item:SetScript("OnEnter", function() item.glow:SetColorTexture(1, 0.82, 0, 0.22) end)
			item:SetScript("OnLeave", function() item.glow:SetColorTexture(1, 0.82, 0, 0) end)
			item:SetScript("OnClick", function()
				entry.run()
				place()
				if entry.stay then relabel() else menu:Hide() end
			end)
			menu.items[i] = item
		end
		-- It closes itself once the mouse has been off it and the panel a moment.
		menu:SetScript("OnUpdate", function(self, dt)
			if self:IsMouseOver() or frame:IsMouseOver() then
				self.away = 0
			else
				self.away = (self.away or 0) + dt
				if self.away > 1.2 then self:Hide() end
			end
		end)
		menu:Hide()
	end
	if menu:IsShown() then
		menu:Hide()
		return
	end
	relabel()
	menu.away = 0
	menu:ClearAllPoints()
	menu:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -4)
	menu:Show()
end

---------------------------------------------------------------------------
-- The options window: everything the panel can be told, in one place. Each
-- row is one of four kinds: a "check" (on or off), a "step" (a number, with
-- less and more), a "cycle" (a button that goes round its choices) and an
-- "action". The rows are data, so the tests can work them without a window.
---------------------------------------------------------------------------

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

local OPTIONS = {
	{ kind = "header", say = function() return "The panel" end },
	{ kind = "check", say = function() return "Show the panel" end,
		get = function() return ns.db.shown ~= false end,
		set = function(on)
			ns.db.shown = on
			if not on then stopGlow() end
			frame:SetShown(on)
		end },
	{ kind = "check", say = function() return "Lock it in place" end,
		get = function() return ns.db.locked == true end, set = function(on) ns.db.locked = on end },
	{ kind = "check", say = function() return "Icons only, without the words" end,
		get = function() return ns.db.compact == true end, set = function(on) ns.db.compact = on end },
	{ kind = "check", say = function() return "Show the global cooldown on the big icon" end,
		get = function() return ns.db.gcd ~= false end, set = function(on) ns.db.gcd = on end },
	{ kind = "check", say = function() return "Show what is being kept track of (effects, " .. Engine.PowerName() .. ")" end,
		get = function() return ns.db.tracking ~= false end, set = function(on) ns.db.tracking = on end },
	{ kind = "step", say = function() return ("Size: %d%%"):format(math.floor((ns.db.scale or 1) * 100 + 0.5)) end,
		step = function(by) ns.db.scale = clamp(math.floor(((ns.db.scale or 1) + by * 0.1) * 10 + 0.5) / 10, 0.5, 3) end },
	{ kind = "step", say = function() return ("Opacity: %d%%"):format(math.floor(opacity() * 100 + 0.5)) end,
		step = function(by) ns.db.alpha = clamp(math.floor((opacity() + by * 0.1) * 10 + 0.5) / 10, 0.3, 1) end },
	{ kind = "step", say = function() return ("Coming up: %d shown"):format(coming()) end,
		step = function(by) ns.db.coming = clamp(coming() + by, 0, 6) end },
	{ kind = "action", say = function() return "Put it back in the middle of the screen" end, run = function() ns.db.point = nil end },
	{ kind = "header", say = function() return "On my bars" end },
	{ kind = "check", say = function() return "Glow the button to press" end,
		get = function() return ns.db.glow ~= false end,
		set = function(on)
			ns.db.glow = on
			if not on then stopGlow() end
		end },
	{ kind = "check", say = function() return "Only the glow: keep the panel put away" end,
		get = function() return ns.db.hidePanel == true end,
		set = function(on)
			ns.db.hidePanel = on or nil
			if on then ns.db.glow = true end
		end },
	{ kind = "header", say = function() return "The game's own pick" end },
	{ kind = "cycle", say = function()
			local mode = Engine.AssistMode()
			return mode == "always" and "Always shown first" or (mode == "off" and "Not shown" or "Shown when my rotation has nothing")
		end,
		run = function()
			local mode = Engine.AssistMode()
			ns.db.assist = mode == "fallback" and "always" or (mode == "always" and "off" or "fallback")
		end },
	{ kind = "header", say = function() return "Rotations" end },
	{ kind = "action", say = function() return "Edit the rotations..." end, run = function() ns.Edit.Toggle() end },
	{ kind = "action", say = function() return "Print this rotation in chat" end, run = function()
		Engine.Rebuild()
		list()
	end },
}
ns.Options = OPTIONS

local options
local ROW = 24

local function redraw()
	if not options then return end
	for i, option in ipairs(OPTIONS) do
		local row = options.rows[i]
		row.text:SetText(option.say())
		if option.kind == "check" then
			if option.get() then row.box.fill:SetColorTexture(1, 0.82, 0, 0.9) else row.box.fill:SetColorTexture(0, 0, 0, 0.6) end
		end
	end
end

-- Does what a click on row `i` does: `by` is -1 or 1 for a step.
local function useOption(i, by)
	local option = OPTIONS[i]
	if not option then return end
	if option.kind == "check" then
		option.set(not option.get())
	elseif option.kind == "step" then
		option.step(by or 1)
	elseif option.run then
		option.run()
	end
	place()
	redraw()
end
ns.UseOption = useOption

toggleOptions = function()
	if not options then
		options = CreateFrame("Frame", "PolestarNextOptions", UIParent)
		options:SetFrameStrata("DIALOG")
		options:SetSize(360, #OPTIONS * ROW + 50)
		options:SetPoint("CENTER", 0, 60)
		options:SetMovable(true)
		options:EnableMouse(true)
		options:SetClampedToScreen(true)
		options:RegisterForDrag("LeftButton")
		options:SetScript("OnDragStart", options.StartMoving)
		options:SetScript("OnDragStop", options.StopMovingOrSizing)
		UI.Panel(options, 0.95)
		local heading = UI.Text(options, 16)
		heading:SetPoint("TOPLEFT", 14, -10)
		heading:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
		heading:SetText("Polestar Next  ·  options")
		local close = CreateFrame("Button", nil, options, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -2, -2)
		close:SetScript("OnClick", function() options:Hide() end)
		options.rows = {}
		for i, option in ipairs(OPTIONS) do
			local row = CreateFrame("Button", nil, options)
			row:SetSize(332, ROW)
			row:SetPoint("TOPLEFT", 14, -36 - (i - 1) * ROW)
			row.text = UI.Text(row, option.kind == "header" and 11 or 12)
			if option.kind == "header" then
				row.text:SetPoint("BOTTOMLEFT", 0, 4)
				row.text:SetTextColor(0.6, 0.6, 0.6)
				local line = row:CreateTexture(nil, "ARTWORK")
				line:SetColorTexture(1, 1, 1, 0.12)
				line:SetHeight(1)
				line:SetPoint("BOTTOMLEFT")
				line:SetPoint("BOTTOMRIGHT")
			elseif option.kind == "check" then
				-- Gold when it is on, hollow when it is off; the whole row is the switch.
				row.box = CreateFrame("Frame", nil, row)
				row.box:SetSize(13, 13)
				row.box:SetPoint("LEFT", 2, 0)
				row.box.fill = row.box:CreateTexture(nil, "ARTWORK")
				row.box.fill:SetAllPoints()
				UI.Edge(row.box, 1, 0.82, 0, 0.8)
				row.text:SetPoint("LEFT", 24, 0)
				row:SetScript("OnClick", function() useOption(i) end)
			elseif option.kind == "step" then
				row.text:SetPoint("LEFT", 24, 0)
				for _, by in ipairs({ -1, 1 }) do
					local press = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
					press:SetSize(24, 20)
					press:SetText(by < 0 and "-" or "+")
					press:SetPoint("RIGHT", by < 0 and -28 or 0, 0)
					press:SetScript("OnClick", function() useOption(i, by) end)
					row[by < 0 and "less" or "more"] = press
				end
			else
				row.press = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
				row.press:SetSize(308, 20)
				row.press:SetPoint("LEFT", 24, 0)
				row.press:SetScript("OnClick", function() useOption(i) end)
				-- The button carries the words.
				row.text = row.press
			end
			options.rows[i] = row
		end
		options:Hide()
	end
	if options:IsShown() then
		options:Hide()
		return
	end
	redraw()
	options:Show()
end
ns.ToggleOptions = function() toggleOptions() end

---------------------------------------------------------------------------
-- The glow: a pulsing edge round the suggested ability's own button on the
-- action bars, so the eye can go to the button instead of the panel. It is a
-- frame of this add-on's laid over the button: it draws, and that is all; the
-- button underneath is the game's and is clicked as it always was.
---------------------------------------------------------------------------

local Glow = { button = nil, kind = nil }
ns.Glow = Glow
local glowFrame

local GLOWS = { now = { 1, 0.82, 0 }, range = { 1, 0.35, 0.3 }, power = { 0.45, 0.6, 1 } }

stopGlow = function()
	Glow.button, Glow.kind = nil, nil
	if glowFrame then glowFrame:Hide() end
end

local function glow(entry)
	local button
	-- A button still on cooldown is not one to reach for yet.
	if entry and entry.blocked ~= "cooldown" and not entry.placeholder and ns.db.glow ~= false then
		local bar = Scan.bars[(entry.state.name or ""):lower()]
		button = bar and bar.button
		-- A button on a bar that is not shown has nothing to glow round.
		if button and not (type(button.IsVisible) == "function" and button:IsVisible()) then button = nil end
	end
	local kind = button and (entry.blocked or "now") or nil
	if button == Glow.button and kind == Glow.kind then return end
	if not button then return stopGlow() end
	Glow.button, Glow.kind = button, kind
	if not glowFrame then
		glowFrame = CreateFrame("Frame", nil, UIParent)
		glowFrame:SetFrameStrata("HIGH")
		glowFrame.parts = {}
		for i, at in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
			local part = glowFrame:CreateTexture(nil, "OVERLAY")
			part:SetPoint(at[1])
			part:SetPoint(at[2])
			if i <= 2 then part:SetHeight(3) else part:SetWidth(3) end
			glowFrame.parts[i] = part
		end
		local wash = glowFrame:CreateTexture(nil, "ARTWORK")
		wash:SetAllPoints()
		wash:SetBlendMode("ADD")
		glowFrame.parts[5] = wash
		glowFrame:SetScript("OnUpdate", function(self, dt)
			self.beat = (self.beat or 0) + dt
			self:SetAlpha(0.7 + 0.3 * math.sin(self.beat * 6))
		end)
	end
	local c = GLOWS[kind] or GLOWS.now
	for i, part in ipairs(glowFrame.parts) do part:SetColorTexture(c[1], c[2], c[3], i == 5 and 0.16 or 1) end
	glowFrame:ClearAllPoints()
	glowFrame:SetPoint("TOPLEFT", button, "TOPLEFT", -3, 3)
	glowFrame:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 3, -3)
	glowFrame:Show()
end

---------------------------------------------------------------------------
-- Showing a moment
---------------------------------------------------------------------------

-- The tracking line: "Rend 4s  Sunder Armor x5 22s  rage 55 +4/s". A timer
-- about to run out is red; one the add-on is estimating (the game will not
-- show it) has a ~ before it.
local function tracking()
	local parts = {}
	for _, e in ipairs(Engine.Tracked()) do
		local text = e.name
		if e.stacks then text = text .. " x" .. e.stacks end
		if e.left then
			local colour = e.left < 3 and "ff6b5a" or (e.left < 6 and "ffd100" or "c8c8c8")
			text = ("%s |cff%s%s%ds|r"):format(text, colour, e.sure and "" or "~", math.max(0, math.floor(e.left + 0.5)))
		end
		parts[#parts + 1] = text
	end
	local power = Rules.Power()
	if power then
		local income = Rules.rate >= 0.5 and (" |cff8fb4ff+%.0f/s|r"):format(Rules.rate) or ""
		parts[#parts + 1] = ("%s %d%s"):format(Engine.PowerName(), power, income)
	elseif Rules.fighting then
		-- The game hides the bar: what its own answers prove about it.
		local low, under = Rules.Proved()
		local range = under and (under - 1 > low and ("%d-%d"):format(low, under - 1) or ("%d"):format(low)) or (low .. "+")
		parts[#parts + 1] = ("%s |cff9d9d9d~|r%s"):format(Engine.PowerName(), range)
	end
	return table.concat(parts, "   ")
end

local PLACEHOLDER = { { placeholder = true, state = { name = "Polestar Next" } } }
local NOTHING = {}

-- Shows what Engine.Upcoming gave: the one to use now, then what is coming.
local function show(entries)
	local first = entries[1]
	shownRule = first and first.rule or nil
	glow(first)
	-- The panel can be put away while the glow stays.
	if ns.db.hidePanel then
		arrange(NOTHING)
		frame:SetAlpha(0)
		mouse(menu ~= nil and menu:IsShown() == true)
		return
	end
	tracker:SetText(ns.db.tracking ~= false and tracking() or "")
	local around = Rules.Enemies()
	rotation:SetText(Engine.Title() .. (Engine.custom and "  (yours)" or "") .. (around and around >= 2 and ("  |cffffd100x" .. around .. "|r") or ""))
	if not first then
		-- Nothing to do: out of the way, unless it is unlocked for placing.
		if ns.db.locked then
			arrange(NOTHING)
			frame:SetAlpha(0)
			mouse(menu ~= nil and menu:IsShown() == true)
		else
			arrange(PLACEHOLDER)
			mouse(true)
			frame:SetAlpha(0.55 * opacity())
			title:SetText("Polestar Next")
			note:SetText("drag me, click for the menu")
			note:SetTextColor(0.9, 0.9, 0.9)
		end
		return
	end
	arrange(entries)
	local state = first.state
	frame:SetAlpha(opacity())
	mouse(true)
	title:SetText(state.name or "")
	if first.blocked == "range" then
		-- Usable but for the distance: dimmed, with what to do about it.
		note:SetText("move into range")
		note:SetTextColor(UI.RED[1], UI.RED[2], UI.RED[3])
	elseif first.blocked == "power" then
		-- Next up, once there is the rage, energy or mana for it.
		note:SetText("not enough " .. Engine.PowerName() .. " yet")
		note:SetTextColor(0.62, 0.72, 1)
	elseif first.blocked == "cooldown" then
		note:SetText(("ready in %d s"):format(math.ceil(first.left or 0)))
		note:SetTextColor(0.75, 0.75, 0.75)
	elseif first.game then
		note:SetText("the game's own pick")
		note:SetTextColor(GAME[1], GAME[2], GAME[3])
	else
		note:SetTextColor(0.9, 0.9, 0.9)
		if state.onBars and state.key then
			note:SetText(first.rule.note or "")
		elseif state.onBars then
			note:SetText("on your bars, no key bound")
		else
			note:SetText("not on your bars in this stance")
		end
	end
end

frame:SetScript("OnUpdate", function(_, dt)
	if not ns.db or not strip then return end
	-- The icons move every frame; everything else is looked at ten times a second.
	animate(dt)
	sinceTick, sinceBuild, sinceCheck = sinceTick + dt, sinceBuild + dt, sinceCheck + dt
	if sinceTick < TICK then return end
	sinceTick = 0
	-- Once a second, whatever the events said: has anything the rotation is
	-- built from changed (talents, spells, weapons, stance)?
	if sinceCheck >= 1 then
		sinceCheck = 0
		if Scan.Signature() ~= Engine.signature then dirty = true end
	end
	-- Rescans are held to twice a second: a level-up fires a burst of events.
	if dirty and sinceBuild >= 0.5 then
		dirty, barsDirty, sinceBuild = false, false, 0
		Engine.Rebuild()
		ns.Edit.Migrate()
		ns.Edit.Notice()
	elseif barsDirty then
		barsDirty = false
		Scan.Bars()
	end
	if ns.db.shown == false then return end
	local entries = Engine.Upcoming(1 + coming())
	show(entries)
	-- How often the game's assistant and this rotation name the same thing.
	if Rules.fighting and entries[1] and not entries[1].blocked and not entries[1].game then
		local pick = Engine.Assistant().pick
		if pick then
			Engine.picks.shown = Engine.picks.shown + 1
			if pick[2] == entries[1].state.name then Engine.picks.agreed = Engine.picks.agreed + 1 end
		end
	end
	-- In a fight with nothing to use and nothing to head for: note what every
	-- ability said, so the reason can be read from the saved report afterwards.
	local first = entries[1]
	if (not first or first.blocked == "cooldown") and Rules.fighting and Rules.Check({ "target" }) == true then
		local idle = Engine.idle
		idle.times = idle.times + 1
		if not idle.at or GetTime() - idle.at > 3 then
			idle.at = GetTime()
			idle.rotation, idle.why = Engine.Title(), Engine.Explain()
			local power = ns.call(UnitPower, "player")
			idle.power = ns.secret(power) and "hidden by the game" or ns.num(power)
		end
	end
end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- What changes the character: spells, talents, gear, level, stance.
local REBUILD = {
	"SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "PLAYER_LEVEL_UP", "PLAYER_EQUIPMENT_CHANGED", "TRAIT_CONFIG_UPDATED",
	"PLAYER_TALENT_UPDATE", "CHARACTER_POINTS_CHANGED", "ACTIVE_TALENT_GROUP_CHANGED", "UNIT_PET",
	-- The talent tree's own events on clients built on C_Traits.
	"TRAIT_NODE_CHANGED", "TRAIT_TREE_CURRENCY_INFO_UPDATED", "TRAIT_CONFIG_LIST_UPDATED", "ACTIVE_COMBAT_CONFIG_CHANGED",
	"PLAYER_SPECIALIZATION_CHANGED",
}
-- What moves spells between buttons.
local BARS = { "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR", "UPDATE_BINDINGS" }
-- A new stance or form is both: other buttons at once, and another rotation.
local STANCE = { "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS" }

local events = CreateFrame("Frame")
local kind = {}
events:SetScript("OnEvent", function(_, event, a, _, c)
	if event == "ADDON_LOADED" then
		if a ~= ADDON then return end
		if type(PolestarNextDB) ~= "table" then PolestarNextDB = {} end
		ns.db = PolestarNextDB
		-- Kept: rotations the player changed, saved by tree and stance
		-- ("WARRIOR:3:2"). Dropped: copies an earlier version saved just for
		-- opening the editor, and lists saved by class alone.
		for name in pairs(type(ns.db.lists) == "table" and ns.db.lists or {}) do
			local edited = type(ns.db.edited) == "table" and ns.db.edited[name]
			if not edited or not tostring(name):find(":", 1, true) then ns.db.lists[name] = nil end
		end
	elseif event == "PLAYER_LOGIN" then
		ns.db = ns.db or {}
		create()
		place()
		frame:SetShown(ns.db.shown ~= false)
		dirty, sinceBuild = true, 1
		-- Said once: the game has a button of its own for this.
		if not ns.db.toldAssist and Engine.Assistant().available and Engine.Assistant().button then
			ns.db.toldAssist = true
			ns.say("this game has its own one-button rotation. /pnext assist says how to use it.")
		end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if a == "player" then Rules.SawCast(c) end
	elseif kind[event] == "bars" then
		barsDirty = true
	elseif kind[event] == "stance" then
		barsDirty, dirty = true, true
	else
		dirty = true
	end
end)
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "UNIT_SPELLCAST_SUCCEEDED" }) do pcall(events.RegisterEvent, events, event) end
for _, event in ipairs(REBUILD) do pcall(events.RegisterEvent, events, event) end
for _, event in ipairs(BARS) do
	kind[event] = "bars"
	pcall(events.RegisterEvent, events, event)
end
for _, event in ipairs(STANCE) do
	kind[event] = "stance"
	pcall(events.RegisterEvent, events, event)
end

---------------------------------------------------------------------------
-- /pnext
---------------------------------------------------------------------------

-- What the rotation was built for, in one line.
local function summary()
	local g, parts = Scan.gear, {}
	parts[#parts + 1] = ("%s, level %d"):format(Scan.class or "class unknown", Scan.level)
	if Scan.spec then
		parts[#parts + 1] = ("%s (%d/%d/%d, by %s)"):format(Engine.Title(), Scan.points[1], Scan.points[2], Scan.points[3], Scan.pointsFrom or "?")
	else
		parts[#parts + 1] = "no talents spent" .. (Scan.stances[Scan.stance] and (", " .. Scan.stances[Scan.stance]) or "")
	end
	if g.twoHand then parts[#parts + 1] = "two-hander" end
	if g.dualWield then parts[#parts + 1] = "two weapons" end
	if g.shield then parts[#parts + 1] = "shield" end
	if g.dagger then parts[#parts + 1] = "dagger" end
	if g.wand then parts[#parts + 1] = "wand" end
	if g.rangedWeapon then parts[#parts + 1] = "ranged weapon" end
	return table.concat(parts, ", ")
end
ns.Summary = summary

list = function()
	ns.say(summary() .. (Engine.custom and " (your version of this rotation)" or ""))
	for _, text in ipairs(Engine.notes) do print("  " .. text) end
	local n = 0
	for _, rule in ipairs(Engine.list) do
		local state = Engine.State(rule.spell)
		if state.known then
			n = n + 1
			local keyText = state.key and (" [" .. Scan.ShortKey(state.key) .. "]") or (state.onBars and " [no key]" or " [not on bars]")
			print(("  %d. |cffffd100%s|r%s%s  when %s%s"):format(n, state.name, keyText, rule.off and " |cffff8866(switched off)|r" or "",
				Rules.Describe(rule.when), rule.figures and ("  |cff9d9d9d(" .. rule.figures .. ")|r") or ""))
		end
	end
	if n == 0 then print("  Nothing on the list is in your spellbook yet.") end
	for _, text in ipairs(Scan.problems) do print("  |cffff8866" .. text .. "|r") end
end

SLASH_POLESTARNEXT1, SLASH_POLESTARNEXT2 = "/pnext", "/polestarnext"
SlashCmdList.POLESTARNEXT = function(text)
	local db = ns.db
	if not db or not strip then return end
	local word, rest = (text or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if word == "" then
		db.shown = db.shown == false
		if db.shown == false then stopGlow() end
		frame:SetShown(db.shown ~= false)
		ns.say(db.shown ~= false and "on." or "off.")
	elseif word == "lock" or word == "unlock" then
		db.locked = word == "lock"
		place()
		ns.say(db.locked and "locked in place. Click it for the menu." or "unlocked: drag it where you want it.")
	elseif word == "next" and tonumber(rest) then
		db.coming = math.max(0, math.min(6, math.floor(tonumber(rest))))
		place()
		ns.say(("showing %d coming up."):format(db.coming))
	elseif word == "assist" then
		local a = Engine.Assistant()
		if rest == "off" or rest == "always" or rest == "fallback" then db.assist = rest end
		if not a.available then
			ns.say("this game has no assistant of its own, or it is not available to your character.")
		else
			ns.say("the game has its own assistant: it picks the next spell itself, knowing the rage and health it hides from add-ons.")
			if a.button then
				print(("  Its one button is |cffffd100%s|r: find it in your spellbook, drag it to a bar, and each press casts the game's pick."):format(a.button[2]))
			else
				print("  It has a one-button spell in the spellbook: on a bar, each press casts the game's pick.")
			end
			if a.pick then print(("  Right now it would cast |cffffd100%s|r."):format(a.pick[2])) end
			local mode = Engine.AssistMode()
			print("  On this panel its pick is " .. (mode == "always" and "always shown first" or (mode == "off" and "not shown" or "shown when your own rotation has nothing")) ..
				". Change with /pnext assist always, fallback or off.")
		end
	elseif word == "glow" then
		db.glow = db.glow == false
		if db.glow == false then stopGlow() end
		ns.say(db.glow ~= false and "the suggested ability's button glows on your bars." or "no glow on the bars.")
	elseif word == "panel" then
		db.hidePanel = not db.hidePanel
		ns.say(db.hidePanel and "the panel is put away (the glow stays)." or "the panel is back.")
	elseif word == "compact" then
		db.compact = not db.compact
		place()
		ns.say(db.compact and "icons only." or "icons and words.")
	elseif word == "scale" and tonumber(rest) then
		db.scale = math.max(0.5, math.min(3, tonumber(rest)))
		place()
	elseif word == "reset" then
		db.point, db.scale, db.locked, db.compact, db.hidePanel, db.coming = nil, nil, nil, nil, nil, nil
		place()
		ns.say("back in the middle, unlocked.")
	elseif word == "scan" or word == "list" then
		Engine.Rebuild()
		list()
	elseif word == "options" or word == "config" or word == "settings" then
		toggleOptions()
	elseif word == "gcd" then
		db.gcd = db.gcd == false
		ns.say(db.gcd ~= false and "the global cooldown shows on the big icon." or "no global cooldown on the big icon.")
	elseif word == "edit" then
		ns.Edit.Toggle()
	elseif word == "share" or word == "import" then
		ns.Edit.Share(word)
	elseif word == "update" then
		ns.Edit.Pick()
		local count = ns.Edit.Update()
		ns.say(count > 0 and ("your version is brought up to date in " .. count .. " places. Your order is kept.")
			or "the rotation in use has nothing to bring up to date.")
	elseif word == "restore" then
		ns.say(ns.Edit.Restore() and "the rotation the import replaced is back." or "there is no replaced rotation to bring back here.")
	else
		ns.say("Click the panel for its menu. Or: /pnext (on or off), /pnext options, /pnext edit, /pnext share, /pnext import, /pnext update, /pnext list, /pnext assist, /pnext next 4, /pnext glow, /pnext panel, /pnext lock, /pnext unlock, /pnext compact, /pnext scale 1.2, /pnext reset")
	end
end
