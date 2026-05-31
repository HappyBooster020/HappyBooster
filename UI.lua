--[[----------------------------------------------------------------------------
    HappyBooster - UI.lua
    The main window: a draggable, escape-closable panel that lists tracked
    players with live counts and per-row controls, plus mode toggle, settings
    checkboxes, and footer actions. No external libraries.
------------------------------------------------------------------------------]]

local addonName, HB = ...

local UI = {}
HB.UI = UI

local WIDTH, HEIGHT = 360, 376
local ROW_H, NUM_ROWS = 26, 9
local LIST_W = WIDTH - 40
local SETTINGS_W, SETTINGS_H = 340, 536  -- bumped for the Restore Defaults button

local BACKDROP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function MakeButton(parent, w, h, text)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h)
    b:SetText(text)
    return b
end

local function MakeCheck(parent, label, tooltip)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(22, 22)
    local fs = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", c, "RIGHT", 1, 0)
    fs:SetText(label)
    c.label = fs
    if tooltip then
        c:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label, 1, 1, 1)
            GameTooltip:AddLine(tooltip, 1, 0.82, 0, true)
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return c
end

-- Chat feedback for a settings checkbox toggle. We print the setting name,
-- the new ON/OFF state in green/red, and a one-line explanation of what the
-- new state actually does. Same helper used for every checkbox so the
-- phrasing stays consistent.
local function announceCheck(name, on, effectOn, effectOff)
    if HB and HB.Print then
        local state = on and "|cFF60FF60ON|r" or "|cFFFF6060OFF|r"
        HB:Print("%s: %s -- %s", name, state, on and effectOn or effectOff)
    end
end

