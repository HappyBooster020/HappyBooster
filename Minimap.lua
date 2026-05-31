--[[----------------------------------------------------------------------------
    HappyBooster - Minimap.lua
    A self-contained minimap button (no LibDBIcon dependency).
      Left-click : toggle the window.
      Drag       : reposition around the minimap (angle saved).
      Hover      : summary tooltip.
------------------------------------------------------------------------------]]

local addonName, HB = ...

local Minimap_ = {}
HB.Minimap = Minimap_

local RADIUS = 80  -- distance from minimap center

local function UpdatePosition(btn)
    local angle = math.rad(HB.db.minimap.angle or 215)
    local x = math.cos(angle) * RADIUS
    local y = math.sin(angle) * RADIUS
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function Minimap_:RefreshTooltip()
    if self.button and GameTooltip:IsOwned(self.button) then
        self:ShowTooltip(self.button)
    end
end

function Minimap_:ShowTooltip(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
    GameTooltip:AddDoubleLine("|cFFFFD700HappyBooster|r",
        HB:IsBoosted() and "BOOSTED" or "BOOSTER")
    GameTooltip:AddLine(" ")

    local data = {}
    for key, e in pairs(HB.db.runs) do
        data[#data + 1] = { key = key, remaining = e.remaining or 0, total = e.total or 0 }
    end
    table.sort(data, function(a, b)
        if a.remaining ~= b.remaining then return a.remaining < b.remaining end
        return a.key < b.key
    end)

    if #data == 0 then
        GameTooltip:AddLine("Nobody tracked yet.", 0.7, 0.7, 0.7)
    else
        local shown = 0
        for _, d in ipairs(data) do
            if shown >= 10 then
                GameTooltip:AddLine(("...and %d more"):format(#data - shown), 0.6, 0.6, 0.6)
                break
            end
            local color = (d.remaining <= 0) and "|cFFFF4444" or "|cFFFFD700"
            local right = HB.db.settings.countDown
                          and ("%s%d/%d|r"):format(color, d.remaining, d.total)
                          or  ("%s%d|r"):format(color, d.remaining)
            GameTooltip:AddDoubleLine(HB:PrettyName(d.key), right, 1, 1, 1)
            shown = shown + 1
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: open window", 0.4, 0.8, 1)
    GameTooltip:AddLine("Drag: move this button", 0.4, 0.8, 1)
    GameTooltip:Show()
end

function Minimap_:Create()
    if self.button then return end
    if HB.db.minimap.hide then return end

    local btn = CreateFrame("Button", "HappyBoosterMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- ring overlay (standard minimap button border)
    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    -- icon (custom coin texture from media/happybooster.tga; falls back to
    -- the Blizzard coin icon if for some reason the texture fails to load).
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\AddOns\\HappyBooster\\media\\happybooster")
    icon:SetPoint("CENTER", 0, 1)
    -- No texCoord crop -- the TGA is already circular-masked so the full
    -- texture is what we want to show inside the minimap-button ring.
    btn.icon = icon

    btn:SetScript("OnClick", function() HB.UI:Toggle() end)

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(s)
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            local angle = math.deg(math.atan2(py - my, px - mx))
            HB.db.minimap.angle = angle
            UpdatePosition(s)
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnEnter", function(self) Minimap_:ShowTooltip(self) end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    self.button = btn
    UpdatePosition(btn)
end

function Minimap_:SetShown(show)
    HB.db.minimap.hide = not show
    if show then
        self:Create()
        if self.button then self.button:Show() end
    elseif self.button then
        self.button:Hide()
    end
end
