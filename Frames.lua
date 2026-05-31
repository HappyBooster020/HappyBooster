--[[----------------------------------------------------------------------------
    HappyBooster - Frames.lua
    Draws a counter on each relevant unit frame.
      booster mode: party/raid members (not you).
      boosted mode: your own frame.
    Supports default party/raid frames (both raid layouts), ElvUI, and a
    generic UIParent scan as a safety net for other frame addons.
------------------------------------------------------------------------------]]

local addonName, HB = ...

local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local overlays    = {}   -- frame -> fontstring
local cachedPairs = {}   -- { {unit=, frame=}, ... }

local function ResolveUnit(frame)
    if not frame then return nil end
    if type(frame.unit) == "string" then return frame.unit end
    if frame.GetAttribute then
        local u = frame:GetAttribute("unit")
        if type(u) == "string" then return u end
    end
    return nil
end

local function IsPartyRaid(unit)
    return unit and (unit:match("^party%d$") or unit:match("^raid%d+$"))
end

-- Mode-aware: should this unit get a counter?
local function UnitWanted(unit)
    if not unit then return false end
    if HB:IsBoosted() then
        return unit == "player" or (UnitExists(unit) and UnitIsUnit(unit, "player"))
    end
    if not IsPartyRaid(unit) then return false end
    if UnitExists(unit) and UnitIsUnit(unit, "player") then return false end
    return true
end

