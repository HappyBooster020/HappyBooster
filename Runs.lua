--[[----------------------------------------------------------------------------
    HappyBooster - Runs.lua
    Detects a completed boost run using the signals proven boost addons use:

      1. INSTANCE RESET  - CHAT_MSG_SYSTEM matching the "X has been reset." global
                           string. The canonical boost signal (you reset the
                           dungeon to run it again). Fires for the resetter.
                           Counts immediately.
      2. LEAVE INSTANCE  - you were inside a dungeon/raid/scenario for at least
                           minRunSeconds and then zoned out. We do NOT count
                           immediately here -- the player might be HSing for
                           repair or vendoring. Instead, set a 90-second pending
                           timer; if they return to the same dungeon, cancel.
                           If 90s elapses without return, show a popup asking
                           "Did that run finish? Count it, or not?"
      3. INSTANCE UID    - (v3.13.0+) Each WoW mob GUID embeds a session-unique
                           "instance ID" in its 4th dash-separated field. When
                           the leader resets an instance (no chat broadcast, no
                           NIT in group), that ID changes for the new instance
                           even though the dungeon name + mapID stay the same.
                           On re-entry to a pending-leave dungeon, we wait for
                           the first creature GUID, compare IDs, and either
                           count (different = reset happened) or cancel (same =
                           HS-for-repair return). This closes Case 3 without
                           requiring NIT or any external addon.

    Both signal paths funnel into HB:CountRun, which has a short global cooldown
    so a single run can't be counted twice. Boss kills are NOT required by
    default (boosting is usually trash farming); "requireBossKill" is an
    optional strict mode.
------------------------------------------------------------------------------]]

local addonName, HB = ...

local runFrame = CreateFrame("Frame", "HappyBoosterRunFrame")

local LEAVE_GRACE_SECONDS = 90  -- HS+repair+return window before we prompt

-- Build a Lua pattern from the localized "%s has been reset." global string.
local RESET_PATTERN
if INSTANCE_RESET_SUCCESS then
    RESET_PATTERN = "^" .. INSTANCE_RESET_SUCCESS:gsub("%%s", ".-") .. "$"
end
local function IsResetMessage(msg)
    if not msg then return false end
    if RESET_PATTERN and msg:match(RESET_PATTERN) then return true end
    local low = msg:lower()
    if low:find("has been reset") then return true end  -- English: post-reset announcement
    -- Inside-the-instance reset attempt notification. Blizzard fires this for
    -- non-leader players when the leader resets while they are still inside:
    -- "The party leader has attempted to reset the instance you are in.
    --  Please zone out to allow the instance to reset."
    if low:find("attempted to reset") then return true end
    if low:find("zone out to allow")  then return true end
    return false
end

-- Extract the session-unique instance ID from a WoW GUID.
-- Format: <type>-0-<serverID>-<instanceID>-<zoneUID>-<NPCID>-<spawnUID>
-- Example: "Creature-0-1465-349-12345-12555-000043F59F" -> 12345
-- Returns nil for player GUIDs, unrecognized formats, or instanceID=0 (which
-- means outdoor / not in an instance). The number changes on instance reset
-- even when the dungeon name and mapID stay the same, which is exactly what
-- we need to tell "same instance returned" from "new instance after reset".
local function ExtractInstanceUID(guid)
    if not guid or guid == "" then return nil end
    local utype, _, _, instID = strsplit("-", guid)
    if (utype == "Creature" or utype == "Vehicle"
        or utype == "Pet" or utype == "GameObject") and instID then
        local n = tonumber(instID)
        if n and n > 0 then return n end
    end
    return nil
end

local s = {}
local function ResetSession()
    s.inInstance     = false
    s.mapID          = nil
    s.name           = nil
    s.enterTime      = 0
    s.kills          = 0
    s.alreadyCounted = false  -- set when a reset announcement counts the run
                              -- while the player is still inside; suppresses
                              -- the next smart-leave so we don't double-count.
    s.instanceUID    = nil    -- captured from the first creature GUID we see
                              -- in this instance (via COMBAT_LOG). Used on the
                              -- next re-entry to detect a reset without chat.
