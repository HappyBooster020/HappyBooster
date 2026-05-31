--[[----------------------------------------------------------------------------
    HappyBooster - Core.lua
    Initialization, saved variables, shared utilities, and the run-count store.

    Public API used by the other modules:
      HB:IsBoosted()                       -> bool
      HB:GetUnitKey(unit) / GetNameKey(n,r)-> "Name-Realm"
      HB:PrettyName(key)                   -> short display name
      HB:IterateGroupUnits(includePlayer)  -> { "party1", ... } or { "raid1", ... }
      HB:GetCount(key)                     -> remaining, total
      HB:SetCount(key, remaining, total)
      HB:AdjustCount(key, delta)
      HB:ResetPlayer(key) / HB:ResetAll()
      HB:DecrementGroup(reason)            -> number of counters advanced
      HB:CountRun(reason[, lockKey])       -> dedupe-locked run count
      HB:Changed()                         -> refresh frames + window
------------------------------------------------------------------------------]]

local addonName, HB = ...
_G.HappyBooster = HB

-- ----------------------------------------------------------------------------
-- Workaround for a long-standing Classic Era Blizzard bug:
-- Blizzard_ReadyCheck/Classic/ReadyCheck.lua calls GetDifficultyInfo(nil)
-- in certain zones during a ready check, and GetDifficultyInfo doesn't
-- handle nil -- it raises an error and pops up the Lua error frame on every
-- ready check. Since boost sessions ready-check constantly, this is brutal.
-- We wrap the global so nil safely returns nil. Harmless to other addons.
-- ----------------------------------------------------------------------------
do
    local orig = _G.GetDifficultyInfo
    if orig then
        _G.GetDifficultyInfo = function(id, ...)
            if id == nil then return nil end
            return orig(id, ...)
        end
    end
end

HB.version   = "3.15.4"
HB.addonName = addonName

-- Flavor detection
HB.isRetail  = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
HB.isClassic = (WOW_PROJECT_ID == WOW_PROJECT_CLASSIC)

-- Login hooks. Modules append a function here instead of redefining
-- HB:OnLogin (which previously caused Frames.lua to silently clobber Core's
-- own login routine). Core fires HB:OnLogin first, then every hook in order.
HB.onLoginHooks = {}

-- Master event frame
HB.frame = CreateFrame("Frame", "HappyBoosterEventFrame", UIParent)

-- ----------------------------------------------------------------------------
-- Defaults
-- ----------------------------------------------------------------------------
HB.defaults = {
    settings = {
        mode             = "booster",  -- LEGACY: fallback only. Per-character
                                       -- mode lives in modeByChar (below).
        defaultRuns      = 5,
        autoPrompt       = true,       -- popup after a trade
        countDown        = true,       -- count down to 0 (true) or up from 0 (false)
        showOnFrames     = true,       -- on-frame counter overlay
        requireBossKill  = false,      -- OPTIONAL strict mode: only count if a boss died. Off by default (boosting is often trash farming).
        minRunSeconds    = 12,         -- ignore instance visits shorter than this (avoids counting accidental zone-outs)
        promptOnGoldOnly = false,      -- only prompt when gold changed hands (off: always prompt)
        autoOpenAfterTrade = false,    -- pop the window open for a few seconds after a trade
        autoOpenOnEnter    = false,    -- open window when entering a dungeon (booster mode + tracked customers in group)
        autoOpenSeconds  = 6,          -- how long it stays open in auto-open mode
        autoAnnounce     = false,      -- BOOSTED only: announce automatically when down to 1 or 0 runs left
        fontSize         = 16,
        textPosition     = "TOPRIGHT",
        textOffsetX      = 6,          -- pill overhangs to the right
        textOffsetY      = 6,          -- pill overhangs upward
        textColor        = { 1.00, 0.82, 0.00, 1 },
        zeroColor        = { 1.00, 0.20, 0.20, 1 },
        debug            = false,
    },
    window  = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0, shown = false },
    minimap = { angle = 215, hide = false },
    runs    = {},   -- [key] = { remaining, total, lastUpdate }
    history = {},   -- capped log
    -- Per-dungeon price-per-run, in copper. Keys are lowercase dungeon names
    -- as they appear in GetInstanceInfo. "__default" is used when no entry
    -- matches the current dungeon. 0 = no price set (manual count, like before).
    prices  = { __default = 0 },
    -- Persistent per-customer stats. Lifetime totals across all sessions.
    --   [key] = { trades = N, totalCopper = C, totalRunsBought = R, firstSeen = ts, lastSeen = ts, pinned = bool }
    stats   = {},
    -- Current session totals (reset on /reload, login, or /hb session reset).
    session = { startTs = nil, runs = 0, copperReceived = 0, copperPaid = 0, customers = {} },
    -- Per-character mode (v3.14+). Each character on the account remembers
    -- whether it's a booster or being boosted. The mode toggle writes here
    -- under the current character's key. Falls back to settings.mode for any
    -- character that has never been seen post-update.
    modeByChar = {},  -- [charKey] = "booster" | "boosted"
    -- Set of character keys that have ever logged in on this account. Used
    -- to filter the booster-mode customer list -- you don't want your own
    -- boosted alts showing up alongside actual customers.
    knownAlts = {},   -- [charKey] = true
}

