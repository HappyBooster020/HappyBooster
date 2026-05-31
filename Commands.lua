--[[----------------------------------------------------------------------------
    HappyBooster - Commands.lua
    The window is the primary interface; these remain for power users and for
    setting counts on players who aren't currently in your group.
------------------------------------------------------------------------------]]

local addonName, HB = ...

local function Help()
    HB:Print("Window: |cffffff00/hb|r  (or the minimap coin, or a key binding)")
    print("  |cffffff00/hb mode booster|boosted|r - switch tracking mode")
    print("  |cffffff00/hb set <name|self> <n>|r  - set a player's runs")
    print("  |cffffff00/hb add <name|self> <±n>|r - adjust a player's runs")
    print("  |cffffff00/hb reset <name|self>|r    - clear a player")
    print("  |cffffff00/hb resetall|r             - clear current mode's data")
    print("  |cffffff00/hb wipe|r                 - clear EVERYTHING (both modes)")
    print("  |cffffff00/hb count|r                - count 1 run for the group")
    print("  |cffffff00/hb pin|r                  - pin selected target (saved from Clear list)")
    print("  |cffffff00/hb session [reset]|r      - show or reset today's totals")
    print("  |cffffff00/hb stats [clear]|r        - lifetime top customers")
    print("  |cffffff00/hb price <dungeon> <g>|r  - set per-dungeon price (SM, BRD, ZG etc. work)")
    print("  |cffffff00/hb selling <dungeon>|r    - override which dungeon's price applies")
    print("  |cffffff00/hb announce|r             - post current standings to party/raid chat now")
    print("  |cffffff00/hb alt <name>|r           - mark/unmark a name as your own alt (hides from booster list)")
    print("  |cffffff00/hb alts|r                 - list characters flagged as your alts")
    print("  |cffffff00/hb minimap|r              - toggle the minimap button")
    print("  |cffffff00/hb font <6-48>|r          - on-frame number size")
    print("  |cffffff00/hb pos <ANCHOR> [x] [y]|r - on-frame number position")
    print("  |cffffff00/hb history|r              - last 20 events")
end

local function ResolveKey(arg)
    if not arg or arg == "" then return nil end
    local low = arg:lower()
    if low == "self" or low == "me" or low == "player" then
        return HB:GetUnitKey("player")
    end
    if arg:find("-") then
        local n, r = arg:match("^(.-)%-(.+)$")
        if n and r then return HB:GetNameKey(n, r) end
    end
    for _, unit in ipairs(HB:IterateGroupUnits(true)) do
        if UnitExists(unit) then
            local name = UnitName(unit)
            if name and name:lower() == low then return HB:GetUnitKey(unit) end
        end
    end
    for key in pairs(HB.db.runs) do
        local short = (key:match("^(.-)%-") or key):lower()
        if short == low then return key end
    end
    return HB:GetNameKey(arg, nil)
end