-- ----------------------------------------------------------------------------
-- Build (lazy, once)
-- ----------------------------------------------------------------------------
function UI:Build()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "HappyBoosterWindow", UIParent, "BackdropTemplate")
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    if f.SetBackdrop then
        f:SetBackdrop(BACKDROP)
        f:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
        f:SetBackdropBorderColor(0.6, 0.5, 0.1, 1)
    end

    -- position
    local w = HB.db.window
    f:SetPoint(w.point or "CENTER", UIParent, w.relPoint or "CENTER", w.x or 0, w.y or 0)

    -- drag
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        HB.db.window.point, HB.db.window.relPoint = point, relPoint
        HB.db.window.x, HB.db.window.y = x, y
    end)

    -- escape-closable
    tinsert(UISpecialFrames, "HappyBoosterWindow")

    -- title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cFFFFD700Happy|rBooster")

    -- close button
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() UI:Hide() end)

    -- mode toggle (per-character; HB:SetMode writes to modeByChar[selfKey]).
    local mode = MakeButton(f, 150, 22, "")
    mode:SetPoint("TOPLEFT", 16, -34)
    mode:SetScript("OnClick", function(self)
        HB:SetMode(HB:IsBoosted() and "booster" or "boosted")
        self:SetText(HB:IsBoosted() and "Mode: BOOSTED" or "Mode: BOOSTER")
        HB:Print("Mode: |cFFFFD700%s|r", HB:IsBoosted() and "BOOSTED" or "BOOSTER")
        HB:Changed()
    end)
    f.modeBtn = mode

    -- add target (booster mode) / add runs (boosted mode). The label is
    -- updated mode-aware in Refresh().
    local addBtn = MakeButton(f, 150, 22, "Add Target")
    addBtn:SetPoint("TOPRIGHT", -16, -34)
    addBtn:SetScript("OnClick", function() UI:AddTarget() end)
    f.addBtn = addBtn

    -- settings cog (top-right of header)
    local cog = MakeButton(f, 80, 20, "Settings")
    cog:SetPoint("TOPRIGHT", -36, -8)
    cog:SetScript("OnClick", function()
        if f.settings:IsShown() then f.settings:Hide(); return end
        -- Smart-pick the side that fits on-screen: right of main, else left of
        -- main, else below. Falls back to right if measurements unavailable.
        local panel = f.settings
        local screenW = UIParent:GetWidth() or 1920
        local mainRight = f:GetRight() or 0
        local mainLeft  = f:GetLeft()  or 0
        local panelW    = panel:GetWidth() or 320
        panel:ClearAllPoints()
        if (screenW - mainRight) >= (panelW + 10) then
            panel:SetPoint("TOPLEFT",  f, "TOPRIGHT",   6, 0)   -- right side
        elseif mainLeft >= (panelW + 10) then
            panel:SetPoint("TOPRIGHT", f, "TOPLEFT",   -6, 0)   -- left side
        else
            panel:SetPoint("TOPLEFT",  f, "BOTTOMLEFT", 0, -6)  -- below
        end
        panel:Show(); UI:Refresh(); UI:RefreshPrices()
    end)
    f.settingsBtn = cog

    -- Announce button (top-left of header, mirroring Settings on the right).
    -- One-click broadcast to party/raid chat.
    --   BOOSTER -- posts each tracked customer's remaining runs.
    --   BOOSTED -- posts YOUR remaining runs so the booster knows where you
    --              stand without having to ask.
    local announceBtn = MakeButton(f, 80, 20, "Announce")
    announceBtn:SetPoint("TOPLEFT", 10, -8)
    announceBtn:SetScript("OnClick", function()
        HB:AnnounceStandings(HB.lastDungeon, false)
    end)
    announceBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Announce", 1, 1, 1)
        GameTooltip:AddLine(" ")
        if HB:IsBoosted() then
            GameTooltip:AddLine("Tells the group how many runs you have left.",
                                1, 0.82, 0, true)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click when you want your booster to know " ..
                                "(e.g. \"last run!\" or \"out of runs\").",
                                0.85, 0.85, 0.85, true)
        else
            GameTooltip:AddLine("Posts each customer's remaining runs to party/raid chat.",
                                1, 0.82, 0, true)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click when you want to share the standings " ..
                                "(e.g. a customer asks how many runs they have left).",
                                0.85, 0.85, 0.85, true)
        end
        GameTooltip:Show()
    end)
    announceBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.announceBtn = announceBtn

    -- column header
    local colHdr = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    colHdr:SetPoint("TOPLEFT", 18, -62)
    colHdr:SetText("Player")
    f.colHdr = colHdr
    local colHdr2 = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    colHdr2:SetPoint("TOPLEFT", 150, -62)
    colHdr2:SetText("Left")

    -- list container
    local list = CreateFrame("Frame", nil, f)
    list:SetPoint("TOPLEFT", 14, -76)
    list:SetSize(LIST_W, ROW_H * NUM_ROWS)
    f.list = list

    -- scroll
    local scroll = CreateFrame("ScrollFrame", "HappyBoosterScroll", f, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -2, 0)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function() UI:Refresh() end)
    end)
    f.scroll = scroll

    -- rows
    f.rows = {}
    for i = 1, NUM_ROWS do
        local row = CreateFrame("Frame", nil, list)
        row:SetSize(LIST_W, ROW_H)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.04)
        if i % 2 == 0 then bg:SetColorTexture(1, 1, 1, 0.07) end
        row.bg = bg

        -- Name field as a clickable button. Click toggles the pin state for
        -- this customer. Pinned customers' names show in gold, unpinned in
        -- the default highlight color. No separate icon clutter.
        local nameBtn = CreateFrame("Button", nil, row)
        nameBtn:SetPoint("LEFT", 4, 0)
        nameBtn:SetSize(130, ROW_H - 2)
        local nameFS = nameBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        nameFS:SetAllPoints()
        nameFS:SetJustifyH("LEFT")
        row.name = nameFS         -- the fontstring stays as row.name for SetText compat
        row.nameBtn = nameBtn     -- the button is wired up in Refresh

        local count = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        count:SetPoint("LEFT", 136, 0)
        count:SetWidth(56)
        count:SetJustifyH("LEFT")
        row.count = count

        local rem = MakeButton(row, 22, 20, "-")
        rem:SetPoint("LEFT", 196, 0)
        row.minus = rem

        local add = MakeButton(row, 22, 20, "+")
        add:SetPoint("LEFT", 220, 0)
        row.plus = add

        local set = MakeButton(row, 40, 20, "Set")
        set:SetPoint("LEFT", 244, 0)
        row.set = set

        local del = MakeButton(row, 22, 20, "X")
        del:SetPoint("LEFT", 286, 0)
        row.del = del

        f.rows[i] = row
        row:Hide()
    end

    -- empty hint
    local empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("CENTER", list, "CENTER", 0, 0)
    empty:SetWidth(LIST_W - 20)
    empty:SetText("No one tracked yet.\nTrade a customer, or use \"Add Target\".")
    f.empty = empty

    -- ----- Settings panel (a separate frame, hidden until you click Settings)
    local settings = CreateFrame("Frame", "HappyBoosterSettings", UIParent, "BackdropTemplate")
    settings:SetSize(SETTINGS_W, SETTINGS_H)
    settings:SetFrameStrata("HIGH")
    settings:SetClampedToScreen(true)
    settings:SetMovable(true); settings:EnableMouse(true); settings:RegisterForDrag("LeftButton")
    settings:SetScript("OnDragStart", settings.StartMoving)
    settings:SetScript("OnDragStop",  settings.StopMovingOrSizing)
    settings:SetBackdrop(BACKDROP)
    settings:SetBackdropColor(0, 0, 0, 0.92)
    settings:SetPoint("TOPLEFT", f, "TOPRIGHT", 6, 0)
    settings:Hide()
    local stitle = settings:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    stitle:SetPoint("TOP", 0, -12); stitle:SetText("|cFFFFD700Settings|r")
    local sclose = CreateFrame("Button", nil, settings, "UIPanelCloseButton")
    sclose:SetPoint("TOPRIGHT", -2, -2)
    sclose:SetScript("OnClick", function() settings:Hide() end)
    f.settings = settings

    local cb1 = MakeCheck(settings, "On-frame numbers",
        "Show the count overlay on each party/raid frame.")
    cb1:SetPoint("TOPLEFT", 16, -40)
    cb1:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        HB.db.settings.showOnFrames = on
        HB:UpdateAllFrames()
        announceCheck("On-frame numbers", on,
            "pill badges shown on party/raid frames.",
            "pill badges hidden.")
    end)
    f.cbFrames = cb1

    local cb2 = MakeCheck(settings, "Prompt after trade",
        "Pop up a window after a trade so you can confirm how many runs were paid for.")
    cb2:SetPoint("TOPLEFT", cb1, "BOTTOMLEFT", 0, -4)
    cb2:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        HB.db.settings.autoPrompt = on
        announceCheck("Prompt after trade", on,
            "popup appears after each trade so you can confirm runs.",
            "no popup after trades -- use Add Target or +/- buttons manually.")
    end)
    f.cbPrompt = cb2

    local cb3 = MakeCheck(settings, "Require boss kill to count a run",
        "Strict mode: a run only counts if a boss died. " ..
        "Off by default since boosting is often trash-only.")
    cb3:SetPoint("TOPLEFT", cb2, "BOTTOMLEFT", 0, -4)
    cb3:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        HB.db.settings.requireBossKill = on
        announceCheck("Require boss kill", on,
            "runs only count if a boss died (strict mode).",
            "runs count even if no boss died (good for trash farming).")
    end)
    f.cbBoss = cb3

    local cb4 = MakeCheck(settings, "Count down (off = count up)",
        "On: pill shows remaining runs (5,4,3...). Off: pill shows runs completed (0,1,2...).")
    cb4:SetPoint("TOPLEFT", cb3, "BOTTOMLEFT", 0, -4)
    cb4:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        HB.db.settings.countDown = on
        announceCheck("Count direction", on,
            "counting DOWN -- pill shows runs remaining (5,4,3...).",
            "counting UP -- pill shows runs completed (0,1,2...).")
        HB:Changed()
    end)
    f.cbDir = cb4

    local cb5 = MakeCheck(settings, "Only prompt when gold was traded",
        "Skip the run-count popup if the trade contained no money (item-only trades).")
    cb5:SetPoint("TOPLEFT", cb4, "BOTTOMLEFT", 0, -4)
    cb5:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        HB.db.settings.promptOnGoldOnly = on
        announceCheck("Gold-only prompt", on,
            "skip popup when no gold changed hands (item-only trades).",
            "popup appears after any trade, gold or not.")
    end)
    f.cbGold = cb5

    local cb7 = MakeCheck(settings, "Auto-open window after a trade",
        "Briefly open the window after a trade completes so you can see updated counts.")
    cb7:SetPoint("TOPLEFT", cb5, "BOTTOMLEFT", 0, -4)
    cb7:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        HB.db.settings.autoOpenAfterTrade = on
        announceCheck("Auto-open after trade", on,
            "window opens briefly after each trade.",
            "window stays as-is after trades.")
    end)
    f.cbAutoOpen = cb7

    local cb8 = MakeCheck(settings, "Open window when entering a dungeon",
        "Opens the window automatically when you enter a dungeon.\n" ..
        "BOOSTER: only if a tracked customer is in your group.\n" ..
        "BOOSTED: always (your own counter is always relevant).")
    cb8:SetPoint("TOPLEFT", cb7, "BOTTOMLEFT", 0, -4)
    cb8:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        HB.db.settings.autoOpenOnEnter = on
        announceCheck("Auto-open on dungeon entry", on,
            "window opens when you zone into a dungeon.",
            "window stays as-is when entering a dungeon.")
    end)
    f.cbAutoOpenEnter = cb8

    -- Auto-announce in BOOSTED mode. Only fires at the two moments the
    -- booster actually cares about (1 left = "last one!", 0 left = "out!"),
    -- never on every run, so it doesn't flood chat. Off by default.
    local cb9 = MakeCheck(settings, "Auto-announce 'last run' and 'out of runs'",
        "Boosted mode only. Posts to party/raid automatically when you have 1 run left (so the booster knows it's the last one) and again when you hit 0 (so they know to ask for a trade). Silent on every other run -- no chat spam.")
    cb9:SetPoint("TOPLEFT", cb8, "BOTTOMLEFT", 0, -4)
    cb9:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        HB.db.settings.autoAnnounce = on
        announceCheck("Auto-announce (boosted mode)", on,
            "chat post when you hit 1 run left, again at 0.",
            "no automatic chat messages.")
    end)
    f.cbAutoAnnounce = cb9

    -- ---- Prices section in the Settings panel.
    -- A scrollable list of currently-configured dungeon prices, plus a row to
    -- add a new dungeon, plus a "Use current dungeon" quick button when you're
    -- inside an instance. The entire section is hidden in BOOSTED mode (you
    -- don't set prices when you're the one buying boosts); f.priceWidgets
    -- holds every widget so Refresh() can show/hide them as a group.
    -- Anchor everything to the settings panel directly so layout math is sane.
    f.priceWidgets = {}
    local function addPrice(w) f.priceWidgets[#f.priceWidgets + 1] = w end

    local sep = settings:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.4)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", cb9, "BOTTOMLEFT", 0, -10)
    sep:SetPoint("RIGHT", settings, "RIGHT", -16, 0)
    addPrice(sep)

    local pTitle = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pTitle:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -6)
    pTitle:SetText("|cFFFFD700Prices|r (per run)")
    addPrice(pTitle)

    -- Scroll frame for the price list. Width = panel - left padding (16) -
    -- right padding (16) - scrollbar gutter (22).
    local scroll = CreateFrame("ScrollFrame", "HappyBoosterPriceScroll",
                               settings, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", pTitle, "BOTTOMLEFT", 0, -4)
    scroll:SetSize(SETTINGS_W - 54, 110)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(SETTINGS_W - 54, 110)
    scroll:SetScrollChild(content)
    f.priceScroll = scroll
    f.priceContent = content
    f.priceRows = {}
    addPrice(scroll)

    -- Add-row controls under the scroll. Edit-box widths picked so they all
    -- fit inside the panel together: name (140) + gold (44) + Add (44).
    local addLbl = settings:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    addLbl:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -8)
    addLbl:SetText("Add a dungeon")
    addPrice(addLbl)

    local nameEdit = CreateFrame("EditBox", nil, settings, "InputBoxTemplate")
    nameEdit:SetPoint("TOPLEFT", addLbl, "BOTTOMLEFT", 6, -4)
    nameEdit:SetSize(140, 20); nameEdit:SetAutoFocus(false)
    f.priceNameEdit = nameEdit
    addPrice(nameEdit)

    local goldEdit = CreateFrame("EditBox", nil, settings, "InputBoxTemplate")
    goldEdit:SetPoint("LEFT", nameEdit, "RIGHT", 12, 0)
    goldEdit:SetSize(44, 20); goldEdit:SetAutoFocus(false); goldEdit:SetNumeric(false)
    f.priceGoldEdit = goldEdit
    addPrice(goldEdit)

    local goldLbl = settings:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    goldLbl:SetPoint("LEFT", goldEdit, "RIGHT", 2, 0)
    goldLbl:SetText("g")
    addPrice(goldLbl)

    local addBtnP = MakeButton(settings, 44, 22, "Add")
    addBtnP:SetPoint("LEFT", goldLbl, "RIGHT", 4, 0)
    addBtnP:SetScript("OnClick", function()
        local name = nameEdit:GetText()
        local g    = tonumber(goldEdit:GetText())
        if not name or name == "" then HB:Print("Enter a dungeon name."); return end
        if not g or g < 0 then HB:Print("Enter gold as a number (e.g. 12 or 12.5)."); return end
        HB:SetPrice(name, math.floor(g * 10000 + 0.5))
        nameEdit:SetText(""); goldEdit:SetText("")
        HB:Print("Price set: |cFFFFD700%s|r = %s/run", name, HB:FormatMoney(math.floor(g*10000+0.5)))
        UI:RefreshPrices()
    end)
    addPrice(addBtnP)

    -- "Use current dungeon" button: anchored to BOTH left and right of the
    -- panel inset so it cannot overhang the right edge no matter what.
    local useCurr = MakeButton(settings, 0, 22, "Use current dungeon's name")
    useCurr:SetPoint("TOPLEFT", nameEdit, "BOTTOMLEFT", -6, -8)
    useCurr:SetPoint("RIGHT", settings, "RIGHT", -16, 0)
    useCurr:SetScript("OnClick", function()
        local d = HB:GetActiveDungeon()
        if d and d ~= "" then nameEdit:SetText(d); goldEdit:SetFocus()
        else HB:Print("No active dungeon. Enter inside one first.") end
    end)
    useCurr:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local d = HB:GetActiveDungeon() or "(none yet)"
        GameTooltip:SetText("Current dungeon: " .. d, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    useCurr:SetScript("OnLeave", function() GameTooltip:Hide() end)
    addPrice(useCurr)

    -- Restore Defaults button. Anchored to the panel's bottom-right so it's
    -- always visible regardless of which sections are hidden (the Prices
    -- group is hidden in BOOSTED mode). Hover shows the actual default
    -- values without forcing a reset; clicking opens a confirm popup.
    local restoreBtn = MakeButton(settings, 130, 22, "Restore Defaults")
    restoreBtn:SetPoint("BOTTOMRIGHT", settings, "BOTTOMRIGHT", -16, 10)
    restoreBtn:SetScript("OnClick", function()
        StaticPopup_Show("HAPPYBOOSTER_RESTORE_DEFAULTS")
    end)
    restoreBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:SetText("Restore Defaults", 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Resets the 8 settings checkboxes above. " ..
                            "Tracked customers, prices, and stats stay unchanged.",
                            1, 0.82, 0, true)
        GameTooltip:AddLine(" ")
        local d = HB.defaults.settings
        local function row(label, on)
            local mark = on and "|cFF60FF60[x]|r" or "|cFFFF6060[ ]|r"
            GameTooltip:AddLine(mark .. " " .. label, 1, 1, 1)
        end
        GameTooltip:AddLine("Defaults:", 1, 0.82, 0)
        row("On-frame numbers",                  d.showOnFrames)
        row("Prompt after trade",                d.autoPrompt)
        row("Require boss kill to count a run",  d.requireBossKill)
        row("Count down (off = count up)",       d.countDown)
        row("Only prompt when gold was traded",  d.promptOnGoldOnly)
        row("Auto-open window after a trade",    d.autoOpenAfterTrade)
        row("Open window when entering a dungeon", d.autoOpenOnEnter)
        row("Auto-announce 'last run' / 'out'",  d.autoAnnounce)
        GameTooltip:Show()
    end)
    restoreBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- footer actions
    local countRun = MakeButton(f, 104, 24, "Count Run")
    countRun:SetPoint("BOTTOMLEFT", 14, 14)
    countRun:SetScript("OnClick", function()
        if HB.CancelPendingLeave then HB:CancelPendingLeave("window Count Run") end
        local n = HB:DecrementGroup("window: Count Run")
        if n > 0 then
            -- Walk the current group and list each tracked member with their
            -- new count. Capped at 5 entries to keep the line readable; the
            -- DecrementGroup zero-alerts already fire separately for any 0s.
            local selfKey = HB:GetUnitKey("player")
            local parts = {}
            for _, t in ipairs(HB:GetGroupTargets()) do
                local rem = HB:GetCount(t.key)
                if rem ~= nil then
                    local label = (t.key == selfKey) and "You" or HB:PrettyName(t.key)
                    parts[#parts + 1] = ("%s (%s)"):format(
                        label, rem == 0 and "DONE" or tostring(rem))
                end
            end
            if #parts > 0 and #parts <= 5 then
                HB:Print("Counted 1 run -- %s.", table.concat(parts, ", "))
            else
                HB:Print("Counted 1 run (%d affected).", n)
            end
        else
            HB:Print("No tracked players in your group to count.")
        end
    end)
    countRun:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Count Run (manual)", 1, 1, 1)
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("Subtracts 1 run from every tracked player in your group.", 1, 0.82, 0, true)
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("Use this when:", 1, 1, 1)
        GameTooltip:AddLine("- A real run finished but the addon didn't notice it.", 0.85, 0.85, 0.85, true)
        GameTooltip:AddLine("- You did the dungeon after a DC and the addon missed counting.", 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    countRun:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local resetAll = MakeButton(f, 90, 24, "Clear list")
    resetAll:SetPoint("BOTTOMLEFT", countRun, "BOTTOMRIGHT", 6, 0)
    resetAll:SetScript("OnClick", function()
        StaticPopup_Show("HAPPYBOOSTER_CONFIRM_RESETALL", HB:IsBoosted() and "your run count" or "all customer entries")
    end)
    resetAll:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local what = HB:IsBoosted() and "your own run count" or "all customer entries"
        GameTooltip:SetText("Clear list", 1, 1, 1)
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("Permanently removes " .. what .. " (the current mode). " ..
                            "The other mode's data is kept.", 1, 0.82, 0, true)
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("Use /hb wipe to clear both modes at once.", 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    resetAll:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local undo = MakeButton(f, 60, 24, "Undo")
    undo:SetPoint("BOTTOMLEFT", resetAll, "BOTTOMRIGHT", 6, 0)
    undo:SetScript("OnClick", function() UI:UndoRun() end)
    undo:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Undo last Count Run", 1, 1, 1)
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("Adds 1 run back to everyone who was last decremented.", 1, 0.82, 0, true)
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("Use this when the addon counted a run that didn't really happen:", 1, 1, 1)
        GameTooltip:AddLine("- Died and released outside the instance.", 0.85, 0.85, 0.85, true)
        GameTooltip:AddLine("- HS'd out for repair and came back.", 0.85, 0.85, 0.85, true)
        GameTooltip:AddLine("- Any false count you see in chat.", 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    undo:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Session footer: one small dim line above the buttons showing total runs
    -- and gold earned this session. Updated by Refresh.
    local sessionFooter = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sessionFooter:SetPoint("BOTTOMLEFT", 14, 44)
    sessionFooter:SetText("")
    f.sessionFooter = sessionFooter

    StaticPopupDialogs["HAPPYBOOSTER_CONFIRM_RESETALL"] = {
        text = "Clear |cFFFFD700%s|r?",
        button1 = YES, button2 = NO,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        OnAccept = function()
            local what = HB:IsBoosted() and "your run count" or "customer entries"
            HB:ResetAll()
            HB:Print("Cleared %s.", what)
        end,
    }

    -- Restore Defaults confirmation. Resets only the 8 settings checkboxes;
    -- runs/stats/prices/mode are untouched. The user can hover the button
    -- to see the defaults before confirming, so this popup is short.
    StaticPopupDialogs["HAPPYBOOSTER_RESTORE_DEFAULTS"] = {
        text = "Reset all settings to defaults?\n\n" ..
               "Resets only the checkboxes on the Settings panel.\n" ..
               "Tracked customers, prices, and stats stay unchanged.",
        button1 = "Reset", button2 = "Cancel",
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        OnAccept = function()
            local d = HB.defaults.settings
            HB.db.settings.showOnFrames       = d.showOnFrames
            HB.db.settings.autoPrompt         = d.autoPrompt
            HB.db.settings.requireBossKill    = d.requireBossKill
            HB.db.settings.countDown          = d.countDown
            HB.db.settings.promptOnGoldOnly   = d.promptOnGoldOnly
            HB.db.settings.autoOpenAfterTrade = d.autoOpenAfterTrade
            HB.db.settings.autoOpenOnEnter    = d.autoOpenOnEnter
            HB.db.settings.autoAnnounce       = d.autoAnnounce
            HB:Print("Settings reset to defaults.")
            UI:Refresh()
            if HB.UpdateAllFrames then HB:UpdateAllFrames() end
        end,
    }

    self.frame = f
    return f
end

-- ----------------------------------------------------------------------------
-- Data helpers
-- ----------------------------------------------------------------------------
function UI:BuildDisplayList()
    local list = {}
    local selfKey = HB:GetUnitKey("player")
    local boosted = HB:IsBoosted()
    if boosted then
        -- BOOSTED mode shows exactly one row: yours. Synthesize at 0 runs
        -- when the DB has no entry yet (first time in BOOSTED mode, or after
        -- Clear), so the user always sees their tracker without an empty hint.
        if selfKey then
            local e = HB.db.runs[selfKey]
            list[#list + 1] = {
                key = selfKey,
                remaining = (e and e.remaining) or 0,
                total = (e and e.total) or 0,
            }
        end
        return list
    end
    -- BOOSTER mode: everyone tracked except the player AND except any of
    -- this account's other known characters (their boosted self-rows aren't
    -- customers, just data for those alts when you play them).
    for key, e in pairs(HB.db.runs) do
        if key ~= selfKey and not HB:IsKnownAlt(key) then
            list[#list + 1] = { key = key, remaining = e.remaining or 0, total = e.total or 0 }
        end
    end
    -- Alphabetical sort. Rows are stable when you bump counts up or down,
    -- so you don't have to chase them around the list. The 0-run rows get a
    -- red-tinted background in Refresh() so they still stand out at a glance.
    table.sort(list, function(a, b) return a.key < b.key end)
    return list
end

-- Header button click. Two behaviors depending on mode:
--   BOOSTER  -- adds your current target as a tracked customer, then opens the
--              run-input popup so you can type how many runs they paid for.
--   BOOSTED  -- opens a simple "Add N runs to your counter" popup (no target
--              needed; the booster's identity doesn't matter to the tracker).
function UI:AddTarget()
    if HB:IsBoosted() then
        local selfKey = HB:GetUnitKey("player")
        if not selfKey then HB:Print("Couldn't read your name."); return end
        local existing = HB:GetCount(selfKey) or 0
        -- We reuse the trade-popup pathway in additive mode so a fresh batch
        -- and a top-up both work. The popup pre-fills with defaultRuns and is
        -- editable.
        StaticPopupDialogs["HAPPYBOOSTER_RUN_INPUT"].text = (existing > 0)
            and ("You have |cFFFFD700" .. existing .. "|r runs left.\nAdd how many MORE?")
            or "Add how many runs to your counter?"
        StaticPopup_Show("HAPPYBOOSTER_RUN_INPUT",
                         HB:PrettyName(selfKey), nil,
                         { key = selfKey, copper = 0, mode = "trade",
                           suggest = HB.db.settings.defaultRuns or 5 })
        return
    end

    -- Booster-mode behavior (unchanged from previous versions).
    if not UnitExists("target") then
        HB:Print("No target. Click a player first, then press |cffffff00Add Target|r.")
        return
    end
    if not UnitIsPlayer("target") then
        HB:Print("Target must be a player (not a pet or NPC).")
        return
    end
    if UnitIsUnit("target", "player") then
        HB:Print("That's you. Pick a customer to track.")
        return
    end
    local key = HB:GetUnitKey("target")
    if not key then HB:Print("Couldn't read target's name."); return end

    local existing, total = HB:GetCount(key)
    if existing ~= nil then
        HB:Print("|cFFFFD700%s|r is already tracked (%d/%d left). " ..
                 "Use the |cffffff00Set|r button on their row to change it, " ..
                 "or trade them to add more runs.",
                 HB:PrettyName(key), existing, total or existing)
        return
    end
    HB:PromptSetRuns(key, HB.db.settings.defaultRuns or 5)
end

-- Undo: re-add 1 run to whoever was decremented by the most recent run event.
function UI:UndoRun()
    local h = HB.db.history
    for i = #h, 1, -1 do
        if h[i].type == "run" then
            -- We didn't store exact members, so re-add to current group targets.
            local delta = HB.db.settings.countDown and 1 or -1
            local selfKey = HB:GetUnitKey("player")
            local parts = {}
            for _, t in ipairs(HB:GetGroupTargets()) do
                if HB.db.runs[t.key] then
                    HB:AdjustCount(t.key, delta, true)  -- silent: we emit one summary line below
                    local rem = HB:GetCount(t.key)
                    if rem ~= nil then
                        local label = (t.key == selfKey) and "You" or HB:PrettyName(t.key)
                        parts[#parts + 1] = ("%s (%s)"):format(label, tostring(rem))
                    end
                end
            end
            table.remove(h, i)
            if #parts > 0 and #parts <= 5 then
                HB:Print("Undid last run -- restored: %s.", table.concat(parts, ", "))
            else
                HB:Print("Undid last run count.")
            end
            return
        end
    end
    HB:Print("Nothing to undo.")
end

-- ----------------------------------------------------------------------------
-- Refresh
-- ----------------------------------------------------------------------------
function UI:Refresh()
    local f = self.frame
    if not f or not f:IsShown() then return end

    -- header / settings state
    local boosted = HB:IsBoosted()
    f.modeBtn:SetText(boosted and "Mode: BOOSTED" or "Mode: BOOSTER")
    if f.addBtn then f.addBtn:SetText(boosted and "Add Runs" or "Add Target") end
    if f.colHdr then f.colHdr:SetText(boosted and "You" or "Customer") end
    f.cbFrames:SetChecked(HB.db.settings.showOnFrames)
    f.cbPrompt:SetChecked(HB.db.settings.autoPrompt)
    f.cbBoss:SetChecked(HB.db.settings.requireBossKill)
    f.cbDir:SetChecked(HB.db.settings.countDown)
    f.cbGold:SetChecked(HB.db.settings.promptOnGoldOnly)
    if f.cbAutoOpen then f.cbAutoOpen:SetChecked(HB.db.settings.autoOpenAfterTrade) end
    if f.cbAutoOpenEnter then f.cbAutoOpenEnter:SetChecked(HB.db.settings.autoOpenOnEnter) end
    if f.cbAutoAnnounce then f.cbAutoAnnounce:SetChecked(HB.db.settings.autoAnnounce) end

    -- Settings panel: the Prices section is only meaningful in booster mode.
    -- In boosted mode (you don't set the prices, your booster does) we hide
    -- the entire Prices block.
    if f.priceWidgets then
        for _, w in ipairs(f.priceWidgets) do w:SetShown(not boosted) end
    end
    if f.settings and f.settings:IsShown() then self:RefreshPrices() end

    -- Session footer. In booster mode we show runs + gold earned. In boosted
    -- mode the user said they don't need all the extra info, so just runs.
    if f.sessionFooter then
        local sess = HB.db.session or {}
        local runs = sess.runs or 0
        if boosted then
            if runs == 0 then
                f.sessionFooter:SetText("")
            else
                f.sessionFooter:SetText(("Session:  %d run%s completed"):format(
                    runs, runs == 1 and "" or "s"))
            end
        else
            local copper = sess.copperReceived or 0
            if runs == 0 and copper == 0 then
                f.sessionFooter:SetText("")
            else
                f.sessionFooter:SetText(("Session:  %d run%s completed  -  %s earned"):format(
                    runs, runs == 1 and "" or "s", HB:FormatMoney(copper)))
            end
        end
    end

    local data = self:BuildDisplayList()
    -- BOOSTED mode always shows a self row, so the empty hint never fires.
    f.empty:SetShown(#data == 0 and not boosted)

    FauxScrollFrame_Update(f.scroll, #data, NUM_ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(f.scroll)

    for i = 1, NUM_ROWS do
        local row = f.rows[i]
        local idx = i + offset
        local entry = data[idx]
        if entry then
            local key = entry.key
            -- Name color: pinned customers in gold, others default white.
            -- Pinning doesn't really apply to the BOOSTED self-row but the
            -- tooltip hides the hint and the click is harmless.
            local pinned = HB:IsPinned(key)
            local nameColor = pinned and "|cFFFFD700" or "|cFFFFFFFF"
            row.name:SetText(nameColor .. HB:PrettyName(key) .. "|r")

            local txt
            if HB.db.settings.countDown then
                txt = string.format("%d / %d", entry.remaining, entry.total)
            else
                txt = tostring(entry.remaining)
            end
            -- Row background tint: rows at 0 runs glow red so they pop out.
            -- Other rows keep the alternating-stripe shading from Build().
            if entry.remaining <= 0 and HB.db.settings.countDown then
                row.count:SetText("|cFFFF4444" .. txt .. "|r")
                row.bg:SetColorTexture(0.55, 0.10, 0.10, 0.28)  -- red tint
            else
                row.count:SetText("|cFFFFD700" .. txt .. "|r")
                -- Restore the alternating-stripe shading set up in Build().
                if i % 2 == 0 then
                    row.bg:SetColorTexture(1, 1, 1, 0.07)
                else
                    row.bg:SetColorTexture(1, 1, 1, 0.04)
                end
            end
            row.minus:SetScript("OnClick", function() HB:AdjustCount(key, -1) end)
            row.plus:SetScript("OnClick",  function() HB:AdjustCount(key,  1) end)
            row.set:SetScript("OnClick",   function() HB:PromptSetRuns(key, entry.total) end)
            row.del:SetScript("OnClick",   function() HB:ResetPlayer(key) end)
            -- In BOOSTED mode the self-row is permanent (BuildDisplayList
            -- recreates it). Hide the X to avoid the user thinking they
            -- can delete their own tracker.
            row.del:SetShown(not boosted)
            -- Click the name to toggle pin (booster only). Tooltip differs.
            row.nameBtn:SetScript("OnClick", function()
                if boosted then return end  -- no pin in boosted mode
                HB:TogglePin(key); HB:Changed()
            end)
            row.nameBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(HB:PrettyName(key), 1, 0.84, 0)
                if boosted then
                    -- Minimal tooltip: just the run count. No gold math
                    -- (you already paid), no pin hint (only one row).
                    GameTooltip:AddLine(
                        ("Runs left:  |cFFFFFFFF%d|r"):format(entry.remaining),
                        1, 0.82, 0)
                    if entry.remaining <= 0 then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine("All done! Click |cffffff00Add Runs|r when you buy more.",
                                            0.85, 0.85, 0.85, true)
                    end
                else
                    if pinned then
                        GameTooltip:AddLine("|cFFFFD700Pinned|r -- survives Clear list.", 1, 1, 1, true)
                        GameTooltip:AddLine("Click name to unpin.", 0.85, 0.85, 0.85, true)
                    else
                        GameTooltip:AddLine("Click name to pin (keeps the customer on Clear list).",
                                            1, 0.82, 0, true)
                    end
                    GameTooltip:AddLine(" ")
                    local e = HB.db.runs[key] or {}
                    GameTooltip:AddLine(("Remaining runs:  |cFFFFFFFF%d|r"):format(e.remaining or 0),
                                        1, 0.82, 0)
                    local rg = HB:RemainingGold(key)
                    if rg ~= nil then
                        GameTooltip:AddLine(("Remaining gold:  |cFFFFFFFF%s|r"):format(HB:FormatMoney(rg)),
                                            1, 0.82, 0)
                    else
                        GameTooltip:AddLine("Remaining gold:  |cFF888888--|r  (no rate known)",
                                            1, 0.82, 0)
                    end
                end
                GameTooltip:Show()
            end)
            row.nameBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row:Show()
        else
            row:Hide()
        end
    end
end

-- ----------------------------------------------------------------------------
-- Show / hide / toggle
-- ----------------------------------------------------------------------------
-- Rebuild the Prices list inside the Settings panel. Each row shows the
-- dungeon name, its current price as an editable gold field, and a remove (x).
-- Used both on first Settings open and after any price add/edit/remove.
function UI:RefreshPrices()
    local f = self.frame
    if not f or not f.priceContent then return end
    local content = f.priceContent

    -- Tear down any old rows.
    for _, r in ipairs(f.priceRows) do r:Hide(); r:SetParent(nil) end
    wipe(f.priceRows)

    -- Build a sorted list: __default first, then alpha.
    local list = HB:ListPrices()
    table.sort(list, function(a, b)
        if a.name == "__default" then return true end
        if b.name == "__default" then return false end
        return a.name < b.name
    end)

    local ROW = 22
    for i, entry in ipairs(list) do
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(content:GetWidth(), ROW)
        row:SetPoint("TOPLEFT", 0, -((i - 1) * ROW))

        local label = (entry.name == "__default") and "(default)" or entry.name
        local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameFS:SetPoint("LEFT", row, "LEFT", 2, 0)
        nameFS:SetWidth(150); nameFS:SetJustifyH("LEFT")
        nameFS:SetText(label)

        -- Inline editable gold value (initial value derived from copper).
        local gold = (entry.copper or 0) / 10000
        local goldStr = (gold == math.floor(gold)) and tostring(math.floor(gold))
                                                  or string.format("%.2f", gold)
        local edit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        edit:SetPoint("LEFT", nameFS, "RIGHT", 8, 0)
        edit:SetSize(50, 18); edit:SetAutoFocus(false)
        edit:SetText(goldStr)
        -- Save action shared by Enter and "clicked away" (focus lost). If the
        -- text isn't a valid number we silently revert by refreshing the list.
        local function commitEdit(self)
            local g = tonumber(self:GetText())
            if not g or g < 0 then
                self:ClearFocus()
                UI:RefreshPrices()
                return
            end
            local newCopper = math.floor(g * 10000 + 0.5)
            if newCopper ~= (entry.copper or 0) then
                HB:SetPrice(entry.name, newCopper)
                HB:Print("Updated: |cFFFFD700%s|r = %s/run", label, HB:FormatMoney(newCopper))
            end
            self:ClearFocus()
            UI:RefreshPrices()
        end
        edit:SetScript("OnEnterPressed",   commitEdit)
        edit:SetScript("OnEditFocusLost",  commitEdit)
        edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); UI:RefreshPrices() end)

        local gLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        gLabel:SetPoint("LEFT", edit, "RIGHT", 4, 0)
        gLabel:SetText("g/run")

        local x = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        x:SetSize(22, 18); x:SetText("x")
        x:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        x:SetScript("OnClick", function()
            HB:SetPrice(entry.name, 0)
            HB:Print("Removed price: %s", label)
            UI:RefreshPrices()
        end)

        f.priceRows[#f.priceRows + 1] = row
    end

    -- Resize content for scrolling.
    content:SetHeight(math.max(130, #list * ROW))

    if #list == 0 then
        local empty = CreateFrame("Frame", nil, content)
        empty:SetSize(content:GetWidth(), ROW * 2)
        empty:SetPoint("TOPLEFT")
        local fs = empty:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("CENTER")
        fs:SetText("|cFF888888No prices set yet.|r")
        f.priceRows[#f.priceRows + 1] = empty
    end

    -- If the trade-window dungeon picker is open, refresh it so a price added
    -- or removed here appears immediately (the refresh preserves the pick).
    if HB.TradePicker and HB.TradePicker.Refresh then HB.TradePicker:Refresh() end
end


function UI:Show()
    self:Build()
    self.frame:Show()
    HB.db.window.shown = true
    self:Refresh()
end

function UI:Hide()
    if self.frame then self.frame:Hide() end
    if self.frame and self.frame.settings then self.frame.settings:Hide() end
    HB.db.window.shown = false
end

function UI:Toggle()
    self:Build()
    if self.frame:IsShown() then self:Hide() else self:Show() end
end

-- Global entry point for slash, minimap, or a /hb macro bound to a key.
_G.HappyBooster_ToggleWindow = function() UI:Toggle() end

-- ----------------------------------------------------------------------------
-- History popup: a copy-friendly window for the last 20 events.
-- Built on-demand and reused. The EditBox is read-only (OnTextChanged reverts
-- to the cached text so the user can't accidentally type into the log) but
-- still allows selection -- so Ctrl+A / Ctrl+C copies the whole thing out.
-- ----------------------------------------------------------------------------
local function BuildHistoryText()
    local h = HB.db.history or {}
    if #h == 0 then return "History empty." end
    local lines = {}
    table.insert(lines, ("HappyBooster history (last %d events):"):format(math.min(20, #h)))
    table.insert(lines, ("Generated: %s"):format(date("%Y-%m-%d %H:%M:%S")))
    table.insert(lines, "")
    for i = math.max(1, #h - 19), #h do
        local e = h[i]
        local ts = date("%H:%M:%S", e.timestamp or 0)
        if e.type == "trade" then
            table.insert(lines, ("[%s] TRADE  %-20s -> %d runs"):format(
                ts, HB:PrettyName(e.key or "?"), e.runs or 0))
        elseif e.type == "run" then
            table.insert(lines, ("[%s] RUN    (%d affected) %s"):format(
                ts, e.affected or 0, e.reason or ""))
        else
            table.insert(lines, ("[%s] %s"):format(ts, e.type or "?"))
        end
    end
    return table.concat(lines, "\n")
end

function UI:ShowHistory()
    local f = self.historyFrame
    if not f then
        f = CreateFrame("Frame", "HappyBoosterHistory", UIParent, "BackdropTemplate")
        f:SetSize(560, 480)
        f:SetFrameStrata("DIALOG")
        f:SetClampedToScreen(true)
        f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        if f.SetBackdrop then
            f:SetBackdrop(BACKDROP)
            f:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
            f:SetBackdropBorderColor(0.6, 0.5, 0.1, 1)
        end
        f:SetPoint("CENTER")

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -12)
        title:SetText("|cFFFFD700HappyBooster|r - History")

        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -2, -2)
        close:SetScript("OnClick", function() f:Hide() end)

        -- Scroll + EditBox
        local scroll = CreateFrame("ScrollFrame", "HappyBoosterHistoryScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 16, -40)
        scroll:SetPoint("BOTTOMRIGHT", -32, 56)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetMaxLetters(0)
        edit:EnableMouse(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(490)
        edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); f:Hide() end)
        -- Read-only behavior: revert any edits back to the cached text.
        edit:SetScript("OnTextChanged", function(self, userInput)
            if userInput and f.cachedText and self:GetText() ~= f.cachedText then
                self:SetText(f.cachedText)
            end
        end)
        edit:SetScript("OnMouseDown", function(self) self:SetFocus() end)
        scroll:SetScrollChild(edit)
        f.edit = edit

        -- Select All button
        local selBtn = MakeButton(f, 120, 24, "Select All")
        selBtn:SetPoint("BOTTOMRIGHT", -16, 16)
        selBtn:SetScript("OnClick", function()
            f.edit:SetFocus()
            f.edit:HighlightText()
        end)

        -- Refresh button (re-pull latest history without closing)
        local refBtn = MakeButton(f, 90, 24, "Refresh")
        refBtn:SetPoint("RIGHT", selBtn, "LEFT", -6, 0)
        refBtn:SetScript("OnClick", function()
            local txt = BuildHistoryText()
            f.cachedText = txt
            f.edit:SetText(txt)
        end)

        -- Hint
        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("BOTTOMLEFT", 16, 22)
        hint:SetText("Click |cffffff00Select All|r, then press Ctrl+C to copy.")
        hint:SetTextColor(0.7, 0.7, 0.7)

        self.historyFrame = f
    end

    local txt = BuildHistoryText()
    f.cachedText = txt
    f.edit:SetText(txt)
    -- Pre-select so Ctrl+C works on the very first click.
    f:Show()
    f.edit:SetFocus()
    f.edit:HighlightText()
end

-- Convenience HB-side alias so Commands.lua can call HB:ShowHistory().
function HB:ShowHistory() UI:ShowHistory() end
