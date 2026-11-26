-- Don't Hide/Show/resize/Layout Blizzard's frames or parent anything to them, it taints
-- Edit Mode. Alpha, mouse and anchors only.

local ADDON_NAME = ...

local DOUBLE_CLICK_SECONDS = 0.35
local SCAN_INTERVAL = 0.25
local LOG_LINES = 300
local TITLE_ROW_PADDING = 14
local TITLE_ROW_FALLBACK = 44
local TUTORIAL_BUTTON_CLEARANCE = 28 -- clears the (i) button
local ARROW_UP = [[Interface\Buttons\UI-ScrollBar-ScrollUpButton-Up]]
local ARROW_DOWN = [[Interface\Buttons\UI-ScrollBar-ScrollDownButton-Up]]
local ARROW_HIGHLIGHT = [[Interface\Buttons\UI-ScrollBar-ScrollUpButton-Highlight]]

local windows = {}
local ownFrames = {} -- our bars look like Edit Mode windows too
local sparePairs = {}
local pairsMade = 0
local db

-- /ws log on: kept in the saved variables file, readable after a /reload
local function Log(text, ...)
	if not (db and db.logging) then
		return
	end
	local log = db.log
	log[#log + 1] = date("%H:%M:%S ") .. text:format(...)
	if #log > LOG_LINES then
		table.remove(log, 1)
	end
end

-- first line of the stack that isn't us or Blizzard's hook plumbing
local function Caller()
	for line in debugstack(3, 6, 0):gmatch("[^\n]+") do
		if not line:find(ADDON_NAME, 1, true) and not line:find("[C]", 1, true) then
			local file, lineNumber = line:match('AddOns[/\\]([^"%]]+)"?%]?:(%d+)')
			return file and (file .. ":" .. lineNumber) or line
		end
	end
	return "?"
end

local function TitleOf(window)
	local text = window.Title:GetText()
	if text and text ~= "" then
		return text
	end
end

local function IsRolledUp(window)
	local title = TitleOf(window)
	return title ~= nil and db.collapsed[title] == true
end

local function IsEditModeWindow(frame)
	if ownFrames[frame] or frame:IsForbidden() or frame:IsProtected() then
		return false
	end
	if not (frame:IsShown() and frame:IsMovable() and frame:GetFrameStrata() == "DIALOG") then
		return false
	end
	local title = frame.Title
	return type(title) == "table" and type(title.GetText) == "function" and type(title.GetTop) == "function"
end

local function CloseButtonOf(window)
	return window.CloseButton or window.Close
end

local function TitleRowHeight(window)
	local top, titleBottom = window:GetTop(), window.Title:GetBottom()
	if not (top and titleBottom) then
		return TITLE_ROW_FALLBACK
	end
	return top - titleBottom + TITLE_ROW_PADDING
end

local function ArrowPlacement(window)
	local close = CloseButtonOf(window)
	local size, x, y = 24, 6, -6
	if close then
		local width, height = close:GetSize()
		size = math.max(width or 0, height or 0, 20)
		local point, _, _, offsetX, offsetY = close:GetPoint(1)
		if point == "TOPRIGHT" then
			x, y = -(offsetX or 0), offsetY or 0
		end
	end
	if window == EditModeManagerFrame then
		x = x + TUTORIAL_BUTTON_CLEARANCE
	end
	return size, x, y
end

local function CropArrowTexture(texture)
	texture:SetTexCoord(0.2, 0.8, 0.2, 0.8)
end

local function SetArrowDirection(arrow, pointsDown)
	local file = pointsDown and ARROW_DOWN or ARROW_UP
	arrow:SetNormalTexture(file)
	arrow:SetPushedTexture(file)
	CropArrowTexture(arrow:GetNormalTexture())
	CropArrowTexture(arrow:GetPushedTexture())
end

local function CreateArrow(parent)
	local arrow = CreateFrame("Button", nil, parent)
	ownFrames[arrow] = true
	arrow:SetHighlightTexture(ARROW_HIGHLIGHT, "ADD")
	CropArrowTexture(arrow:GetHighlightTexture())
	return arrow
end

local function RestorePosition(window, force)
	local state = windows[window]
	if state.dragging or state.anchoring then
		return
	end
	local title = TitleOf(window)
	local saved = title and db.positions[title]
	if not saved then
		return
	end
	if not force then
		local left, top = window:GetLeft(), window:GetTop()
		local inPlace = left and top and math.abs(left - saved.x) < 0.5 and math.abs(top - saved.y) < 0.5
		if inPlace and window:GetNumPoints() == 1 then
			return
		end
	end
	state.anchoring = true
	window:ClearAllPoints()
	window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", saved.x, saved.y)
	state.anchoring = false
end

local function SavePosition(window, left, top)
	local title = TitleOf(window)
	if title and left and top then
		db.positions[title] = { x = left, y = top }
	end
end

local function StaysVisible(window, child, state)
	if child == CloseButtonOf(window) then
		return true
	end
	-- title row buttons stay clickable
	if child ~= window.Title and child.GetBottom then
		local bottom, top = child:GetBottom(), window:GetTop()
		if bottom and top and bottom >= top - (state.titleRowHeight or TITLE_ROW_FALLBACK) - 1 then
			return true
		end
	end
	-- grid and snap lines
	return child.GetFrameStrata ~= nil and child:GetFrameStrata() ~= window:GetFrameStrata()
end

local function DisableMouse(object, state)
	if object.IsMouseEnabled and object:IsMouseEnabled() then
		object:EnableMouse(false)
		state.mouseOff[object] = true
	end
	if object.IsMouseWheelEnabled and object:IsMouseWheelEnabled() then
		object:EnableMouseWheel(false)
		state.wheelOff[object] = true
	end
	if object.GetChildren then
		for _, child in ipairs({ object:GetChildren() }) do
			DisableMouse(child, state)
		end
	end
end

local function FadeContents(window, state)
	if not state.savedAlpha then
		state.savedAlpha, state.mouseOff, state.wheelOff = {}, {}, {}
	end
	for _, list in ipairs({ { window:GetChildren() }, { window:GetRegions() } }) do
		for _, child in ipairs(list) do
			if state.savedAlpha[child] ~= nil or not StaysVisible(window, child, state) then
				if state.savedAlpha[child] == nil then
					state.savedAlpha[child] = child:GetAlpha()
				end
				if child:GetAlpha() ~= 0 then
					child:SetAlpha(0)
				end
				if child.EnableMouse then
					DisableMouse(child, state)
				end
			end
		end
	end
	if window:IsMouseEnabled() then
		window:EnableMouse(false)
		state.mouseOff[window] = true
	end
end

local function RestoreContents(state)
	if not state.savedAlpha then
		return
	end
	for child, alpha in pairs(state.savedAlpha) do
		child:SetAlpha(alpha)
	end
	for object in pairs(state.mouseOff) do
		object:EnableMouse(true)
	end
	for object in pairs(state.wheelOff) do
		object:EnableMouseWheel(true)
	end
	state.savedAlpha, state.mouseOff, state.wheelOff = nil, nil, nil
end

local CreatePair

local function ReleasePair(state)
	local pair = state.pair
	if not pair then
		return
	end
	pair.bar:StopMovingOrSizing()
	pair.bar:Hide()
	pair.arrow:Hide()
	pair.bar.window, pair.arrow.window = nil, nil
	sparePairs[#sparePairs + 1] = pair
	state.pair, state.dragging = nil, false
end

local function AcquirePair(window, state)
	if not state.pair then
		state.pair = table.remove(sparePairs)
		if not state.pair then
			state.pair = CreatePair()
			pairsMade = pairsMade + 1
			Log("new bar for %s (%d made, %d spare)", tostring(TitleOf(window)), pairsMade, #sparePairs)
		end
		state.pair.bar.window, state.pair.arrow.window = window, window
	end
	return state.pair
end

local function Refresh(window)
	local state = windows[window]
	if not window:IsVisible() then
		RestoreContents(state)
		ReleasePair(state)
		return
	end
	local pair = AcquirePair(window, state)
	local rolledUp = IsRolledUp(window)
	local arrowSize, arrowX, arrowY = ArrowPlacement(window)

	local bar = pair.bar
	if rolledUp then
		FadeContents(window, state)
		local close = CloseButtonOf(window)
		bar:SetFrameLevel(window:GetFrameLevel()) -- keeps title row buttons on top
		if not state.dragging then
			bar:ClearAllPoints()
			bar:SetPoint("TOPLEFT", window, "TOPLEFT")
		end
		bar:SetSize(window:GetWidth(), state.titleRowHeight or TITLE_ROW_FALLBACK)
		bar:SetHitRectInsets(0, close and close:GetWidth() or 0, 0, 0)
		bar.Title:SetText(TitleOf(window))
		bar.Arrow:SetSize(arrowSize, arrowSize)
		bar.Arrow:ClearAllPoints()
		bar.Arrow:SetPoint("TOPLEFT", arrowX, arrowY)
		bar:Show()
	else
		bar:Hide()
		RestoreContents(state)
		state.titleRowHeight = TitleRowHeight(window)
	end

	local arrow = pair.arrow
	if not rolledUp and TitleOf(window) then
		arrow:SetSize(arrowSize, arrowSize)
		arrow:ClearAllPoints()
		arrow:SetPoint("TOPLEFT", window, "TOPLEFT", arrowX, arrowY)
		arrow:SetFrameLevel(window:GetFrameLevel() + 10)
		arrow:Show()
	else
		arrow:Hide()
	end
end

local function Toggle(window)
	local title = TitleOf(window)
	if not title then
		return
	end
	if db.collapsed[title] then
		db.collapsed[title] = nil
		Log("opened %s", title)
	else
		windows[window].titleRowHeight = TitleRowHeight(window)
		db.collapsed[title] = true
		Log("rolled up %s", title)
	end
	Refresh(window)
end

local function IsDoubleClick(clickState)
	local now = GetTime()
	if clickState.lastClick and now - clickState.lastClick <= DOUBLE_CLICK_SECONDS then
		clickState.lastClick = nil
		return true
	end
	clickState.lastClick = now
	return false
end

local function OnWindowMouseDown(window, button)
	if button ~= "LeftButton" then
		return
	end
	local state = windows[window]
	local _, cursorY = GetCursorPosition()
	local top = window:GetTop()
	if not top or cursorY / window:GetEffectiveScale() < top - TitleRowHeight(window) then
		state.lastClick = nil
		return
	end
	if IsDoubleClick(state) then
		Toggle(window)
	end
end

local function FollowVisibility(widget)
	widget:SetScript("OnUpdate", function(self)
		if self.window and not self.window:IsVisible() then
			Refresh(self.window)
		end
	end)
end

local function CreateBar()
	local bar = CreateFrame("Frame", nil, UIParent)
	ownFrames[bar] = true
	CreateFrame("Frame", nil, bar, "DialogBorderTranslucentTemplate"):SetAllPoints()
	bar:SetFrameStrata("DIALOG")
	bar:EnableMouse(true)
	bar:SetMovable(true)
	bar:RegisterForDrag("LeftButton")
	bar:Hide()

	bar.Title = bar:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	bar.Title:SetPoint("TOP", 0, -15)

	bar.Arrow = CreateArrow(bar)
	SetArrowDirection(bar.Arrow, true)
	bar.Arrow:SetScript("OnClick", function(self)
		Toggle(self:GetParent().window)
	end)

	FollowVisibility(bar)

	local clickState = {}
	bar:SetScript("OnMouseDown", function(self, button)
		if button == "LeftButton" and IsDoubleClick(clickState) then
			Toggle(self.window)
		end
	end)
	bar:SetScript("OnDragStart", function(self)
		windows[self.window].dragging = true
		self:StartMoving()
	end)
	bar:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local window = self.window
		windows[window].dragging = false
		SavePosition(window, self:GetLeft(), self:GetTop())
		Log("dragged %s (bar) to %d, %d", tostring(TitleOf(window)), self:GetLeft() or 0, self:GetTop() or 0)
		RestorePosition(window, true)
		Refresh(window)
	end)
	return bar
end

local function CreateOpenArrow()
	local arrow = CreateArrow(UIParent)
	arrow:SetFrameStrata("DIALOG")
	SetArrowDirection(arrow, false)
	arrow:SetScript("OnClick", function(self)
		Toggle(self.window)
	end)
	FollowVisibility(arrow)
	arrow:Hide()
	return arrow
end

CreatePair = function()
	return { bar = CreateBar(), arrow = CreateOpenArrow() }
end

local function Track(window)
	if windows[window] then
		return
	end
	windows[window] = {}
	Log("tracking %s (%s)", tostring(TitleOf(window)), window:GetName() or "unnamed")

	window:HookScript("OnMouseDown", OnWindowMouseDown)
	window:HookScript("OnDragStart", function(self)
		windows[self].dragging = true
	end)
	window:HookScript("OnDragStop", function(self)
		windows[self].dragging = false
		SavePosition(self, self:GetLeft(), self:GetTop())
		Log("dragged %s to %d, %d", tostring(TitleOf(self)), self:GetLeft() or 0, self:GetTop() or 0)
		RestorePosition(self, true)
	end)
	window:HookScript("OnShow", function(self)
		RestorePosition(self, true)
		Refresh(self)
	end)
	window:HookScript("OnHide", function(self)
		windows[self].dragging = false
		Refresh(self)
	end)
	-- same frame, so it never flashes at the default spot
	hooksecurefunc(window, "SetPoint", function(self)
		local state = windows[self]
		if not state.anchoring and not state.dragging and db.positions[TitleOf(self) or ""] then
			Log("%s moved by %s, put back", tostring(TitleOf(self)), Caller())
			RestorePosition(self, true)
		end
	end)
	RestorePosition(window, true)
	Refresh(window)
end

local function IsEditModeOpen()
	return db ~= nil and EditModeManagerFrame ~= nil and EditModeManagerFrame:IsShown()
end

local function Scan()
	if IsEditModeWindow(EditModeManagerFrame) then
		Track(EditModeManagerFrame)
	end
	for _, child in ipairs({ UIParent:GetChildren() }) do
		if not windows[child] and IsEditModeWindow(child) then
			Track(child)
		end
	end
end

local function RefreshAll()
	for window in pairs(windows) do
		if window:IsVisible() then
			Refresh(window)
		end
	end
end

local function ScanIfOpen()
	if IsEditModeOpen() then
		Scan()
		RefreshAll()
	end
end

-- CMC makes a new window every selection, catch it before it draws
local function HookWindowOpeners()
	if EditModeSystemSettingsDialog and EditModeSystemSettingsDialog.AttachToSystemFrame then
		hooksecurefunc(EditModeSystemSettingsDialog, "AttachToSystemFrame", ScanIfOpen)
	end
	if not LibStub then
		return
	end
	for _, libName in ipairs({ "WilduEditModeLib-1.0", "LibEQOLEditMode-1.0", "LibEditMode" }) do
		local lib = LibStub(libName, true)
		if lib then
			for _, method in ipairs({ "ShowAttachedSettingsPanel", "ShowStandaloneSettingsDialog" }) do
				if type(lib[method]) == "function" then
					hooksecurefunc(lib, method, ScanIfOpen)
				end
			end
		end
	end
end

local driver = CreateFrame("Frame")
local sinceScan = SCAN_INTERVAL
local wasOpen = false

local function LogSummary()
	local tracked, visible = 0, 0
	for window in pairs(windows) do
		tracked = tracked + 1
		if window:IsVisible() then
			visible = visible + 1
		end
	end
	Log("%d windows tracked, %d showing, %d bars made, %d spare", tracked, visible, pairsMade, #sparePairs)
end

driver:SetScript("OnUpdate", function(_, elapsed)
	local open = IsEditModeOpen()
	if open ~= wasOpen then
		wasOpen = open
		Log(open and "edit mode opened" or "edit mode closed")
		LogSummary()
	end
	if not open then
		sinceScan = SCAN_INTERVAL
		return
	end
	sinceScan = sinceScan + elapsed
	if sinceScan >= SCAN_INTERVAL then
		sinceScan = 0
		Scan()
		RefreshAll()
		return
	end
	-- cheap checks only, the rest waits for the next scan
	for window, state in pairs(windows) do
		if window:IsShown() then
			RestorePosition(window)
			local title = TitleOf(window)
			if title ~= state.title then
				state.title = title
				Refresh(window)
			end
		end
	end
end)

driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_LOGIN")
driver:SetScript("OnEvent", function(self, event, loadedAddon)
	if event == "PLAYER_LOGIN" then
		HookWindowOpeners() -- after theirs
	elseif loadedAddon == ADDON_NAME then
		EditModeWindowShadingDB = EditModeWindowShadingDB or {}
		db = EditModeWindowShadingDB
		db.positions = db.positions or {}
		db.collapsed = db.collapsed or {} -- rolled up titles
		db.log = db.log or {}
		self:UnregisterEvent("ADDON_LOADED")
	end
end)

SLASH_EDITMODEWINDOWSHADING1 = "/ws"
SlashCmdList.EDITMODEWINDOWSHADING = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "reset" then
		wipe(db.positions)
		wipe(db.collapsed)
		print("Edit Mode Window Shading: saved spots and rolled-up windows cleared (reopen Edit Mode).")
	elseif msg == "log on" or msg == "log off" then
		db.logging = msg == "log on" or nil
		print("Edit Mode Window Shading: log " .. (db.logging and "on" or "off") .. ".")
	elseif msg == "log clear" then
		wipe(db.log)
		print("Edit Mode Window Shading: log cleared.")
	elseif msg == "log" then
		for i = math.max(1, #db.log - 19), #db.log do
			print(db.log[i])
		end
	elseif msg == "debug" then
		for window, state in pairs(windows) do
			print(("%s | %s | visible %s | mouse %s | rolled up %s | bar %s"):format(
				window:GetName() or tostring(window),
				tostring(TitleOf(window)),
				tostring(window:IsVisible()),
				tostring(window:IsMouseEnabled()),
				tostring(IsRolledUp(window)),
				tostring(state.pair ~= nil and state.pair.bar:IsShown())
			))
		end
	else
		print("Edit Mode Window Shading: double-click a window's title or click its arrow to roll it up.")
		print("/ws reset clears saved spots, /ws debug lists tracked windows.")
		print("/ws log on|off|clear, /ws log shows the last 20 lines.")
	end
end
