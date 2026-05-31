--[[----------------------------------------------------------------------------
    HappyBooster - TradePicker.lua
    A radio-button panel that docks to the right of the live trade window
    (BOOSTER mode only). Lets the booster pick WHICH dungeon's price this trade
    is for, so the suggested run count and the underpayment warning work even
    when trading outside the instance (e.g. in town between runs).

    The chosen dungeon is exposed via HB:GetTradeDungeon(), which Trade.lua's
    completion handler reads instead of relying solely on auto-detection.

    Selection precedence (matches the design spec):
        explicit session pick  >  current dungeon ("(here)")  >  last used  >  top row
    An explicit pick is sticky for the session, so "selling BRD while standing
    in SM" doesn't keep snapping back to SM on every trade.

    The panel rebuilds live (HB.TradePicker:Refresh()) when prices change while
    it's open, preserving the current selection. Its height tracks the trade
    window so a normal dungeon list never needs scrolling.
------------------------------------------------------------------------------]]

local addonName, HB = ...

local Picker = {}
HB.TradePicker = Picker

local ROW_H   = 24           -- taller rows: easier to read and click
local PANEL_W = 172
local TITLE_PAD = 38         -- vertical space for the title + padding
local MIN_ROWS  = 3          -- don't shrink below this when content is tiny

-- Sticky explicit choice the booster made this session (wins over auto-detect).
local sessionPick = nil
-- Last dungeon used on a trade (weak fallback default).
local lastPicked  = nil
-- Canonical key currently selected in the open picker.
local selected    = nil

local BACKDROP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- The canonical key Trade.lua should price this trade against. Falls back to
-- auto-detect (old behavior) when the picker never set anything.
function HB:GetTradeDungeon()
    return selected or sessionPick or lastPicked or HB:GetActiveDungeon()
end

-- Build the ordered radio list: current dungeon first ("(here)"), then priced
-- dungeons alphabetically. Returns the list and the normalized current key.
local function BuildList()
    local out, seen = {}, {}
    local current = HB:GetActiveDungeon()
    current = current and HB:NormalizeDungeon(current) or nil

    local function push(key, isCurrent)
        if not key or key == "" or key == "__default" then return end
        if seen[key] then
            if isCurrent then
                for _, e in ipairs(out) do if e.key == key then e.isCurrent = true end end
            end
            return
        end
        seen[key] = true
        out[#out + 1] = { key = key, isCurrent = isCurrent or false }
    end

    for _, e in ipairs(HB:ListPrices()) do push(e.name, e.name == current) end
    -- ensure the current dungeon and any sticky picks appear even if unpriced
    push(current, true)
    push(sessionPick, sessionPick == current)
    push(lastPicked,  lastPicked  == current)

    table.sort(out, function(a, b)
        if a.isCurrent ~= b.isCurrent then return a.isCurrent end   -- current first
        return HB:PrettyDungeon(a.key) < HB:PrettyDungeon(b.key)
    end)
    return out, current
end

local function ChooseDefault(list, current)
    local function has(k)
        if not k then return false end
        for _, e in ipairs(list) do if e.key == k then return true end end
        return false
    end
    if has(sessionPick) then return sessionPick end
    if has(current)     then return current end
    if has(lastPicked)  then return lastPicked end
    return list[1] and list[1].key or nil
end

-- Centralized selection so a click anywhere on a row (or on the radio) does the
-- same thing and all radios stay in sync.
local function SelectKey(f, key)
    selected    = key
    sessionPick = key            -- becomes the sticky session choice
    for _, r in ipairs(f.rows) do
        if r.radio then r.radio:SetChecked(r.key == key) end
    end
end

function Picker:Build()
    if self.frame then return self.frame end

    local f = CreateFrame("Frame", "HappyBoosterTradePicker", UIParent, "BackdropTemplate")
    f:SetWidth(PANEL_W + 34)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    if f.SetBackdrop then
        f:SetBackdrop(BACKDROP)
        f:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
        f:SetBackdropBorderColor(0.6, 0.5, 0.1, 1)
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cFFFFD700Selling which dungeon?|r")
    f.title = title

    local scroll = CreateFrame("ScrollFrame", "HappyBoosterTradePickerScroll", f,
                               "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    scroll:SetSize(PANEL_W, ROW_H * MIN_ROWS)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local sb = _G["HappyBoosterTradePickerScrollScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - delta * ROW_H) end
    end)
    f.scroll = scroll

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(PANEL_W - 4, ROW_H)
    scroll:SetScrollChild(content)
    f.content = content
    f.rows = {}

    self.frame = f
    return f
