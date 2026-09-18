-- =========================================================
-- FS25_SettingsHub - RfLiveBinding
-- =========================================================
-- Reads the key chord currently bound to an InputAction so the Control Center
-- shows what the player actually has bound, not what the mod declared as a
-- default. Values are read on every refresh and never cached, so a remap made
-- in the base game Controls page is reflected the next time the dialog opens.
--
-- Binding policy (Wizard lock, BUILD 21:33): reading is the ONLY thing the suite
-- does to bindings at runtime. Defaults live in each mod's modDesc and apply only
-- to actions new to a save; a player's own assignments are never overwritten and
-- there is deliberately no runtime migration. Repairing an existing save's empty
-- slots is a manual, offline, opt-in job for tools/rf-backfill-inputbindings.ps1,
-- which must never be called from mod code.
--
-- Engine API: an action can carry keyboard alternatives in slots 1 and 2.
-- Calling getControllerSymbolOverlays without a custom binding flattens the
-- keys from every alternative into one .keys array; joining that array makes
-- two bindings look like one impossible four-key chord. Select the primary
-- keyboard Binding object first, then pass it as the customBinding argument so
-- the display contains exactly one real chord.
-- =========================================================

RfLiveBinding = RfLiveBinding or {}

RfLiveBinding.UNASSIGNED = "[ Unassigned ]"

local function getPrimaryKeyboardBinding(action)
    if action == nil or type(action.getActiveBindings) ~= "function" then
        return nil
    end

    local ok, bindings = pcall(function() return action:getActiveBindings() end)
    if not ok or type(bindings) ~= "table" then return nil end

    local selected = nil
    for _, binding in ipairs(bindings) do
        if binding ~= nil and binding.isKeyboard == true then
            local selectedIndex = selected ~= nil and tonumber(selected.index) or math.huge
            local bindingIndex = tonumber(binding.index) or math.huge
            local selectedPositive = selected ~= nil and selected.axisComponent == "+"
            local bindingPositive = binding.axisComponent == "+"

            if selected == nil
                or bindingIndex < selectedIndex
                or (bindingIndex == selectedIndex and bindingPositive and not selectedPositive) then
                selected = binding
            end
        end
    end
    return selected
end

--- Returns the chord bound to an action, e.g. "Right Shift+G".
--- Returns nil when the action is not loaded or carries no binding, so callers
--- can tell "no such action" apart from a literal display string.
---@param actionName string InputAction name, e.g. "MH_TOGGLE_ALL_HUDS"
---@return string|nil
function RfLiveBinding.getChord(actionName)
    if actionName == nil or g_inputDisplayManager == nil or g_inputBinding == nil then
        return nil
    end

    local action = (InputAction ~= nil) and InputAction[actionName] or nil
    if action == nil then return nil end

    local actionObject = g_inputBinding:getActionByName(actionName)
    local binding = getPrimaryKeyboardBinding(actionObject)
    if binding == nil then return nil end

    local ok, helpElement = pcall(function()
        return g_inputDisplayManager:getControllerSymbolOverlays(action, "", "", false, binding)
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
