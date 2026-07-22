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

local modDirectory = g_currentModDirectory

source(modDirectory .. "src/Logger.lua")
source(modDirectory .. "src/SettingsHubAdminEvent.lua")
source(modDirectory .. "src/AdminControlRegistry.lua")
source(modDirectory .. "src/OptionScalingResolver.lua")
source(modDirectory .. "src/OptionScalingSpine.lua")
source(modDirectory .. "src/SettingsHub.lua")

local settingsHub = SettingsHub.new()
getfenv(0)["g_settingsHub"] = settingsHub

local function onMissionLoad(mission)
    if mission ~= nil then
        mission.settingsHub = settingsHub
    end
    SHLogger.info("SettingsHub active (mod 4, settings)")
end

local function onMissionLoadedFinished()
    settingsHub:onMissionLoaded()
end

local function onMissionUpdate(mission, dt)
    settingsHub:update(dt)
end

local function onMissionSave()
    -- Flush player-local prefs into the (temp)savegame being written.
    settingsHub:_saveLocalFile()
end

local function onMissionDelete()
    getfenv(0)["g_settingsHub"] = nil
    if g_currentMission ~= nil then
        g_currentMission.settingsHub = nil
    end
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
