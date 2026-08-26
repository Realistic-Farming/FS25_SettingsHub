-- =========================================================
-- FS25_SettingsHub - RfLiveBinding
-- =========================================================
-- Reads the key chord currently bound to an InputAction so the Control Center
-- shows what the player actually has bound, not what the mod declared as a
-- default. Values are read on every refresh and never cached, so a remap made
-- in the base game Controls page is reflected the next time the dialog opens.
--
-- Engine API: g_inputDisplayManager:getControllerSymbolOverlays(action, "", "", false)
-- returns a help element whose .keys array holds one display string per key in
-- the chord. This four-argument form is the one already proven live in
-- SoilHUD.lua, SoilSmartSensorPanel.lua and SoilVariableRatePanel.lua.
-- =========================================================

RfLiveBinding = RfLiveBinding or {}

RfLiveBinding.UNASSIGNED = "[ Unassigned ]"

--- Returns the chord bound to an action, e.g. "Right Shift+G".
--- Returns nil when the action is not loaded or carries no binding, so callers
--- can tell "no such action" apart from a literal display string.
---@param actionName string InputAction name, e.g. "MH_TOGGLE_ALL_HUDS"
---@return string|nil
function RfLiveBinding.getChord(actionName)
    if actionName == nil or g_inputDisplayManager == nil then return nil end

    local action = (InputAction ~= nil) and InputAction[actionName] or nil
    if action == nil then return nil end

    local ok, helpElement = pcall(function()
        return g_inputDisplayManager:getControllerSymbolOverlays(action, "", "", false)
    end)
    if not ok or helpElement == nil or helpElement.keys == nil then return nil end

    local parts = {}
    for _, key in ipairs(helpElement.keys) do
        parts[#parts + 1] = tostring(key)
    end
    if #parts == 0 then return nil end

    return table.concat(parts, "+")
end

--- Always returns something printable, for direct use as cell text.
---@param actionName string
---@return string
function RfLiveBinding.getChordOrUnassigned(actionName)
    return RfLiveBinding.getChord(actionName) or RfLiveBinding.UNASSIGNED
end

--- True when the action exists in this session, i.e. its mod is installed and
--- loaded. Absent mods contribute no InputAction entry, which is what keeps the
--- Control Center list honest without any per-mod presence check.
---@param actionName string
---@return boolean
function RfLiveBinding.isActionLoaded(actionName)
    return actionName ~= nil
       and InputAction ~= nil
       and InputAction[actionName] ~= nil
end
