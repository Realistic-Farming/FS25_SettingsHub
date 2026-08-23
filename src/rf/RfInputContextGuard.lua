-- =========================================================
-- FS25_SettingsHub - RfInputContextGuard
-- =========================================================
-- Decides whether the Control Center is allowed to open right now. The summon
-- action is registered in the ONFOOT and VEHICLE contexts, which still fire
-- while a menu or another dialog is on screen, so opening has to be gated here
-- rather than relying on the input context alone.
--
-- Blocks on: any full screen GUI (Esc menu, shop, map), any dialog already up
-- (including this one, so a second press cannot stack a duplicate), and the
-- GUI reload window. All three checks use calls already proven across the
-- suite: g_gui:getIsGuiVisible, g_gui:getIsDialogVisible, g_gui.currentlyReloading.
-- =========================================================

RfInputContextGuard = RfInputContextGuard or {}

--- True when it is safe to summon the Control Center.
---@return boolean canOpen
---@return string|nil reason  short reason when blocked, for the log
function RfInputContextGuard.canOpen()
    if g_gui == nil then
        return false, "no gui manager"
    end

    if g_gui.currentlyReloading then
        return false, "gui reloading"
    end

    local okVisible, guiVisible = pcall(function() return g_gui:getIsGuiVisible() end)
    if okVisible and guiVisible then
        return false, "a menu is open (" .. tostring(g_gui.currentGuiName) .. ")"
    end

    local okDialog, dialogVisible = pcall(function() return g_gui:getIsDialogVisible() end)
    if okDialog and dialogVisible then
        return false, "a dialog is open"
    end

    return true, nil
end

--- True when the player is in a state where a suite action may be triggered.
--- Used by the dialog before firing a delegate, so a row cannot act on a
--- mission that has already been torn down.
---@return boolean
function RfInputContextGuard.hasLiveMission()
    return g_currentMission ~= nil
end
