--[[----------------------------------------------------------------------------
    HappyBooster - Trade.lua
    Detects a completed trade and (optionally) prompts for the runs paid for.
      * booster mode: counts gold RECEIVED, sets the partner's counter.
      * boosted mode: counts gold GIVEN,   sets YOUR counter.
------------------------------------------------------------------------------]]

local addonName, HB = ...

local tradeFrame = CreateFrame("Frame", "HappyBoosterTradeFrame")

local state = {}
local function ResetState()
    state.partnerName  = nil
    state.partnerRealm = nil
    state.playerOK     = false
    state.targetOK     = false
    state.moneyRecv    = 0
    state.moneyGiven   = 0
    state.startMoney   = nil   -- GetMoney() when the trade opened (bag-delta fallback)
    state.armed        = false
    state.handled      = false
end
ResetState()
local tradeGen = 0  -- bumped each TRADE_SHOW; guards delayed cleanup against a new trade
local moneyTicker   -- repeating poll of the live trade money while the window is open

-- Capture trade money during the trade. We keep the most recent NON-ZERO value,
-- so lowering the amount before accepting is respected (250 -> 150 records 150),
-- while a transient 0 (some clients report 0 mid-trade, and the APIs return 0
-- once the window closes) never wipes a real amount. Offers lock at accept-time,
-- so the last value captured then is the true agreed amount.
local function CaptureMoney(where)
    local recv  = (GetTargetTradeMoney and GetTargetTradeMoney()) or 0
    local given = (GetPlayerTradeMoney and GetPlayerTradeMoney()) or 0
    if recv  and recv  > 0 then state.moneyRecv  = recv  end
    if given and given > 0 then state.moneyGiven = given end
    HB:Debug("Money @%s: given=%s recv=%s (kept given=%s recv=%s)",
             where, tostring(given), tostring(recv),
             tostring(state.moneyGiven), tostring(state.moneyRecv))
end