-- (Boss-kill gating is off by default for all flavors; boosting is usually
-- trash farming, so a run is detected by leaving / resetting the instance.)

-- ----------------------------------------------------------------------------
-- Output
-- ----------------------------------------------------------------------------
function HB:Print(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    print("|cFFFFD700[HappyBooster]|r " .. tostring(msg))
end

function HB:Debug(msg, ...)
    if HB.db and HB.db.settings.debug then
        if select("#", ...) > 0 then msg = msg:format(...) end
        print("|cFF888888[HB Debug]|r " .. tostring(msg))
    end
end

-- Formatting helpers for clean, readable output (NIT-style).
-- Money: native coin string if available, else "1g95s36c" with colored letters.
function HB:FormatMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper <= 0 then return "0|cFFEDA55Fc|r" end
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local out = {}
    if g > 0 then out[#out+1] = g .. "|cFFFFD700g|r" end
    if s > 0 then out[#out+1] = s .. "|cFFC7C7C7s|r" end
    if c > 0 or #out == 0 then out[#out+1] = c .. "|cFFEDA55Fc|r" end
    return table.concat(out)
end

-- Highlight a value in gold so it pops in a sentence.
function HB:Hi(v) return "|cFFFFD700" .. tostring(v) .. "|r" end

-- ----------------------------------------------------------------------------
-- Mode (per-character)
-- ----------------------------------------------------------------------------
-- Each character on the account remembers its own mode (booster vs boosted),
-- so the boost-seller's alt doesn't open in BOOSTED just because a customer
-- alt left it that way. Falls back to settings.mode for any character that
-- predates the per-character store (legacy, or never toggled post-update).
function HB:GetMode()
    if not HB.db then return "booster" end
    local selfKey = HB:GetUnitKey("player")
    if selfKey and HB.db.modeByChar and HB.db.modeByChar[selfKey] then
        return HB.db.modeByChar[selfKey]
    end
    return HB.db.settings.mode or "booster"
end

function HB:SetMode(newMode)
    if newMode ~= "booster" and newMode ~= "boosted" then return end
    if not HB.db then return end
    local selfKey = HB:GetUnitKey("player")
    if selfKey then
        HB.db.modeByChar = HB.db.modeByChar or {}
        HB.db.modeByChar[selfKey] = newMode
    end
    -- Keep settings.mode in sync as the fallback for legacy paths that still
    -- read it directly. Harmless and means new chars start in whatever the
    -- account last used.
    HB.db.settings.mode = newMode
end

function HB:IsBoosted()
    return HB:GetMode() == "boosted"
end

-- Returns whether a player key is one of this account's own characters. Used
-- to filter the booster-mode customer list so your own alts don't appear
-- alongside actual customers. The set is built by IsKnownAlt being called
-- (via OnLogin) for every character that logs in post-update.
function HB:IsKnownAlt(key)
    if not key or not HB.db or not HB.db.knownAlts then return false end
    return HB.db.knownAlts[key] == true
end

-- ----------------------------------------------------------------------------
-- Name / realm keys
-- ----------------------------------------------------------------------------
local function NormalizeRealm(realm)
    if not realm or realm == "" then
        realm = GetNormalizedRealmName() or GetRealmName() or ""
    end
    return (realm:gsub("[%s%-']", ""))
end

function HB:GetUnitKey(unit)
    if not unit or not UnitExists(unit) then return nil end
    local name, realm = UnitName(unit)
    if not name or name == "" or name == UNKNOWNOBJECT then return nil end
    return name .. "-" .. NormalizeRealm(realm)
end

function HB:GetNameKey(name, realm)
    if not name or name == "" then return nil end
    if name:find("-") and (not realm or realm == "") then
        local n, r = name:match("^(.-)%-(.+)$")
        if n and r then return n .. "-" .. NormalizeRealm(r) end
    end
    return name .. "-" .. NormalizeRealm(realm)
end

function HB:PrettyName(key)
    if not key then return "?" end
    if Ambiguate then return Ambiguate(key, "short") end
    return key:match("^(.-)%-") or key
end

-- ----------------------------------------------------------------------------
-- Group iteration
-- ----------------------------------------------------------------------------
function HB:IterateGroupUnits(includePlayer)
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            units[#units + 1] = "raid" .. i
        end
    else
        if includePlayer then units[#units + 1] = "player" end
        local n = (GetNumSubgroupMembers and GetNumSubgroupMembers())
                  or math.max(0, GetNumGroupMembers() - 1)
        for i = 1, n do
            units[#units + 1] = "party" .. i
        end
    end
    return units
end

-- List of {key=..., unit=...} for current group members (excludes player in
-- booster mode, returns only the player in boosted mode).
function HB:GetGroupTargets()
    local out = {}
    if HB:IsBoosted() then
        local key = HB:GetUnitKey("player")
        if key then out[#out + 1] = { key = key, unit = "player" } end
        return out
    end
    for _, unit in ipairs(HB:IterateGroupUnits(false)) do
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local key = HB:GetUnitKey(unit)
            if key then out[#out + 1] = { key = key, unit = unit } end
        end
    end
    return out
end

-- ----------------------------------------------------------------------------
-- Per-dungeon pricing (booster mode). Prices are stored in copper, keyed by
-- lowercase dungeon name. "__default" is the fallback when no entry matches.
-- A price of 0 means "no price set" -> popup falls back to manual count.
-- ----------------------------------------------------------------------------
local function NormKey(name)
    return name and tostring(name):lower():gsub("^%s+", ""):gsub("%s+$", "") or nil
end

-- Common Classic Era / Cata dungeon abbreviations. Lowercased on both sides.
-- Resolving an alias returns the canonical (lowercased) dungeon name as it
-- would be reported by GetInstanceInfo. Unknown values pass through as-is.
HB.DungeonAliases = {
    ["rfc"]   = "ragefire chasm",
    ["wc"]    = "wailing caverns",
    ["dm"]    = "the deadmines",                 -- DM is ambiguous (Dire Maul) but Deadmines is the level-bracket-popular one
    ["vc"]    = "the deadmines",                 -- "Van Cleef" / Deadmines
    ["sfk"]   = "shadowfang keep",
    ["bfd"]   = "blackfathom deeps",
    ["stocks"]= "the stockade",
    ["stockade"]="the stockade",
    ["gnomer"]= "gnomeregan",
    ["rfk"]   = "razorfen kraul",
    ["sm"]    = "scarlet monastery",
    ["smgy"]  = "scarlet monastery",             -- graveyard wing (same instance name)
    ["smlib"] = "scarlet monastery",
    ["smarm"] = "scarlet monastery",
    ["smcath"]= "scarlet monastery",
    ["rfd"]   = "razorfen downs",
    ["uld"]   = "uldaman",
    ["zf"]    = "zul'farrak",
    ["mara"]  = "maraudon",
    ["st"]    = "the temple of atal'hakkar",     -- sunken temple
    ["sunken"]= "the temple of atal'hakkar",
    ["brd"]   = "blackrock depths",
    ["lbrs"]  = "lower blackrock spire",
    ["ubrs"]  = "upper blackrock spire",
    ["dme"]   = "dire maul",
    ["dmw"]   = "dire maul",
    ["dmn"]   = "dire maul",
    ["dire"]  = "dire maul",
    ["strat"] = "stratholme",
    ["scholo"]= "scholomance",
    -- Raids people sometimes boost lowbies in
    ["zg"]    = "zul'gurub",
    ["aq20"]  = "ruins of ahn'qiraj",
    ["mc"]    = "molten core",
    ["ony"]   = "onyxia's lair",
}

-- The set of canonical dungeon names (every value the alias table resolves
-- to). NormalizeDungeon uses it to fold "the"-prefixed spellings together.
HB.DungeonCanon = {}
for _, v in pairs(HB.DungeonAliases) do HB.DungeonCanon[v] = true end

-- Capital-city qualifiers boosters sometimes prepend ("SW Stockade"). Stripped
-- so the rest can resolve. No real instance name starts with these, so it's safe.
local DUNGEON_PREFIXES = {
    "sw ", "stormwind ", "if ", "ironforge ", "darnassus ", "darn ",
    "og ", "orgrimmar ", "uc ", "undercity ", "tb ", "thunder bluff ",
}

-- Fold any spelling of a dungeon into ONE canonical key. This is the single
-- chokepoint: /hb price, /hb selling, auto-detect, and the trade picker all
-- route through here, so "Stockade", "SW Stockade" and "The Stockade" can
-- never fragment into three separate price rows. Unknown dungeons pass through
-- as a cleaned-up key (so custom names still work, just consistently).
function HB:NormalizeDungeon(name)
    if not name then return nil end
    local k = NormKey(name)
    if not k or k == "" then return nil end
    k = k:gsub("%s+", " ")                       -- collapse internal whitespace
    if HB.DungeonAliases[k] then return HB.DungeonAliases[k] end
    -- strip a leading capital-city qualifier and retry
    for _, p in ipairs(DUNGEON_PREFIXES) do
        if k:sub(1, #p) == p then
            local rest = k:sub(#p + 1)
            if HB.DungeonAliases[rest] then return HB.DungeonAliases[rest] end
            k = rest
            break
        end
    end
    -- "the"-insensitive folding against the canonical set
    if HB.DungeonCanon[k] then return k end
    if HB.DungeonCanon["the " .. k] then return "the " .. k end
    if k:sub(1, 4) == "the " and HB.DungeonCanon[k:sub(5)] then return k:sub(5) end
    if HB.DungeonAliases[k] then return HB.DungeonAliases[k] end
    return k
end

-- Back-compat wrapper: every existing caller used ResolveDungeonAlias. Route
-- it through the hardened normalizer so all paths share one canonical key.
function HB:ResolveDungeonAlias(name)
    return HB:NormalizeDungeon(name)
end

-- Pretty display name for a canonical key. Title-cases words and the letter
-- after an apostrophe: "the stockade" -> "The Stockade",
-- "zul'farrak" -> "Zul'Farrak". "__default" renders as "(default)".
function HB:PrettyDungeon(key)
    if not key or key == "" then return "" end
    if key == "__default" then return "(default)" end
    local s = tostring(key):gsub("%a[%w']*", function(w)
        return w:sub(1, 1):upper() .. w:sub(2)
    end)
    s = s:gsub("'(%a)", function(a) return "'" .. a:upper() end)
    return s
end

function HB:GetPrice(dungeon)
    if not HB.db or not HB.db.prices then return 0 end
    local key = HB:ResolveDungeonAlias(dungeon)
    if key and HB.db.prices[key] and HB.db.prices[key] > 0 then
        return HB.db.prices[key]
    end
    return HB.db.prices.__default or 0
end

function HB:SetPrice(dungeon, copper)
    if not HB.db then return end
    HB.db.prices = HB.db.prices or {}
    copper = math.max(0, math.floor(tonumber(copper) or 0))
    local key = (dungeon and dungeon ~= "" and HB:ResolveDungeonAlias(dungeon)) or "__default"
    if copper == 0 then
        HB.db.prices[key] = nil
    else
        HB.db.prices[key] = copper
    end
end

function HB:ListPrices()
    local out = {}
    if not HB.db or not HB.db.prices then return out end
    for k, v in pairs(HB.db.prices) do
        out[#out + 1] = { name = k, copper = v }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- The dungeon we treat as "currently selling". Order of precedence:
--   1. Explicit override from /hb selling <name>
--   2. The instance we're currently inside, if it's a dungeon/raid
--   3. The last dungeon we were in (tracked by Runs.lua)
function HB:GetActiveDungeon()
    if HB.sellingOverride and HB.sellingOverride ~= "" then
        return HB.sellingOverride
    end
    if IsInInstance and IsInInstance() and GetInstanceInfo then
        local name, itype = GetInstanceInfo()
        if itype == "party" or itype == "raid" or itype == "scenario" then
            return name
        end
    end
    return HB.lastDungeon
end

function HB:SetSellingOverride(name)
    if not name or name == "" then
        HB.sellingOverride = nil
    else
        -- Store the canonical name so it matches GetInstanceInfo's output.
        HB.sellingOverride = HB:ResolveDungeonAlias(name)
    end
end

-- ----------------------------------------------------------------------------
-- Stats: persistent per-customer memory + session totals.
-- HB.db.stats[key] tracks lifetime totals for that player.
-- HB.db.session tracks the current play session only.
-- ----------------------------------------------------------------------------
function HB:RecordTrade(key, copper, runsBought)
    if not key or not HB.db then return end
    HB.db.stats = HB.db.stats or {}
    local s = HB.db.stats[key]
    if not s then
        s = { trades = 0, totalCopper = 0, totalRunsBought = 0,
              firstSeen = time(), lastSeen = time(), pinned = false }
        HB.db.stats[key] = s
    end
    s.trades          = (s.trades or 0) + 1
    s.totalCopper     = (s.totalCopper or 0) + math.max(0, copper or 0)
    s.totalRunsBought = (s.totalRunsBought or 0) + math.max(0, runsBought or 0)
    s.lastSeen        = time()

    -- Stamp the gold-per-run rate on the runs entry so the hover tooltip can
    -- show "remaining gold" accurately even when you switch dungeons mid-deal.
    -- Last-trade-wins: simpler than a weighted average and matches real
    -- behavior (a customer typically pays at one consistent rate per session).
    if HB.db.runs and HB.db.runs[key] and runsBought and runsBought > 0
       and copper and copper > 0 then
        HB.db.runs[key].goldPerRun = math.floor(copper / runsBought + 0.5)
    end

    -- Update session totals.
    HB.db.session = HB.db.session or { customers = {} }
    HB.db.session.customers = HB.db.session.customers or {}
    HB.db.session.customers[key] = true
    if HB:IsBoosted() then
        HB.db.session.copperPaid = (HB.db.session.copperPaid or 0) + math.max(0, copper or 0)
    else
        HB.db.session.copperReceived = (HB.db.session.copperReceived or 0) + math.max(0, copper or 0)
    end
    -- Trigger a Refresh so the session footer + lifetime tooltip pick up the
    -- new totals immediately (ApplyTradeRuns already fired Changed, but that
    -- ran BEFORE this RecordTrade, so without this nudge the footer is stale).
    HB:Changed()
end

-- Compute the gold value of a customer's remaining runs. Uses the rate stored
-- at last trade time first (most accurate to what they actually paid), and
-- falls back to the current dungeon's price if no rate was stamped (e.g. the
-- customer was added via Add Target, not via trade). Returns copper, or nil
-- if nothing reasonable can be computed.
function HB:RemainingGold(key)
    if not key or not HB.db or not HB.db.runs then return nil end
    local e = HB.db.runs[key]
    if not e or not e.remaining or e.remaining <= 0 then return 0 end
    local rate = e.goldPerRun
    if not rate or rate <= 0 then
        -- Fall back to current dungeon price.
        local dn = HB:GetActiveDungeon()
        if dn then rate = HB:GetPrice(dn) end
    end
    if not rate or rate <= 0 then return nil end
    return e.remaining * rate
end

-- Toggle whether a customer is "pinned" (saved from being cleared by Clear list).
function HB:TogglePin(key)
    if not key or not HB.db then return end
    HB.db.stats = HB.db.stats or {}
    local s = HB.db.stats[key] or { trades = 0, totalCopper = 0, totalRunsBought = 0,
                                    firstSeen = time(), lastSeen = time(), pinned = false }
    s.pinned = not s.pinned
    HB.db.stats[key] = s
    return s.pinned
end

function HB:IsPinned(key)
    return key and HB.db and HB.db.stats and HB.db.stats[key] and HB.db.stats[key].pinned or false
end

-- Format a human-readable session summary line for chat or tooltip use.
function HB:SessionSummary()
    local s = HB.db and HB.db.session
    if not s or not s.startTs then return "No session data yet." end
    local secs = time() - s.startTs
    local hrs  = math.floor(secs / 3600)
    local mins = math.floor((secs % 3600) / 60)
    local timeStr = (hrs > 0) and ("%dh %dm"):format(hrs, mins) or ("%dm"):format(mins)
    local nCust = 0
    for _ in pairs(s.customers or {}) do nCust = nCust + 1 end
    local gold = s.copperReceived or 0
    local paid = s.copperPaid or 0
    local net  = gold - paid
    return ("Session: %s  |  %d run(s)  |  %d customer(s)  |  earned %s, paid %s  |  net %s")
           :format(timeStr, s.runs or 0, nCust,
                   HB:FormatMoney(gold), HB:FormatMoney(paid), HB:FormatMoney(net))
end

-- ----------------------------------------------------------------------------
-- Announce standings to party/raid chat.
--   BOOSTER mode -- one header line + one "- Name: N left" line per tracked
--                   group member. Color codes are stripped from player chat
--                   by the server, so this is laid out as clean plain text.
--   BOOSTED mode  -- a single line announcing YOUR remaining runs to the
--                   group ("3 runs left in Maraudon"). Lets the booster know
--                   where you stand without having to ask.
-- ----------------------------------------------------------------------------
function HB:AnnounceStandings(dungeon, auto)
    if not HB.db then return end
    if not IsInGroup() then
        if not auto then HB:Print("You're not in a party or raid.") end
        return
    end
    local channel = IsInRaid() and "RAID" or "PARTY"

    if HB:IsBoosted() then
        local selfKey = HB:GetUnitKey("player")
        local remaining = selfKey and HB:GetCount(selfKey) or 0
        local where = (dungeon and dungeon ~= "") and (" in " .. dungeon) or ""
        local msg
        if not remaining or remaining <= 0 then
            msg = "HappyBooster >> Out of runs -- need to pay for more!"
        elseif remaining == 1 then
            msg = ("HappyBooster >> 1 run left%s -- last one!"):format(where)
        else
            msg = ("HappyBooster >> %d runs left%s."):format(remaining, where)
        end
        SendChatMessage(msg, channel)
        return
    end

    -- Current group members that have a tracked count, in group order.
    local entries = {}
    for _, t in ipairs(HB:GetGroupTargets()) do
        local remaining = HB:GetCount(t.key)
        if remaining ~= nil then
            local label = (remaining <= 0) and "DONE - pay for more!"
                          or (remaining .. " left")
            entries[#entries + 1] = HB:PrettyName(t.key) .. ": " .. label
        end
    end
    if #entries == 0 then
        if not auto then HB:Print("No tracked customers in the group to announce.") end
        return
    end

    -- Recount-style: a header line, then one entry per line with a "- "
    -- prefix. For 5-man boosts (1-4 customers) this is well under any chat
    -- flood threshold. 20-person raid boosts might lose a line or two to
    -- throttling, but those are one-and-done events.
    local header = "HappyBooster >> " ..
                   (dungeon and (dungeon .. " -- ") or "") ..
                   "runs remaining:"
    SendChatMessage(header, channel)
    for _, e in ipairs(entries) do
        SendChatMessage("- " .. e, channel)
    end
end
function HB:Changed()
    if HB.UpdateAllFrames then pcall(function() HB:UpdateAllFrames() end) end
    if HB.UI and HB.UI.Refresh then pcall(function() HB.UI:Refresh() end) end
    if HB.Minimap and HB.Minimap.RefreshTooltip then pcall(function() HB.Minimap:RefreshTooltip() end) end
end

-- ----------------------------------------------------------------------------
-- Count store
-- ----------------------------------------------------------------------------
function HB:GetCount(key)
    if not key or not HB.db.runs[key] then return nil end
    return HB.db.runs[key].remaining, HB.db.runs[key].total
end

function HB:SetCount(key, remaining, total)
    if not key then return end
    remaining = math.max(0, remaining or 0)
    HB.db.runs[key] = HB.db.runs[key] or {}
    HB.db.runs[key].remaining  = remaining
    HB.db.runs[key].total      = total or remaining
    HB.db.runs[key].lastUpdate = time()
    HB:Debug("SetCount %s = %d/%d", key, remaining, HB.db.runs[key].total)
    HB:Changed()
end

function HB:AdjustCount(key, delta, silent)
    if not key then return end
    local e = HB.db.runs[key]
    if not e then
        -- Adjusting an untracked player creates them at max(0, delta).
        HB:SetCount(key, math.max(0, delta), math.max(0, delta))
        return
    end
    local old = e.remaining or 0
    e.remaining = math.max(0, old + delta)
    if e.remaining > (e.total or 0) then e.total = e.remaining end
    e.lastUpdate = time()
    -- Chat feedback so manual +/- adjustments are visible (otherwise the
    -- number on the pill changes but nothing tells you the addon registered it).
    -- The 'silent' param lets internal callers (Undo) suppress per-row prints
    -- and emit one summary line instead.
    if not silent then
        local selfKey = HB:GetUnitKey("player")
        local isSelf  = (key == selfKey)
        local who     = isSelf and "your counter" or HB:PrettyName(key)
        if delta > 0 then
            HB:Print("Added %d run%s to %s -- now %s left.",
                     delta, delta == 1 and "" or "s",
                     HB:Hi(who), HB:Hi(tostring(e.remaining)))
        elseif delta < 0 then
            HB:Print("Removed %d run%s from %s -- now %s left.",
                     -delta, delta == -1 and "" or "s",
                     HB:Hi(who), HB:Hi(tostring(e.remaining)))
        end
        -- If we crossed to zero, fire the same zero-alert DecrementGroup uses
        -- so manual /+/- adjustments feel consistent with auto-counting.
        if old > 0 and e.remaining == 0 then
            if isSelf then
                HB:Print("|cFFFF6666You|r have 0 runs left -- time to pay for more!")
            else
                HB:Print("|cFFFF6666%s|r has 0 runs left -- time to trade!", HB:PrettyName(key))
            end
            if PlaySound then PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960, "Master") end
        end
    end
    HB:Changed()
end

-- Apply runs purchased in a trade.
--   * If the player still has runs left  -> ADD to remaining and total (top-up).
--   * If the player is new or at 0 left   -> start a FRESH batch of n.
-- Returns "added" or "fresh" so callers can phrase messages correctly.
function HB:ApplyTradeRuns(key, n)
    if not key or not n then return end
    n = math.max(0, n)
    local cur = HB:GetCount(key)
    if cur and cur > 0 then
        local e = HB.db.runs[key]
        e.remaining = cur + n
        e.total     = (e.total or cur) + n
        e.lastUpdate = time()
        HB:Debug("Trade top-up %s: %d + %d = %d", key, cur, n, e.remaining)
        HB:Changed()
        return "added"
    else
        HB:SetCount(key, n, n)  -- fresh batch (SetCount fires Changed)
        return "fresh"
    end
end

function HB:ResetPlayer(key)
    if not key then return end
    if HB.db.runs[key] then
        HB:Print("Removed %s from tracking.", HB:Hi(HB:PrettyName(key)))
    end
    HB.db.runs[key] = nil
    HB:Changed()
end

-- Mode-aware reset. In booster mode this clears customer entries (anyone
-- except the player). In boosted mode it clears only the player's own row.
-- Pinned customers (saved via the pin button) are preserved.
-- The session footer is also reset so it matches the now-empty list.
-- Pass scope="all" (e.g. from /hb wipe) to clear absolutely everything,
-- including pinned. The wipe is irreversible.
function HB:ResetAll(scope)
    local selfKey = HB:GetUnitKey("player")
    if scope == "all" then
        wipe(HB.db.runs)
    elseif HB:IsBoosted() then
        if selfKey then HB.db.runs[selfKey] = nil end
    else
        for k in pairs(HB.db.runs) do
            if k ~= selfKey and not HB:IsPinned(k) then HB.db.runs[k] = nil end
        end
    end
    -- Reset session totals so the footer reflects reality. We keep startTs
    -- (you didn't just log in) but zero everything else.
    if HB.db.session then
        local started = HB.db.session.startTs or time()
        HB.db.session = { startTs = started, runs = 0,
                          copperReceived = 0, copperPaid = 0, customers = {} }
    end
    HB:Changed()
end

-- Advance the counter(s) for one completed run.
function HB:DecrementGroup(reason)
    local countDown = HB.db.settings.countDown
    local affected, zeroed = 0, {}
    local selfDecremented, customersDecremented = false, 0

    local function apply(key, isSelf)
        local e = key and HB.db.runs[key]
        if not e then return end
        if countDown then
            if e.remaining > 0 then
                e.remaining = e.remaining - 1
                e.lastUpdate = time()
                affected = affected + 1
                if isSelf then selfDecremented = true
                else customersDecremented = customersDecremented + 1 end
                if e.remaining == 0 then zeroed[#zeroed + 1] = { key = key, isSelf = isSelf } end
            end
        else
            e.remaining = (e.remaining or 0) + 1
            e.lastUpdate = time()
            affected = affected + 1
            if isSelf then selfDecremented = true
            else customersDecremented = customersDecremented + 1 end
        end
    end

    -- ALWAYS try to decrement the player's own row (boosted-side data).
    local selfKey = HB:GetUnitKey("player")
    if selfKey then apply(selfKey, true) end

    -- ALWAYS try to decrement any tracked group members (booster-side data),
    -- regardless of current mode. This way chain-boost scenarios (you're both
    -- being boosted AND boosting customers in the same run) update both sides.
    if IsInGroup() then
        for _, unit in ipairs(HB:IterateGroupUnits(false)) do
            if UnitExists(unit) and not UnitIsUnit(unit, "player") then
                local key = HB:GetUnitKey(unit)
                if key then apply(key, false) end
            end
        end
    end

    if affected > 0 then
        HB:Debug("Advanced %d counter(s) (self=%s, customers=%d, reason=%s)",
                 affected, tostring(selfDecremented), customersDecremented, tostring(reason))
        HB:LogHistory({ type = "run", reason = reason, timestamp = time(), affected = affected })
        -- Session stats: bump the run counter once per "this run is done" event.
        if HB.db and HB.db.session then
            HB.db.session.runs = (HB.db.session.runs or 0) + 1
        end
        HB:Changed()
        for _, z in ipairs(zeroed) do
            if z.isSelf then
                HB:Print("|cFFFF6666You|r have 0 runs left -- time to pay for more!")
            else
                HB:Print("|cFFFF6666%s|r has 0 runs left -- time to trade!", HB:PrettyName(z.key))
            end
            if PlaySound then PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960, "Master") end
        end
        -- Smart auto-announce (BOOSTED mode, opt-in): only fires at the two
        -- moments that matter to the booster -- "down to 1" (so they know to
        -- finish this batch) and "out" (so they know to ask for a trade). Any
        -- more often than that and it's just chat spam.
        if selfDecremented and selfKey and HB:IsBoosted()
           and HB.db.settings.autoAnnounce then
            local remaining = HB:GetCount(selfKey) or 0
            if remaining == 1 or remaining == 0 then
                HB:AnnounceStandings(HB.lastDungeon, true)
            end
        end
        -- Note: the OLD per-run announce is now a manual button in the window
        -- header, not an auto-fire. The booster chooses when to broadcast.
    end
    return affected
end

-- Run counting from automatic signals (leave instance / reset message).
-- A short global cooldown means whichever signal fires first wins, and the
-- others for the same run are ignored. Real runs are minutes apart, so this
-- never blocks legitimate back-to-back runs. Manual counting (the window's
-- "Count run +1" and /hb count) bypasses this by calling DecrementGroup directly.
local AUTO_COOLDOWN = 8
local lastAuto = 0
function HB:CountRun(reason)
    if time() - lastAuto < AUTO_COOLDOWN then
        HB:Debug("Auto run-count ignored (%ds cooldown): %s", AUTO_COOLDOWN, tostring(reason))
        return 0
    end
    lastAuto = time()
    -- Any successful count makes the pending leave-prompt moot.
    if HB.CancelPendingLeave then HB:CancelPendingLeave("CountRun:" .. tostring(reason)) end
    return HB:DecrementGroup(reason)
end

-- ----------------------------------------------------------------------------
-- History (capped)
-- ----------------------------------------------------------------------------
function HB:LogHistory(entry)
    HB.db.history = HB.db.history or {}
    HB.db.history[#HB.db.history + 1] = entry
    while #HB.db.history > 200 do table.remove(HB.db.history, 1) end
end

-- ----------------------------------------------------------------------------
-- DB init + module bootstrap
-- ----------------------------------------------------------------------------
local function MergeDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            MergeDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function Migrate(db)
    db.dbVersion = db.dbVersion or 1
    -- v2: switch from plain-text counter to the corner pill badge, and turn off
    -- the boss-kill requirement that was blocking trash-farm boosting.
    if db.dbVersion < 2 then
        db.settings.requireBossKill = false
        db.settings.textPosition = "TOPRIGHT"
        db.settings.textOffsetX  = 6
        db.settings.textOffsetY  = 6
        db.dbVersion = 2
    end
    -- v3: per-dungeon pricing.
    if db.dbVersion < 3 then
        db.prices = db.prices or { __default = 0 }
        db.dbVersion = 3
    end
    -- v4: persistent stats + session totals + pinned customers.
    if db.dbVersion < 4 then
        db.stats   = db.stats   or {}
        db.session = db.session or {}
        db.dbVersion = 4
    end
    -- v5: per-character mode + known-alt registry. The actual seeding of
    -- modeByChar[selfKey] happens at PLAYER_LOGIN (when the character name
    -- is known), via HB:OnLogin. Migration here just ensures the tables exist.
    if db.dbVersion < 5 then
        db.modeByChar = db.modeByChar or {}
        db.knownAlts  = db.knownAlts  or {}
        db.dbVersion = 5
    end
    -- v6: normalize/dedupe per-dungeon price keys. Earlier versions stored
    -- whatever the booster typed ("Stockade", "SW Stockade", "The Stockade"),
    -- which could fragment into three rows. Fold each key to its canonical
    -- name; on a collision keep the HIGHER price so we never silently
    -- undercharge. __default is preserved untouched.
    if db.dbVersion < 6 then
        if type(db.prices) == "table" then
            local merged = { __default = db.prices.__default or 0 }
            for k, v in pairs(db.prices) do
                if k ~= "__default" then
                    local canon = HB:NormalizeDungeon(k) or k
                    if merged[canon] then
                        merged[canon] = math.max(merged[canon], v)
                    else
                        merged[canon] = v
                    end
                end
            end
            db.prices = merged
        end
        db.dbVersion = 6
    end
end

local function InitDB()
    HappyBoosterDB = HappyBoosterDB or {}
    local db = HappyBoosterDB
    db.settings    = db.settings    or {}
    db.window      = db.window      or {}
    db.minimap     = db.minimap     or {}
    db.runs        = db.runs        or {}
    db.history     = db.history     or {}
    db.prices      = db.prices      or { __default = 0 }
    db.stats       = db.stats       or {}
    db.session     = db.session     or {}
    db.modeByChar  = db.modeByChar  or {}
    db.knownAlts   = db.knownAlts   or {}
    MergeDefaults(db.settings, HB.defaults.settings)
    MergeDefaults(db.window,   HB.defaults.window)
    MergeDefaults(db.minimap,  HB.defaults.minimap)
    Migrate(db)
    -- Each PLAYER_LOGIN starts a fresh session. We deliberately do NOT
    -- preserve session totals across logout: the booster's "today" is a
    -- play-session view, not a calendar day.
    db.session = { startTs = time(), runs = 0, copperReceived = 0, copperPaid = 0, customers = {} }
    HB.db = db
end

-- Called from PLAYER_LOGIN (after the character name is available). Records
-- this character as a known alt, and migrates settings.mode -> modeByChar
-- for any character we haven't seen post-3.14.
function HB:OnLogin()
    local selfKey = HB:GetUnitKey("player")
    if not selfKey then return end
    HB.db.modeByChar = HB.db.modeByChar or {}
    HB.db.knownAlts  = HB.db.knownAlts  or {}
    -- First time we see this character post-3.14? Inherit the legacy mode
    -- (so users who set BOOSTED in an earlier version don't get bumped back
    -- to BOOSTER on the same character).
    if HB.db.modeByChar[selfKey] == nil then
        HB.db.modeByChar[selfKey] = HB.db.settings.mode or "booster"
    end
    HB.db.knownAlts[selfKey] = true
end

HB.frame:RegisterEvent("ADDON_LOADED")
HB.frame:RegisterEvent("PLAYER_LOGIN")
HB.frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then
            InitDB()
            if HB.OnDBReady then HB:OnDBReady() end
        end
    elseif event == "PLAYER_LOGIN" then
        HB:Print("v%s loaded. |cffffff00/hb|r opens the window.", HB.version)
        if HB.OnLogin then HB:OnLogin() end
        for _, hook in ipairs(HB.onLoginHooks) do
            local ok, err = pcall(hook)
            if not ok then HB:Debug("login hook error: %s", tostring(err)) end
        end
    end
end)