end
ResetSession()

local function Countable(t)
    return t == "party" or t == "raid" or t == "scenario"
end

-- The popup that asks the player whether a leave should count as a finished
-- run. Shown 90 seconds after leaving if they haven't returned.
StaticPopupDialogs["HAPPYBOOSTER_CONFIRM_LEAVE_COUNT"] = {
    text = "You left |cFFFFD700%s|r %d seconds ago and haven't returned.\n" ..
           "Did that run finish?\n\n" ..
           "|cFFAAAAAAYes -> count one run (decrements everyone tracked).\n" ..
           "No -> ignore (use if you HS'd for repair, died, etc).|r",
    button1 = "Yes, count it",
    button2 = "No, don't count",
    OnAccept = function(self, data)
        if HB._pendingLeave and data and HB._pendingLeave.token == data.token then
            HB:CountRun("delayed leave " .. (HB._pendingLeave.name or "?"))
        end
        HB._pendingLeave = nil
    end,
    OnCancel = function(self, data)
        if HB._pendingLeave and data and HB._pendingLeave.token == data.token then
            HB:Debug("Leave-count dismissed by user (%s)", tostring(HB._pendingLeave.name))
        end
        HB._pendingLeave = nil
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Schedule the popup. Saves a unique token so a later cancellation (return to
-- same dungeon, reset event, new leave) can invalidate this specific timer.
-- The optional instanceUID is the session-unique ID we captured from a mob
-- GUID before leaving; preserved for the GUID-compare on re-entry.
local function ScheduleLeavePopup(name, mapID, instanceUID)
    local token = {}  -- unique table identity
    HB._pendingLeave = {
        name = name, mapID = mapID, ts = time(),
        token = token, instanceUID = instanceUID,
    }
    C_Timer.After(LEAVE_GRACE_SECONDS, function()
        if HB._pendingLeave and HB._pendingLeave.token == token then
            HB:Debug("Leave-grace expired for %s, prompting user", tostring(name))
            StaticPopup_Show("HAPPYBOOSTER_CONFIRM_LEAVE_COUNT",
                             name or "the dungeon", LEAVE_GRACE_SECONDS,
                             { token = token })
        end
    end)
    HB:Debug("Pending leave for %s (UID=%s, will prompt in %ds if not returned)",
             tostring(name), tostring(instanceUID), LEAVE_GRACE_SECONDS)
end

-- Called when we're confident the run was counted some other way (reset event,
-- /hb count, manual button) -- so the pending leave is no longer needed.
function HB:CancelPendingLeave(why)
    if not HB._pendingLeave then return end
    HB:Debug("Cancelling pending leave (%s): %s", tostring(why), tostring(HB._pendingLeave.name))
    HB._pendingLeave = nil
    -- Also hide the popup if it's currently showing.
    if StaticPopup_Hide then StaticPopup_Hide("HAPPYBOOSTER_CONFIRM_LEAVE_COUNT") end
end

