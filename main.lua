-- =========================================================
-- FS25_SettingsHub - mod entry point
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Loads the SettingsHub modules, publishes the g_settingsHub handle, and
-- hooks the FS25 mission lifecycle:
--   Mission00.load                     -> publish the cross-mod bridge handle
--   Mission00.loadMission00Finished    -> load local prefs + bind to bedrock
--   FSBaseMission.update               -> drive the throttled callback queue
--   FSCareerMissionInfo.saveToXMLFile  -> flush player-local prefs into the save
--   FSBaseMission.delete               -> drop the handle
--
-- Load order: SettingsHub is mod 4 (after StateLedger, NetworkSync,
-- MasterHUD). Handle is published at file load so companions loading after
-- it can register during their own module load.
-- =========================================================

-- Hot-reload latch (FuelCosts reference): g_currentModDirectory and
-- g_currentModName are nil on a live re-source, so they are latched into
-- module globals on first load, with a g_modsDirectory loose-folder fallback.
SettingsHubModDirectory = SettingsHubModDirectory
    or g_currentModDirectory
    or (g_modsDirectory ~= nil and (g_modsDirectory .. "FS25_SettingsHub/") or nil)
SettingsHubModName = SettingsHubModName or g_currentModName or "FS25_SettingsHub"
local modDirectory = SettingsHubModDirectory

source(modDirectory .. "src/Logger.lua")
source(modDirectory .. "src/SettingsHubAdminEvent.lua")
source(modDirectory .. "src/AdminControlRegistry.lua")
source(modDirectory .. "src/OptionScalingResolver.lua")
source(modDirectory .. "src/OptionScalingSpine.lua")
source(modDirectory .. "src/SettingsHub.lua")
source(modDirectory .. "src/InGameMenuPageGuard.lua")

-- Control Center (RfKeybindActionDialog): action registry, live key readout,
-- context guard, master summon binding and the dialog itself.
source(modDirectory .. "src/rf/RfLiveBinding.lua")
source(modDirectory .. "src/rf/RfActionRegistry.lua")
source(modDirectory .. "src/rf/RfInputContextGuard.lua")
source(modDirectory .. "src/rf/RfControlCenterInput.lua")

local settingsHub = SettingsHub.new()
getfenv(0)["g_settingsHub"] = settingsHub

-- Suite ESC-menu stacking guard (idempotent; companions may also try).
InGameMenuPageGuard.install()

-- Control Center summon key. Installed at module load because the on-foot half
-- must wrap PlayerInputComponent.registerActionEvents before the first one fires.
RfControlCenterInput.install()

local function onMissionLoad(mission)
    if mission ~= nil then
        mission.settingsHub = settingsHub
    end
    -- Only the g_currentMission handle carries live between mod environments,
    -- so companions reach the action registry through it.
    RfActionRegistry.publish()
    SHLogger.info("SettingsHub active (mod 4, settings)")
end

local function onMissionLoadedFinished()
    settingsHub:onMissionLoaded()
    InGameMenuPageGuard.install()
    RfActionRegistry.publish()
end

local function onMissionUpdate(mission, dt)
    settingsHub:update(dt)
    InGameMenuPageGuard.update(dt)
end

local function onMissionSave()
    -- Flush player-local prefs into the (temp)savegame being written.
    settingsHub:_saveLocalFile()
end

local function onMissionDelete()
    getfenv(0)["g_settingsHub"] = nil
    if g_currentMission ~= nil then
        g_currentMission.settingsHub = nil
        g_currentMission.rfActionRegistry = nil
    end
end

-- GIANTS nil-check bug: DebugCameraClone:update calls getWorldTranslation on
-- a nil camera or player graphicsRootNode after a disconnect, error-floods
-- every frame and freezes the client. Nobody uses the debug camera clone on
-- live servers, so neuter the update entirely: no raiseActive, no dirty
-- flags, no per-frame network traffic for a dead debug feature.
if DebugCameraClone ~= nil then
    DebugCameraClone.update = function() end
end

Mission00.load = Utils.appendedFunction(Mission00.load, onMissionLoad)
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, onMissionLoadedFinished)
FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, onMissionUpdate)
FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, onMissionDelete)

if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function() onMissionSave() end
    )
end

if addConsoleCommand ~= nil then
    addConsoleCommand("shStatus", "Show SettingsHub registered modules and queue",
        "consoleCommandStatus", settingsHub)
    addConsoleCommand("shRegistryStatus", "Show Admin Control Registry declared controls",
        "consoleCommandStatus", settingsHub.registry)
    addConsoleCommand("shSpine", "Show Option-Scaling Spine profile (dials, switches, preset)",
        "consoleCommandStatus", settingsHub.spine)
end