-- Set-runs popup (shared with the window's per-row Set button)
-- Resilient edit-box accessor: different WoW versions store it under
-- different field names. The global name suffix has always worked.
local function GetPopupEditBox(self)
    return self.editBox
        or self.EditBox
        or (self.GetName and _G[self:GetName() .. "EditBox"])
        or nil
end

StaticPopupDialogs["HAPPYBOOSTER_RUN_INPUT"] = {
    text = "Set runs for |cFFFFD700%s|r:",
    button1 = "Confirm",
    button2 = "Cancel",
    hasEditBox = 1,
    maxLetters = 4,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnShow = function(self)
        local eb = GetPopupEditBox(self)
        if not eb then return end
        eb:SetNumeric(true)
        local data = self.data
        local startText
        if data and data.preset then
            startText = tostring(data.preset)
        elseif data and data.mode == "trade" then
            -- Use the price-computed suggestion when we have one (0 if
            -- underpaid). Otherwise leave empty for the booster to type.
            if data.suggest ~= nil then
                startText = tostring(data.suggest)
            else
                startText = ""
            end
        else
            startText = tostring((HB.db and HB.db.settings.defaultRuns) or 5)
        end
        eb:SetText(startText)
        eb:HighlightText()
        eb:SetFocus()
    end,
    OnAccept = function(self)
        local eb = GetPopupEditBox(self)
        local num = tonumber((eb and eb:GetText()) or "")
        local data = self.data
        if num and num >= 0 and data and data.key then
            if data.mode == "trade" then
                local how = HB:ApplyTradeRuns(data.key, num)
                local total = select(2, HB:GetCount(data.key)) or num
                local remaining = HB:GetCount(data.key) or num
                local gold = (data.copper and data.copper > 0)
                             and ("  (paid " .. HB:FormatMoney(data.copper) .. ")") or ""
                local selfKey = HB:GetUnitKey("player")
                local isSelf  = (data.key == selfKey)
                if isSelf then
                    -- BOOSTED mode self-add: don't print own name, frame it as
                    -- adding to "your counter" for cleaner phrasing.
                    if how == "added" then
                        HB:Print("Added %s runs to your counter -- now %s left.%s",
                                 HB:Hi(num), HB:Hi(remaining), gold)
                    else
                        HB:Print("Tracking %s runs on your counter.%s",
                                 HB:Hi(num), gold)
                    end
                else
                    if how == "added" then
                        HB:Print("Added %s runs for %s -- now %s left.%s",
                                 HB:Hi(num), HB:Hi(HB:PrettyName(data.key)), HB:Hi(remaining), gold)
                    else
                        HB:Print("Tracking %s runs for %s.%s",
                                 HB:Hi(num), HB:Hi(HB:PrettyName(data.key)), gold)
                    end
                end
                HB:LogHistory({ type = "trade", key = data.key, runs = num,
                                copper = data.copper or 0, timestamp = time() })
                HB:RecordTrade(data.key, data.copper or 0, num)
            else
                HB:SetCount(data.key, num, num)
            end
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        local data, num = parent.data, tonumber(self:GetText() or "")
        if num and num >= 0 and data and data.key then
            if data.mode == "trade" then
                HB:ApplyTradeRuns(data.key, num)
                HB:LogHistory({ type = "trade", key = data.key, runs = num,
                                copper = data.copper or 0, timestamp = time() })
                HB:RecordTrade(data.key, data.copper or 0, num)
            else
                HB:SetCount(data.key, num, num)
            end
        end
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

-- Public helper used by the window to open the same popup.
function HB:PromptSetRuns(key, preset)
    if not key then return end
    StaticPopupDialogs["HAPPYBOOSTER_RUN_INPUT"].text = "Set runs for |cFFFFD700%s|r:"
    StaticPopup_Show("HAPPYBOOSTER_RUN_INPUT", HB:PrettyName(key), nil,
                     { key = key, preset = preset, mode = "set" })
end

local function CapturePartner()
    local name, realm = UnitName("npc")
    if not name or name == "" or name == UNKNOWNOBJECT then
        if _G.TradeFrameRecipientNameText then
            name = TradeFrameRecipientNameText:GetText()
        end
    end
    if name and name ~= "" and name ~= UNKNOWNOBJECT then
        state.partnerName, state.partnerRealm = name, realm
        HB:Debug("Trade partner: %s (%s)", name, realm or "<same realm>")
    end
end

local function HandleComplete()
    if state.handled or not state.partnerName then return end
    state.handled = true

    local boosted    = HB:IsBoosted()
    local partnerKey = HB:GetNameKey(state.partnerName, state.partnerRealm)
    local targetKey  = boosted and HB:GetUnitKey("player") or partnerKey

    -- Gold: trust the trade-window capture first; fall back to the bag-money
    -- delta (only when the window value is 0). Bag delta is the net change in
    -- our own gold across this trade, so it's correct for a single trade.
    local gold = boosted and (state.moneyGiven or 0) or (state.moneyRecv or 0)
    if gold == 0 and state.startMoney and GetMoney then
        local delta = GetMoney() - state.startMoney
        local byBag = boosted and math.max(0, -delta) or math.max(0, delta)
        if byBag > 0 then
            gold = byBag
            HB:Debug("Gold from bag-delta fallback: %d", gold)
        end
    end

    HB:Debug("Trade complete (mode=%s partner=%s target=%s gold=%d)",
             boosted and "boosted" or "booster", tostring(partnerKey), tostring(targetKey), gold)

    local prompt = HB.db.settings.autoPrompt
    if prompt and HB.db.settings.promptOnGoldOnly and gold <= 0 then prompt = false end

    -- Pricing (booster mode only): figure out which dungeon's price applies,
    -- the suggested run count, and whether this is an underpayment.
    local dungeon, price, suggested, underpaid = nil, 0, nil, false
    if not boosted then
        dungeon = HB:GetTradeDungeon()
        price   = HB:GetPrice(dungeon)
        if price > 0 and gold > 0 then
            suggested = math.floor(gold / price)
            underpaid = (gold < price)  -- not enough for even one run
        end
    end

    if prompt and targetKey then
        local existing = HB:GetCount(targetKey) or 0
        local dlg = StaticPopupDialogs["HAPPYBOOSTER_RUN_INPUT"]
        local paidStr = (gold > 0) and HB:FormatMoney(gold) or "nothing"

        if boosted then
            -- Clearer wording: the partner received the gold; YOUR run count is being set.
            if existing > 0 then
                dlg.text = "You paid |cFFFFD700%s|r " .. paidStr ..
                           ".\n(You have " .. existing .. " runs left.)" ..
                           "\nHow many MORE runs did you buy from them?"
            else
                dlg.text = "You paid |cFFFFD700%s|r " .. paidStr ..
                           ".\nHow many runs did you buy from them?"
            end
        else
            -- booster mode: show the pricing math when we have a price
            local who = "|cFFFFD700%s|r"
            local where = dungeon and (" -- " .. HB:PrettyDungeon(dungeon)) or ""
            if price > 0 then
                local rate = "(" .. HB:FormatMoney(price) .. "/run" .. where .. ")"
                if underpaid then
                    dlg.text = "|cFFFF6666UNDERPAID|r: " .. who .. " paid only " ..
                               paidStr .. ".\nExpected " .. HB:FormatMoney(price) ..
                               " per run" .. where .. ".\nSet 0 runs (or override):"
                elseif existing > 0 then
                    dlg.text = who .. " paid " .. paidStr .. " " .. rate ..
                               "\n(" .. existing .. " left). Add how many MORE runs?"
                else
                    dlg.text = who .. " paid " .. paidStr .. " " .. rate ..
                               "\nConfirm runs:"
                end
            else
                -- no price set: behave like before
                if existing > 0 then
                    dlg.text = "Trade with " .. who .. " complete (" .. existing ..
                               " left).\nHow many MORE runs paid for?"
                else
                    dlg.text = "Trade with " .. who .. " complete.\nHow many runs paid for?"
                end
            end
        end

        local data = {
            key = targetKey,
            copper = gold,
            mode = "trade",
            suggest = underpaid and 0 or suggested,
            dungeon = dungeon,
            price = price,
            underpaid = underpaid,
        }
        StaticPopup_Show("HAPPYBOOSTER_RUN_INPUT", HB:PrettyName(partnerKey), nil, data)
    elseif targetKey then
        local goldStr = (gold and gold > 0) and (" -- paid " .. HB:FormatMoney(gold)) or ""
        HB:Print("Trade with %s complete%s. Open |cffffff00/hb|r to set runs.",
                 HB:Hi(HB:PrettyName(partnerKey)), goldStr)
    end

    -- Optional: pop the window open briefly so the booster sees the updated
    -- counts immediately. Disabled by default; toggled in Settings.
    if HB.db.settings.autoOpenAfterTrade and HB.UI and HB.UI.Show and HB.UI.Hide then
        local wasShown = HB.UI.frame and HB.UI.frame:IsShown()
        if not wasShown then
            HB.UI:Show()
            local dur = tonumber(HB.db.settings.autoOpenSeconds) or 6
            C_Timer.After(dur, function()
                -- Only auto-close if the user didn't keep it open by interacting.
                if HB.UI.frame and HB.UI.frame:IsShown() and not HB.UI.frame:IsMouseOver() then
                    HB.UI:Hide()
                end
            end)
        end
    end
end

-- Delayed cleanup. We do NOT reset on TRADE_CLOSED, because on Classic the
-- "Trade complete." message arrives just AFTER the window closes. We wait a
-- moment: if completion was handled, reset; if not but our gold changed, the
-- trade clearly happened (message just missed) so handle it; otherwise it was
-- a cancel. tradeGen guards against a new trade starting during the wait.
local function ScheduleCleanup()
    local myGen = tradeGen
    C_Timer.After(1.0, function()
        if tradeGen ~= myGen then return end
        if not state.handled and state.partnerName and state.startMoney and GetMoney then
            if GetMoney() ~= state.startMoney then
                HB:Debug("No trade-complete msg, but gold changed -> treating as complete")
                HandleComplete()
            end
        end
        if tradeGen == myGen then ResetState() end
    end)
end

tradeFrame:RegisterEvent("TRADE_SHOW")
tradeFrame:RegisterEvent("TRADE_CLOSED")
tradeFrame:RegisterEvent("TRADE_ACCEPT_UPDATE")
tradeFrame:RegisterEvent("TRADE_REQUEST_CANCEL")
tradeFrame:RegisterEvent("TRADE_MONEY_CHANGED")
tradeFrame:RegisterEvent("PLAYER_TRADE_MONEY")
tradeFrame:RegisterEvent("UI_INFO_MESSAGE")
tradeFrame:RegisterEvent("UI_ERROR_MESSAGE")  -- "Trade complete." can arrive here too

tradeFrame:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "TRADE_SHOW" then
        HB:Debug("TRADE_SHOW")
        ResetState()
        tradeGen = tradeGen + 1
        state.startMoney = GetMoney and GetMoney() or nil
        CapturePartner()
        if not state.partnerName then C_Timer.After(0.1, CapturePartner) end
        -- Poll the live trade money a few times a second. Relying only on
        -- TRADE_MONEY_CHANGED can miss an edit (the event isn't always reliable),
        -- which would leave a stale amount; polling self-heals to the current value.
        if moneyTicker then moneyTicker:Cancel() end
        if C_Timer and C_Timer.NewTicker then
            moneyTicker = C_Timer.NewTicker(0.25, function() CaptureMoney("POLL") end)
        end

    elseif event == "TRADE_ACCEPT_UPDATE" then
        state.playerOK = (a1 == 1)
        state.targetOK = (a2 == 1)
        state.armed    = state.playerOK and state.targetOK
        CaptureMoney("ACCEPT")  -- offers are locked here, before close
        HB:Debug("TRADE_ACCEPT_UPDATE player=%s target=%s armed=%s",
                 tostring(a1), tostring(a2), tostring(state.armed))

    elseif event == "TRADE_MONEY_CHANGED" then
        CaptureMoney("MONEY_CHANGED")

    elseif event == "PLAYER_TRADE_MONEY" then
        CaptureMoney("PLAYER_MONEY")

    elseif event == "UI_INFO_MESSAGE" or event == "UI_ERROR_MESSAGE" then
        -- "Trade complete." is the authoritative completion signal on Classic.
        local errType, msg
        if type(a1) == "number" then errType, msg = a1, a2 else msg = a1 end
        local done = false
        if errType and _G.LE_GAME_ERR_TRADE_COMPLETE and errType == LE_GAME_ERR_TRADE_COMPLETE then
            done = true
        elseif msg and ERR_TRADE_COMPLETE and msg == ERR_TRADE_COMPLETE then
            done = true
        end
        if done then
            HB:Debug("Trade complete detected via %s", event)
            HandleComplete()
            ScheduleCleanup()
        end

    elseif event == "TRADE_REQUEST_CANCEL" then
        -- Don't reset synchronously; let the delayed cleanup decide (a real
        -- completion message may still be on its way).
        ScheduleCleanup()

    elseif event == "TRADE_CLOSED" then
        HB:Debug("TRADE_CLOSED (armed=%s partner=%s)", tostring(state.armed), tostring(state.partnerName))
        if moneyTicker then moneyTicker:Cancel(); moneyTicker = nil end
        -- Some clients DO deliver both-accepted; honor it as a secondary path.
        if state.armed and state.partnerName then HandleComplete() end
        ScheduleCleanup()
    end
end)