local function UpdateInstanceState()
    local name, itype, _, _, _, _, _, mapID = GetInstanceInfo()
    if IsInInstance() and Countable(itype) then
        -- We're inside a countable instance. If we had a pending leave for
        -- this same dungeon, we have to decide whether to cancel it (same
        -- instance returned, HS-for-repair) or count it (different instance,
        -- a reset happened). When we have a saved instance UID, we don't
        -- decide yet -- we mark "verifying" and let the next creature GUID
        -- we see (in COMBAT_LOG_EVENT_UNFILTERED) make the call. When we
        -- have no saved UID (older pending, no combat in prev run), we fall
        -- back to the previous behavior: silently cancel.
        if HB._pendingLeave and HB._pendingLeave.mapID == mapID then
            if HB._pendingLeave.instanceUID then
                HB._pendingLeave.verifying = true
                HB:Debug("Returned to %s (mapID=%s) -- verifying via instance UID (old=%d)",
                         tostring(name), tostring(mapID), HB._pendingLeave.instanceUID)
            else
                HB:CancelPendingLeave("returned to same instance (no UID captured)")
            end
        end
        if not s.inInstance or s.mapID ~= mapID then
            ResetSession()
            s.inInstance = true
            s.mapID      = mapID
            s.name       = name
            s.enterTime  = time()
            HB.lastDungeon = name
            HB:Debug("Entered %s (%s)", tostring(name), tostring(itype))

            -- Optional: auto-open the window on dungeon entry. Setting works
            -- in both modes; the trigger condition differs.
            --   BOOSTER -- open only if at least one tracked customer is in
            --              the current group (avoids opening the window on
            --              random unrelated dungeon visits).
            --   BOOSTED -- always open (your own row is always relevant when
            --              you're inside a dungeon).
            -- Doesn't auto-close: the user is about to do a run, the window
            -- is useful for the duration. They can close it themselves.
            if HB.db.settings.autoOpenOnEnter
               and HB.UI and HB.UI.Show then
                local shouldOpen = false
                if HB:IsBoosted() then
                    shouldOpen = true
                else
                    for _, t in ipairs(HB:GetGroupTargets()) do
                        if HB.db.runs[t.key] then shouldOpen = true; break end
                    end
                end
                if shouldOpen then
                    local alreadyShown = HB.UI.frame and HB.UI.frame:IsShown()
                    if not alreadyShown then
                        HB:Debug("Auto-opening window on dungeon entry")
                        HB.UI:Show()
                    end
                else
                    HB:Debug("Skipping auto-open on entry: no tracked customers in group")
                end
            end
        end
    else
        if s.inInstance then
            local secs = time() - (s.enterTime or 0)
            local longEnough = secs >= (HB.db.settings.minRunSeconds or 0)
            local bossOK = (not HB.db.settings.requireBossKill) or s.kills > 0
            if s.alreadyCounted then
                HB:Debug("Left %s after %ds but run was already counted via reset announcement -> no double-count",
                         tostring(s.name), secs)
            elseif longEnough and bossOK then
                HB:Debug("Left %s after %ds (kills=%d UID=%s) -> pending (grace %ds)",
                         tostring(s.name), secs, s.kills,
                         tostring(s.instanceUID), LEAVE_GRACE_SECONDS)
                ScheduleLeavePopup(s.name, s.mapID, s.instanceUID)
            else
                HB:Debug("Left %s after %ds (kills=%d) -> no count (long=%s boss=%s)",
                         tostring(s.name), secs, s.kills, tostring(longEnough), tostring(bossOK))
            end
            ResetSession()
        end
    end
end

runFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
runFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
runFrame:RegisterEvent("CHAT_MSG_SYSTEM")
-- Group chat: catches party leader's reset announcement (NIT broadcasts e.g.
-- "[NIT] Maraudon has been reset" to raid chat). Only the resetter receives
-- the Blizzard CHAT_MSG_SYSTEM, so for non-leaders we need group chat too.
runFrame:RegisterEvent("CHAT_MSG_PARTY")
runFrame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
runFrame:RegisterEvent("CHAT_MSG_RAID")
runFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")
runFrame:RegisterEvent("CHAT_MSG_RAID_WARNING")
runFrame:RegisterEvent("ENCOUNTER_END")
runFrame:RegisterEvent("BOSS_KILL")
-- Combat log: needed to read mob GUIDs for the instance-UID compare on
-- re-entry. We bail out at the top in the typical case, so the per-event cost
-- is just two table accesses (s.inInstance + s.instanceUID).
runFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
runFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        UpdateInstanceState()

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if IsResetMessage(msg) then
            -- Two distinct cases share this matcher:
            -- 1) Player is OUTSIDE: "<Dungeon> has been reset." -- fires for
            --    the resetter only. Count the pending leave (if any).
            -- 2) Player is INSIDE:  "The party leader has attempted to reset
            --    the instance you are in." -- fires for non-leader members
            --    who are still inside. Count now and suppress next leave.
            if HB._pendingLeave then
                HB:Debug("System reset message + pending leave -> count")
                HB:CancelPendingLeave("system reset message")
                HB:CountRun("instance reset (system)")
            elseif s.inInstance then
                HB:Debug("System reset message while inside %s -> count + suppress next leave",
                         tostring(s.name))
                HB:CountRun("instance reset (system, while inside)")
                s.alreadyCounted = true
            else
                HB:Debug("System reset message but not in or pending any dungeon -> ignore")
            end
        end

    elseif event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER"
        or event == "CHAT_MSG_RAID"  or event == "CHAT_MSG_RAID_LEADER"
        or event == "CHAT_MSG_RAID_WARNING" then
        -- Party/raid chat reset announcement (NIT broadcast or manual chat).
        -- Dungeon name must appear in the message to match. Handles BOTH the
        -- "outside, pending leave" case AND the "still inside" case.
        local msg = ...
        if IsResetMessage(msg) then
            local low = msg:lower()
            -- Outside, with pending leave for that dungeon
            if HB._pendingLeave and HB._pendingLeave.name then
                local pname = tostring(HB._pendingLeave.name):lower()
                if pname ~= "" and low:find(pname, 1, true) then
                    HB:Debug("Group reset announcement matches pending leave (%s) -> count",
                             tostring(HB._pendingLeave.name))
                    HB:CancelPendingLeave("group reset announcement")
                    HB:CountRun("group reset announcement")
                    return
                end
            end
            -- Inside the dungeon being announced as reset
            if s.inInstance and s.name then
                local sname = tostring(s.name):lower()
                if sname ~= "" and low:find(sname, 1, true) and not s.alreadyCounted then
                    HB:Debug("Group reset announcement matches current dungeon (%s) -> count + suppress next leave",
                             tostring(s.name))
                    HB:CountRun("group reset announcement (while inside)")
                    s.alreadyCounted = true
                end
            end
        end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- Two reasons we want to read the next mob GUID we see:
        -- A) Capture this instance's UID for a future leave (so that, on the
        --    next re-entry, we can tell same-instance from new-instance).
        -- B) Resolve a pending verification: if we just re-entered this
        --    dungeon and the pending leave has an old UID stored, the first
        --    new creature GUID tells us whether the instance was reset
        --    (count the run) or we're back in the same instance (cancel).
        if not s.inInstance then return end
        if s.instanceUID then return end  -- already captured for this instance
        local _, _, _, sourceGUID, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
        local uid = ExtractInstanceUID(sourceGUID) or ExtractInstanceUID(destGUID)
        if not uid then return end
        s.instanceUID = uid
        HB:Debug("Captured instance UID %d for %s", uid, tostring(s.name))
        -- Verifying a pending leave? Compare and decide.
        if HB._pendingLeave and HB._pendingLeave.verifying
           and HB._pendingLeave.mapID == s.mapID then
            local oldUID = HB._pendingLeave.instanceUID
            if oldUID and oldUID ~= uid then
                HB:Debug("Instance UID changed (%d -> %d) -- reset detected, counting",
                         oldUID, uid)
                HB:CancelPendingLeave("instance UID changed (reset detected)")
                HB:CountRun("instance reset (via UID)")
            else
                HB:Debug("Instance UID unchanged (%d) -- HS-for-repair, cancelling pending",
                         uid)
                HB:CancelPendingLeave("same instance UID (HS-for-repair)")
            end
        end

    elseif event == "ENCOUNTER_END" then
        local _, _, _, _, success = ...
        if s.inInstance and success == 1 then
            s.kills = s.kills + 1
            HB:Debug("ENCOUNTER_END success (kills=%d)", s.kills)
        end

    elseif event == "BOSS_KILL" then
        if s.inInstance then
            s.kills = s.kills + 1
            HB:Debug("BOSS_KILL (kills=%d)", s.kills)
        end
    end
end)