-- ---- discovery -------------------------------------------------------------
local function CollectNamed(r)
    for i = 1, 4 do
        local f = _G["PartyMemberFrame" .. i]
        if f then local u = ResolveUnit(f) or ("party" .. i)
            if UnitWanted(u) then r[#r+1] = { unit = u, frame = f } end end
    end
    for i = 1, 5 do
        local f = _G["CompactPartyFrameMember" .. i]
        if f then local u = ResolveUnit(f)
            if UnitWanted(u) then r[#r+1] = { unit = u, frame = f } end end
    end
    if _G.PartyFrame and PartyFrame.MemberFrame1 then
        for i = 1, 4 do
            local f = PartyFrame["MemberFrame" .. i]
            if f then local u = ResolveUnit(f) or ("party" .. i)
                if UnitWanted(u) then r[#r+1] = { unit = u, frame = f } end end
        end
    end
    for i = 1, 40 do
        local f = _G["CompactRaidFrame" .. i]
        if f then local u = ResolveUnit(f)
            if UnitWanted(u) then r[#r+1] = { unit = u, frame = f } end end
    end
    if _G.CompactRaidFrameContainer then
        for g = 1, 8 do
            local grp = _G["CompactRaidGroup" .. g]
            if grp and grp.GetChildren then
                for _, child in ipairs({ grp:GetChildren() }) do
                    local u = ResolveUnit(child)
                    if UnitWanted(u) then r[#r+1] = { unit = u, frame = child } end
                end
            end
        end
    end
    -- ElvUI party
    for i = 1, 5 do
        local f = _G["ElvUF_PartyGroup1UnitButton" .. i]
        if f then local u = ResolveUnit(f)
            if UnitWanted(u) then r[#r+1] = { unit = u, frame = f } end end
    end
    -- ElvUI raid (grouped + flat)
    for g = 1, 8 do
        for b = 1, 5 do
            local f = _G["ElvUF_RaidGroup" .. g .. "UnitButton" .. b]
            if f then local u = ResolveUnit(f)
                if UnitWanted(u) then r[#r+1] = { unit = u, frame = f } end end
        end
    end
    for i = 1, 40 do
        local f = _G["ElvUF_RaidUnitButton" .. i] or _G["ElvUF_Raid40UnitButton" .. i]
        if f then local u = ResolveUnit(f)
            if UnitWanted(u) then r[#r+1] = { unit = u, frame = f } end end
    end
    -- Shadowed Unit Frames (SUF)
    for i = 1, 4 do
        local f = _G["SUFUnitparty" .. i]
        if f then local u = ResolveUnit(f) or ("party" .. i)
            if UnitWanted(u) then r[#r+1] = { unit = u, frame = f } end end
    end
    for i = 1, 40 do
        local f = _G["SUFUnitraid" .. i] or _G["SUFHeaderraidUnitButton" .. i]
        if f then local u = ResolveUnit(f)
            if UnitWanted(u) then r[#r+1] = { unit = u, frame = f } end end
    end
    -- Pitbull 4: frame names follow PitBull4_Frames_<groupname>
    if _G.PitBull4 and _G.PitBull4.IterateFramesForUnit then
        for i = 1, 4 do
            for f in _G.PitBull4:IterateFramesForUnit("party" .. i) do
                if UnitWanted("party" .. i) then r[#r+1] = { unit = "party" .. i, frame = f } end
            end
        end
        for i = 1, 40 do
            for f in _G.PitBull4:IterateFramesForUnit("raid" .. i) do
                if UnitWanted("raid" .. i) then r[#r+1] = { unit = "raid" .. i, frame = f } end
            end
        end
    end
    -- Grid / Grid2 / Plexus: GridLayoutFrame contains GridLayoutHeaderN with
    -- child unit buttons. Names vary (GridLayoutHeader1UnitButton1, or just
    -- direct child frames). Walk the layout container instead.
    local gridParent = _G.GridLayoutFrame or _G.Grid2LayoutFrame or _G.PlexusLayoutFrame
    if gridParent and gridParent.GetChildren then
        for _, hdr in ipairs({ gridParent:GetChildren() }) do
            if hdr.GetChildren then
                for _, btn in ipairs({ hdr:GetChildren() }) do
                    local u = ResolveUnit(btn)
                    if UnitWanted(u) then r[#r+1] = { unit = u, frame = btn } end
                end
            end
        end
    end
    -- Cell: CellRaidFrameAnchor + CellPartyFrameAnchor with button children.
    for _, anchor in ipairs({ _G.CellRaidFrameAnchor, _G.CellPartyFrameAnchor,
                              _G.CellRaidFrameHeader1, _G.CellPartyFrame }) do
        if anchor and anchor.GetChildren then
            for _, btn in ipairs({ anchor:GetChildren() }) do
                local u = ResolveUnit(btn)
                if UnitWanted(u) then r[#r+1] = { unit = u, frame = btn } end
                -- one level deeper (Cell wraps the button under group headers)
                if btn.GetChildren then
                    for _, sub in ipairs({ btn:GetChildren() }) do
                        local u2 = ResolveUnit(sub)
                        if UnitWanted(u2) then r[#r+1] = { unit = u2, frame = sub } end
                    end
                end
            end
        end
    end
    -- VuhDo: VuhDoBouquet panel with vd-prefixed buttons (vd1h01 = panel 1, slot 1)
    for panel = 1, 10 do
        for slot = 1, 40 do
            local name = ("vd%dh%02d"):format(panel, slot)
            local f = _G[name]
            if f then local u = ResolveUnit(f)
                if UnitWanted(u) then r[#r+1] = { unit = u, frame = f } end end
        end
    end
end

local function CollectPlayer(r)
    if _G.PlayerFrame then r[#r+1] = { unit = "player", frame = _G.PlayerFrame } end
    if _G.ElvUF_player then r[#r+1] = { unit = "player", frame = _G.ElvUF_player } end
    for i = 1, 5 do
        local f = _G["CompactPartyFrameMember" .. i]
        if f then local u = ResolveUnit(f)
            if u and UnitExists(u) and UnitIsUnit(u, "player") then
                r[#r+1] = { unit = u, frame = f } end end
    end
    for i = 1, 40 do
        local f = _G["CompactRaidFrame" .. i]
        if f then local u = ResolveUnit(f)
            if u and UnitExists(u) and UnitIsUnit(u, "player") then
                r[#r+1] = { unit = u, frame = f } end end
    end
end

-- Frames we must never attach to, even if they expose a party/raid unit:
-- nameplates, target/focus/tot, boss/arena frames. Matched by global name.
local function IsExcludedFrame(frame)
    local name = frame and frame.GetName and frame:GetName()
    if not name then return false end
    return name:find("NamePlate")
        or name:find("TargetFrame")
        or name:find("FocusFrame")
        or name:find("Boss")
        or name:find("Arena")
        or name:find("Nameplate")
end

local function CollectGeneric(r, parent, depth)
    parent = parent or UIParent
    depth  = depth or 0
    if depth > 6 or not parent.GetChildren then return end
    for _, child in ipairs({ parent:GetChildren() }) do
        if not IsExcludedFrame(child) then
            local u = ResolveUnit(child)
            if UnitWanted(u) then r[#r+1] = { unit = u, frame = child } end
            CollectGeneric(r, child, depth + 1)
        end
    end
end

local function Dedupe(list)
    local seen, out = {}, {}
    for _, p in ipairs(list) do
        local k = tostring(p.frame) .. ":" .. p.unit
        if not seen[k] then seen[k] = true; out[#out+1] = p end
    end
    return out
end

local function CollectAll()
    local list = {}
    if HB:IsBoosted() then
        CollectPlayer(list)
        if #list == 0 then CollectGeneric(list) end
    else
        CollectNamed(list)
        -- Only fall back to the broad scan if the named frames found nothing,
        -- so we never attach stray numbers to nameplates / other unit frames.
        if #list == 0 then CollectGeneric(list) end
    end
    return Dedupe(list)
end

-- ---- overlay (rounded pill badge) -----------------------------------------
-- Each overlay is a small frame anchored to the unit frame's top-right corner,
-- overhanging slightly. It has a dark rounded fill, a colored border, and a
-- centered number. Gold normally, red at 0.
local PILL_BG     = "Interface\\Tooltips\\UI-Tooltip-Background"
local PILL_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"

local function StyleBadge(badge)
    local s = HB.db.settings
    local size = s.fontSize or 16
    -- Detect tiny parent frames (Grid/Cell/etc.): use a compact pill that fits.
    local parent = badge:GetParent()
    local pw, ph = (parent and parent:GetWidth() or 0), (parent and parent:GetHeight() or 0)
    local tiny = (pw > 0 and pw < 60) or (ph > 0 and ph < 30)
    if tiny then size = math.max(9, math.floor(size * 0.7)) end
    badge._tiny = tiny
    local h = size + (tiny and 4 or 8)
    badge:SetHeight(h)
    badge.text:SetFont(FONT, size, "OUTLINE")
    badge:ClearAllPoints()
    local pos = s.textPosition or "TOPRIGHT"
    -- For tiny frames, sit inside the corner instead of overhanging.
    local ox, oy = s.textOffsetX or 6, s.textOffsetY or 6
    if tiny then ox, oy = 0, 0 end
    badge:SetPoint(pos, badge:GetParent(), pos, ox, oy)
end

-- Pulse animation that runs while the count is 0. Pulses scale gently to catch
-- the eye without being obnoxious; stops the instant remaining > 0.
local function EnsurePulse(badge)
    if badge._pulse then return badge._pulse end
    local ag = badge:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    local a1 = ag:CreateAnimation("Scale")
    a1:SetScaleFrom(1.0, 1.0); a1:SetScaleTo(1.18, 1.18)
    a1:SetDuration(0.45); a1:SetOrder(1); a1:SetSmoothing("OUT")
    local a2 = ag:CreateAnimation("Scale")
    a2:SetScaleFrom(1.18, 1.18); a2:SetScaleTo(1.0, 1.0)
    a2:SetDuration(0.45); a2:SetOrder(2); a2:SetSmoothing("IN")
    badge._pulse = ag
    return ag
end

local function EnsureOverlay(frame)
    if overlays[frame] then return overlays[frame] end
    local badge = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    badge:SetFrameStrata("HIGH")
    badge:SetFrameLevel((frame:GetFrameLevel() or 1) + 10)
    if badge.SetBackdrop then
        badge:SetBackdrop({
            bgFile   = PILL_BG,
            edgeFile = PILL_BORDER,
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
    end
    local txt = badge:CreateFontString(nil, "OVERLAY")
    txt:SetPoint("CENTER", badge, "CENTER", 0, 0)
    txt:SetFont(FONT, HB.db.settings.fontSize or 16, "OUTLINE")
    badge.text = txt
    -- The pill is PURELY VISUAL. We deliberately do NOT enable the mouse on it:
    -- that would intercept clicks on the party frame underneath and block the
    -- player's normal targeting flow. Adjust counts via the window's row +/-
    -- buttons instead.
    badge:EnableMouse(false)
    overlays[frame] = badge
    StyleBadge(badge)
    return badge
end

local function UpdateOverlay(unit, frame)
    local badge = overlays[frame]
    if not HB.db.settings.showOnFrames then
        if badge then
            if badge._pulse and badge._pulse:IsPlaying() then badge._pulse:Stop() end
            badge:Hide()
        end
        return
    end
    local key = HB:GetUnitKey(unit)
    local remaining = HB:GetCount(key)
    if remaining == nil then
        if badge then
            if badge._pulse and badge._pulse:IsPlaying() then badge._pulse:Stop() end
            badge:Hide()
        end
        return
    end
    badge = EnsureOverlay(frame)
    StyleBadge(badge)

    local txt = tostring(remaining)
    badge.text:SetText(txt)
    -- size the pill to the number width
    local w = badge.text:GetStringWidth() or 12
    badge:SetWidth(math.max(badge:GetHeight(), w + (badge._tiny and 8 or 14)))

    local zero = (remaining <= 0)
    local c = zero and HB.db.settings.zeroColor or HB.db.settings.textColor
    badge.text:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    if badge.SetBackdropBorderColor then
        badge:SetBackdropBorderColor(c[1], c[2], c[3], 1)
        if zero then
            badge:SetBackdropColor(0.22, 0.05, 0.05, 0.9)  -- dark red fill
        else
            badge:SetBackdropColor(0.06, 0.06, 0.08, 0.9)  -- dark fill
        end
    end
    -- Drive the pulse animation from the zero state.
    local pulse = EnsurePulse(badge)
    if zero then
        if not pulse:IsPlaying() then pulse:Play() end
    else
        if pulse:IsPlaying() then pulse:Stop() end
    end
    badge:Show()
end

function HB:UpdateAllFrames()
    if not HB.db then return end
    -- Hide every existing overlay first. The new collection will re-show only
    -- the frames that match the current mode/group; anything orphaned (e.g.
    -- the player's own frame after switching from boosted to booster) stays hidden.
    for _, badge in pairs(overlays) do
        if badge and badge.Hide then badge:Hide() end
    end
    cachedPairs = CollectAll()
    for _, p in ipairs(cachedPairs) do UpdateOverlay(p.unit, p.frame) end
end

-- Cheap re-apply over known frames (no tree walk).
function HB:RefreshCounts()
    if not HB.db then return end
    if #cachedPairs == 0 then HB:UpdateAllFrames(); return end
    for _, p in ipairs(cachedPairs) do UpdateOverlay(p.unit, p.frame) end
end

-- ---- events + timer --------------------------------------------------------
local f = CreateFrame("Frame", "HappyBoosterFramesUpdater")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("UNIT_NAME_UPDATE")
-- PARTY_MEMBERS_CHANGED only exists on some Classic clients; registering an
-- unknown event errors, so try it safely and ignore failure.
pcall(f.RegisterEvent, f, "PARTY_MEMBERS_CHANGED")
f:SetScript("OnEvent", function()
    C_Timer.After(0.1, function() HB:UpdateAllFrames() end)
end)

local e, fe = 0, 0
f:SetScript("OnUpdate", function(_, dt)
    if not (HB.db and HB.db.settings.showOnFrames) then return end
    e, fe = e + dt, fe + dt
    if fe >= 10 then fe, e = 0, 0; HB:UpdateAllFrames()
    elseif e >= 2 then e = 0; HB:RefreshCounts() end
end)

-- Frame refresh + window restore on login. Registered as a hook so it runs
-- alongside Core's HB:OnLogin instead of overwriting it.
table.insert(HB.onLoginHooks, function()
    C_Timer.After(0.5, function() HB:UpdateAllFrames() end)
    if HB.UI and HB.db.window.shown then HB.UI:Show() end
end)
