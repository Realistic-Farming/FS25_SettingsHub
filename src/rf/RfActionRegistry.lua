-- =========================================================
-- FS25_SettingsHub - RfActionRegistry
-- =========================================================
-- Backs the Realistic Farming Control Center. Two jobs:
--
-- 1. DISCOVERY (automatic, nothing to maintain per action). The engine fills
--    the global InputAction table from every loaded modDesc, so the set of
--    suite actions present in a session can be read straight out of it. A mod
--    that is not installed contributes no entry and therefore no row: no
--    presence checks, no hardcoded action list, no dead controls. Adding a new
--    action to any companion modDesc makes it appear here with no code change.
--    The only per-module data kept below is a prefix to display-name map, which
--    is grouping, not an action list.
--
-- 2. DELEGATES (opt in). A row only grows a trigger button when its owner has
--    registered something to run. Companion mods call registerAction from their
--    own load, exactly like the Esc PDA guests register modules. Nothing is
--    assumed about a mod that has not registered, so its row stays a directory
--    entry showing the live key and nothing more.
--
-- Cross-mod reachability follows the suite rule proven by Vera's via=mission
-- gate: only the g_currentMission handle carries live between mod environments,
-- so the registry is published there and re-published on every register attempt.
--
-- Deliberately NOT a whitelisted descriptor copy. RfEscModules:registerModule
-- silently dropped six handlers over five separate incidents because each new
-- field had to be added to a copy list. Here the whole descriptor is retained
-- and only the required fields are validated.
-- =========================================================

RfActionRegistry = RfActionRegistry or {}

-- Prefix to module display name. Grouping only: actions are discovered, not
-- listed. An action whose prefix is absent here is not a suite action and is
-- skipped, which keeps third party mods out of the list.
RfActionRegistry.GROUPS = {
    { prefix = "RF_",    title = "Control Center",       order = 5 },
    { prefix = "MH_",    title = "Master HUD",           order = 10 },
    { prefix = "FT_",    title = "Farm Tablet",          order = 20 },
    { prefix = "SF_",    title = "Soil and Fertilizer",  order = 30 },
    { prefix = "CS_",    title = "Seasonal Crop Stress", order = 40 },
    { prefix = "WC_",    title = "Worker Costs",         order = 50 },
    { prefix = "MDM_",   title = "Market Dynamics",      order = 60 },
    { prefix = "FC_",    title = "Fuel Costs",           order = 70 },
    { prefix = "FD_",    title = "Fertilizer Depot",     order = 80 },
    { prefix = "IM_",    title = "Income",               order = 90 },
    { prefix = "TM_",    title = "Tax",                  order = 100 },
    { prefix = "RWE_",   title = "Random World Events",  order = 110 },
    { prefix = "NPC_",   title = "NPC Favor",            order = 120 },
    { prefix = "FAVOR_", title = "NPC Favor",            order = 120 },
    { prefix = "WT_",    title = "Workplace Triggers",   order = 130 },
}

-- The Control Center's own summon action. Listed so the player can see its key,
-- but it never gets a trigger button: the dialog is already open.
RfActionRegistry.SUMMON_ACTION = "RF_OPEN_CONTROL_CENTER"

RfActionRegistry.delegates = RfActionRegistry.delegates or {}

-- === Registration ========================================

--- Publishes the registry on the mission handle. Called on every register so a
--- companion that loads before or after the mission still lands, and so a
--- re-source during hot reload restores the handle.
local function publishHandle()
    if g_currentMission ~= nil then
        g_currentMission.rfActionRegistry = RfActionRegistry
    end
end

--- Registers a runnable delegate for one action.
---
--- @param def table descriptor:
---   action     (string,   required) InputAction name, e.g. "FT_TOGGLE_TABLET"
---   run        (function, required) called with no arguments when the row is clicked
---   label      (string,   optional) overrides the l10n action name
---   button     (string,   optional) button caption, defaults to "Run"
---   closeFirst (boolean,  optional) close the Control Center before running, for
---                                   delegates that open a full screen of their own
---   order      (number,   optional) sort order inside the module group
--- @return boolean accepted
function RfActionRegistry.registerAction(def)
    if type(def) ~= "table" or type(def.action) ~= "string" or def.action == "" then
        return false
    end
    if type(def.run) ~= "function" then
        return false
    end

    -- Whole descriptor retained on purpose; see the header note.
    RfActionRegistry.delegates[def.action] = def
    publishHandle()
    return true
end

--- Removes a delegate. The row survives as a directory entry.
---@param actionName string
function RfActionRegistry.unregisterAction(actionName)
    if actionName ~= nil then
        RfActionRegistry.delegates[actionName] = nil
    end
end

--- Idempotent publish, for main.lua to call on mission load.
function RfActionRegistry.publish()
    publishHandle()
end

-- === Discovery ===========================================

--- Returns the group descriptor for an action name, or nil when the action does
--- not belong to the suite. Longest prefix wins so NPC_ cannot shadow a future
--- longer group sharing its opening letters.
local function groupFor(actionName)
    local best
    for _, group in ipairs(RfActionRegistry.GROUPS) do
        if actionName:sub(1, #group.prefix) == group.prefix then
            if best == nil or #group.prefix > #best.prefix then
                best = group
            end
        end
    end
    return best
end

--- Human readable name for an action. Prefers the l10n text every companion
--- modDesc already declares as input_<ACTION>, which is the same string the base
--- game Controls page shows, so the two never disagree. Falls back to the raw
--- action name with its prefix stripped.
local function labelFor(actionName)
    local key = "input_" .. actionName

    if g_i18n ~= nil then
        local okHas, has = pcall(function() return g_i18n:hasText(key) end)
        if okHas and has then
            local okText, text = pcall(function() return g_i18n:getText(key) end)
            if okText and text ~= nil and text ~= "" and text ~= key then
                return text
            end
        end
    end

    local stripped = actionName:gsub("^[A-Z]+_", ""):gsub("_", " ")
    return stripped
end

--- Builds the full row list for the current session, sorted by module then by
--- action. Rebuilt on every dialog open so installing a mod, remapping a key or
--- a late delegate registration are all picked up without a restart.
---@return table rows array of { action, label, group, groupOrder, chord, delegate }
function RfActionRegistry.getRows()
    local rows = {}

    if InputAction == nil then
        return rows
    end

    for actionName in pairs(InputAction) do
        if type(actionName) == "string" then
            local group = groupFor(actionName)
            if group ~= nil then
                local delegate = RfActionRegistry.delegates[actionName]
                rows[#rows + 1] = {
                    action     = actionName,
                    label      = (delegate ~= nil and delegate.label) or labelFor(actionName),
                    group      = group.title,
                    groupOrder = group.order,
                    order      = (delegate ~= nil and tonumber(delegate.order)) or 0,
                    chord      = RfLiveBinding.getChordOrUnassigned(actionName),
                    delegate   = delegate,
                }
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.groupOrder ~= b.groupOrder then return a.groupOrder < b.groupOrder end
        if a.order ~= b.order then return a.order < b.order end
        return a.action < b.action
    end)

    return rows
end

--- Convenience for the summon action's own chord, shown in the dialog footer.
---@return string
function RfActionRegistry.getSummonChord()
    return RfLiveBinding.getChordOrUnassigned(RfActionRegistry.SUMMON_ACTION)
end