end

-- How tall the list viewport may grow before it scrolls: as tall as the trade
-- window (minus the title), so a realistic dungeon list never needs scrolling.
local function AvailableHeight()
    if TradeFrame and TradeFrame:IsShown() then
        local h = TradeFrame:GetHeight() - TITLE_PAD
        if h and h > ROW_H * MIN_ROWS then return h end
    end
    return ROW_H * 13   -- sensible fallback when the trade window isn't measurable
end

function Picker:Rebuild()
    local f = self:Build()
    for _, r in ipairs(f.rows) do r:Hide(); r:SetParent(nil) end
    wipe(f.rows)

    local list, current = BuildList()
    -- Preserve the current selection if it still exists (e.g. after a price was
    -- added mid-trade); only fall back to a default if it vanished.
    local stillThere = false
    if selected then
        for _, e in ipairs(list) do if e.key == selected then stillThere = true; break end end
    end
    if not stillThere then selected = ChooseDefault(list, current) end

    if #list == 0 then
        local empty = f.content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        empty:SetPoint("TOPLEFT", 4, -4)
        empty:SetText("|cFF888888No prices set.|r")
        f.content:SetHeight(ROW_H)
        f.scroll:SetHeight(ROW_H)
        f:SetHeight(ROW_H + TITLE_PAD)
        return
    end

    for i, e in ipairs(list) do
        local row = CreateFrame("Button", nil, f.content)
        row:SetSize(f.content:GetWidth(), ROW_H)
        row:SetPoint("TOPLEFT", 0, -((i - 1) * ROW_H))
        row.key = e.key

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)   -- subtle hover feedback

        local rb = CreateFrame("CheckButton", nil, row, "UIRadioButtonTemplate")
        rb:SetPoint("LEFT", 2, 0)
        rb:SetChecked(e.key == selected)
        row.radio = rb

        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", rb, "RIGHT", 6, 0)
        fs:SetWidth(PANEL_W - 30)
        fs:SetJustifyH("LEFT")
        local label = HB:PrettyDungeon(e.key)
        if e.isCurrent then label = label .. " |cFF60FF60(here)|r" end
        if (HB:GetPrice(e.key) or 0) <= 0 then label = label .. " |cFF888888(no price)|r" end
        fs:SetText(label)

        -- Click anywhere on the row, or on the radio itself, to select.
        row:SetScript("OnClick", function() SelectKey(f, e.key) end)
        rb:SetScript("OnClick",  function() SelectKey(f, e.key) end)

        f.rows[#f.rows + 1] = row
    end

    local contentH = #list * ROW_H
    local viewport = math.min(contentH, AvailableHeight())
    viewport = math.max(viewport, ROW_H)          -- never zero-height
    f.content:SetHeight(contentH)
    f.scroll:SetHeight(viewport)
    f:SetHeight(viewport + TITLE_PAD)
end

-- Rebuild in place if the panel is currently open (called when prices change).
function Picker:Refresh()
    if self.frame and self.frame:IsShown() then self:Rebuild() end
end

function Picker:Show()
    if HB.IsBoosted and HB:IsBoosted() then return end   -- booster mode only
    local f = self:Build()
    self:Rebuild()

    f:ClearAllPoints()
    if TradeFrame then
        f:SetPoint("TOPLEFT", TradeFrame, "TOPRIGHT", -2, -8)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 260, 0)
    end
    f:Show()
end

function Picker:Hide()
    if selected then lastPicked = selected end   -- remember as weak default
    if self.frame then self.frame:Hide() end
end

-- Own event frame: show on trade open, hide on close. Independent of Trade.lua
-- so the two concerns stay separate; Trade.lua just reads HB:GetTradeDungeon().
local ev = CreateFrame("Frame")
ev:RegisterEvent("TRADE_SHOW")
ev:RegisterEvent("TRADE_CLOSED")
ev:SetScript("OnEvent", function(_, event)
    if event == "TRADE_SHOW" then
        Picker:Show()
    elseif event == "TRADE_CLOSED" then
        Picker:Hide()
    end
end)