local function Handle(msg)
    local args = {}
    for w in (msg or ""):gmatch("%S+") do args[#args + 1] = w end
    local cmd = (args[1] or ""):lower()

    if cmd == "" then
        HB.UI:Toggle()

    elseif cmd == "help" then
        Help()

    elseif cmd == "mode" then
        local m = (args[2] or ""):lower()
        if m == "booster" or m == "boosted" then
            HB:SetMode(m)
            HB:Print("Mode: |cFFFFD700%s|r", m:upper())
            HB:Changed()
        else
            HB:Print("Usage: /hb mode booster|boosted (now: %s)", HB:GetMode())
        end

    elseif cmd == "set" then
        local key, n = ResolveKey(args[2]), tonumber(args[3])
        if key and n and n >= 0 then
            HB:SetCount(key, n, n)
            HB:Print("Set %s to %d.", HB:PrettyName(key), n)
        else
            HB:Print("Usage: /hb set <name|self> <runs>")
        end

    elseif cmd == "add" then
        local key, n = ResolveKey(args[2]), tonumber(args[3])
        if key and n then
            HB:AdjustCount(key, n)
            HB:Print("%s now at %d.", HB:PrettyName(key), (HB:GetCount(key) or 0))
        else
            HB:Print("Usage: /hb add <name|self> <+/-amount>")
        end

    elseif cmd == "reset" then
        local key = ResolveKey(args[2])
        if key then HB:ResetPlayer(key); HB:Print("Cleared %s.", HB:PrettyName(key))
        else HB:Print("Usage: /hb reset <name|self>") end

    elseif cmd == "resetall" then
        HB:ResetAll(); HB:Print("All counts in current mode cleared.")

    elseif cmd == "wipe" then
        HB:ResetAll("all"); HB:Print("Everything cleared (both modes).")

    elseif cmd == "count" then
        local n = HB:DecrementGroup("/hb count")
        if n > 0 then
            HB:Print("Counted 1 run (%d affected).", n)
        else
            HB:Print("No tracked players in your group to count.")
        end

    elseif cmd == "announce" then
        HB:AnnounceStandings(HB.lastDungeon, false)

    elseif cmd == "alt" then
        -- Toggle whether a name is treated as one of this account's own
        -- characters. Flagged keys are hidden from the booster-mode customer
        -- list. Useful when you can't (or don't want to) log into the alt
        -- just to register it. Same realm is assumed when the name has no
        -- "-Realm" suffix.
        local key = ResolveKey(args[2])
        if not key then
            HB:Print("Usage: /hb alt <name>   (toggles flagged status)")
        else
            HB.db.knownAlts = HB.db.knownAlts or {}
            if HB.db.knownAlts[key] then
                HB.db.knownAlts[key] = nil
                HB:Print("|cFFFFD700%s|r is no longer flagged as your alt.",
                         HB:PrettyName(key))
            else
                HB.db.knownAlts[key] = true
                HB:Print("|cFFFFD700%s|r flagged as your alt -- hidden from booster list.",
                         HB:PrettyName(key))
            end
            HB:Changed()
        end

    elseif cmd == "alts" then
        local names = {}
        for k in pairs(HB.db.knownAlts or {}) do names[#names + 1] = k end
        table.sort(names)
        if #names == 0 then
            HB:Print("No alts flagged. (Use |cffffff00/hb alt <name>|r to flag one.)")
        else
            HB:Print("Flagged alts (hidden from booster list):")
            for _, k in ipairs(names) do
                print("   - " .. HB:PrettyName(k) .. "  |cFF888888(" .. k .. ")|r")
            end
        end

    elseif cmd == "price" then
        -- Forms: /hb price                            (list)
        --        /hb price <gold>                     (set default, single number)
        --        /hb price default <gold>             (set default explicit)
        --        /hb price <dungeon name...> <gold>   (last token is price, rest is name)
        --        /hb price clear <dungeon name...>    (remove a per-dungeon price)
        if #args <= 1 then
            local list = HB:ListPrices()
            HB:Print("Per-dungeon prices (price per run):")
            local any = false
            for _, p in ipairs(list) do
                if p.copper and p.copper > 0 then
                    local label = (p.name == "__default") and "(default)" or p.name
                    print(("   %s : %s"):format(label, HB:FormatMoney(p.copper)))
                    any = true
                end
            end
            if not any then HB:Print("(no prices set -- popup will be manual)") end
            HB:Print("Set:  /hb price <dungeon> <gold>   |   /hb price default <gold>   |   /hb price clear <dungeon>")
        elseif args[2]:lower() == "clear" and #args >= 3 then
            local name = table.concat(args, " ", 3)
            HB:SetPrice(name, 0)
            HB:Print("Cleared price for: %s", name)
        else
            -- last token is the price (supports decimals like 12.5 = 12g50s)
            local priceTok = args[#args]
            local goldNum = tonumber(priceTok)
            local name = (args[2]:lower() == "default") and "__default"
                         or table.concat(args, " ", 2, #args - 1)
            -- Single-number form: "/hb price 12" => sets default
            if #args == 2 and goldNum then name = "__default" end
            if not goldNum or goldNum < 0 then
                HB:Print("Usage: /hb price <dungeon> <gold>   (gold can be decimal, e.g. 12.5)")
            else
                local copper = math.floor(goldNum * 10000 + 0.5)
                HB:SetPrice(name, copper)
                local label = (name == "__default") and "default" or name
                HB:Print("Price set: %s = %s per run", label, HB:FormatMoney(copper))
            end
        end

    elseif cmd == "selling" then
        local name = table.concat(args, " ", 2)
        if name == "" or name:lower() == "clear" or name:lower() == "off" then
            HB:SetSellingOverride(nil)
            HB:Print("Selling override cleared. Now using auto-detected dungeon.")
        else
            HB:SetSellingOverride(name)
            local resolved = HB.sellingOverride or name
            HB:Print("Selling override: |cFFFFD700%s|r (used for trade pricing).", resolved)
        end

    elseif cmd == "minimap" then
        HB.Minimap:SetShown(HB.db.minimap.hide)
        HB:Print("Minimap button: %s", HB.db.minimap.hide and "OFF" or "ON")

    elseif cmd == "font" then
        local s = tonumber(args[2])
        if s and s >= 6 and s <= 48 then
            HB.db.settings.fontSize = s; HB:UpdateAllFrames()
            HB:Print("Font size = %d", s)
        else HB:Print("Usage: /hb font <6-48>") end

    elseif cmd == "pos" then
        local a = (args[2] or ""):upper()
        local valid = { TOPLEFT=1, TOP=1, TOPRIGHT=1, LEFT=1, CENTER=1,
                        RIGHT=1, BOTTOMLEFT=1, BOTTOM=1, BOTTOMRIGHT=1 }
        if valid[a] then
            HB.db.settings.textPosition = a
            local x, y = tonumber(args[3]), tonumber(args[4])
            if x then HB.db.settings.textOffsetX = x end
            if y then HB.db.settings.textOffsetY = y end
            HB:UpdateAllFrames()
            HB:Print("Anchor = %s (%s, %s)", a,
                     tostring(HB.db.settings.textOffsetX), tostring(HB.db.settings.textOffsetY))
        else
            HB:Print("Usage: /hb pos TOPRIGHT|CENTER|... [x] [y]")
        end

    elseif cmd == "history" then
        HB:ShowHistory()

    elseif cmd == "debug" then
        HB.db.settings.debug = not HB.db.settings.debug
        HB:Print("Debug: %s", HB.db.settings.debug and "ON" or "OFF")

    elseif cmd == "session" then
        local sub = (args[2] or ""):lower()
        if sub == "reset" then
            HB.db.session = { startTs = time(), runs = 0, copperReceived = 0,
                              copperPaid = 0, customers = {} }
            HB:Print("Session totals reset.")
        else
            HB:Print(HB:SessionSummary())
        end

    elseif cmd == "pin" then
        if not UnitExists("target") or not UnitIsPlayer("target") then
            HB:Print("Select a player as your target first, then /hb pin.")
        else
            local key = HB:GetUnitKey("target")
            if key then
                local nowPinned = HB:TogglePin(key)
                HB:Print("|cFFFFD700%s|r is now %s.", HB:PrettyName(key),
                         nowPinned and "|cFF66FF66pinned|r (kept on Clear list)" or "|cFFAAAAAAunpinned|r")
                HB:Changed()
            end
        end

    elseif cmd == "stats" then
        local sub = (args[2] or ""):lower()
        if sub == "clear" then
            HB.db.stats = {}
            HB:Print("All customer stats cleared.")
            HB:Changed()
        else
            -- Show top customers by lifetime trades.
            local list = {}
            for k, s in pairs(HB.db.stats or {}) do
                list[#list + 1] = { key = k, s = s }
            end
            table.sort(list, function(a, b) return (a.s.trades or 0) > (b.s.trades or 0) end)
            if #list == 0 then HB:Print("No customer stats yet."); return end
            HB:Print("Top customers (lifetime):")
            for i = 1, math.min(10, #list) do
                local e = list[i]
                print(("  %s%s  --  %d trade(s), %d runs bought, %s total")
                      :format(HB:PrettyName(e.key),
                              e.s.pinned and "  |cFF66FF66*|r" or "",
                              e.s.trades or 0, e.s.totalRunsBought or 0,
                              HB:FormatMoney(e.s.totalCopper or 0)))
            end
        end

    else
        Help()
    end
end

SLASH_HAPPYBOOSTER1 = "/hb"
SLASH_HAPPYBOOSTER2 = "/happybooster"
SlashCmdList["HAPPYBOOSTER"] = Handle

-- Build UI + minimap once the DB is ready.
function HB:OnDBReady()
    if HB.Minimap then HB.Minimap:Create() end
end
