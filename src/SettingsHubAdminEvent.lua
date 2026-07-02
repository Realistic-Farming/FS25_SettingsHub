-- =========================================================
-- FS25_SettingsHub - admin change event (client -> server)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Carries one admin-only setting change request from a client to the
-- server. The server validates that the sender is the master user, then
-- applies it (which persists via StateLedger and broadcasts to all clients
-- via NetworkSync). Mirrors the shipped SoilFertilizer setting-change
-- event: a client requests, the server is authoritative.
-- =========================================================

SettingsHubAdminEvent = {}
local SettingsHubAdminEvent_mt = Class(SettingsHubAdminEvent, Event)
InitEventClass(SettingsHubAdminEvent, "SettingsHubAdminEvent")

SettingsHubAdminEvent.T_BOOL   = 0
SettingsHubAdminEvent.T_INT    = 1
SettingsHubAdminEvent.T_FLOAT  = 2
SettingsHubAdminEvent.T_STRING = 3

function SettingsHubAdminEvent.emptyNew()
    return Event.new(SettingsHubAdminEvent_mt)
end

function SettingsHubAdminEvent.new(modId, key, value)
    local self = SettingsHubAdminEvent.emptyNew()
    self.modId = modId
    self.key   = key
    self.value = value
    return self
end

function SettingsHubAdminEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.modId or "")
    streamWriteString(streamId, self.key or "")
    local v = self.value
    local t = type(v)
    if t == "boolean" then
        streamWriteUInt8(streamId, SettingsHubAdminEvent.T_BOOL)
        streamWriteBool(streamId, v)
    elseif t == "number" then
        if math.floor(v) == v and v >= -2147483648 and v <= 2147483647 then
            streamWriteUInt8(streamId, SettingsHubAdminEvent.T_INT)
            streamWriteInt32(streamId, v)
        else
            streamWriteUInt8(streamId, SettingsHubAdminEvent.T_FLOAT)
            streamWriteFloat32(streamId, v)
        end
    else
        streamWriteUInt8(streamId, SettingsHubAdminEvent.T_STRING)
        streamWriteString(streamId, tostring(v))
    end
end

function SettingsHubAdminEvent:readStream(streamId, connection)
    self.modId = streamReadString(streamId)
    self.key   = streamReadString(streamId)
    local tag  = streamReadUInt8(streamId)
    if tag == SettingsHubAdminEvent.T_BOOL then
        self.value = streamReadBool(streamId)
    elseif tag == SettingsHubAdminEvent.T_INT then
        self.value = streamReadInt32(streamId)
    elseif tag == SettingsHubAdminEvent.T_FLOAT then
        self.value = streamReadFloat32(streamId)
    else
        self.value = streamReadString(streamId)
    end
    self:run(connection)
end

function SettingsHubAdminEvent:run(connection)
    -- Server only: validate the sender is the master user, then apply.
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    local isMaster = connection ~= nil and connection:getIsServer()
    if not isMaster then
        local ok, res = pcall(function()
            local um = g_currentMission.userManager
            local u = um ~= nil and um:getUserByConnection(connection) or nil
            return u ~= nil and u:getIsMasterUser()
        end)
        isMaster = ok and res == true
    end
    if not isMaster then
        SHLogger.warning("Rejected admin setting change from a non-admin connection")
        return
    end
    if g_settingsHub ~= nil then
        g_settingsHub:applyAdminChangeFromNetwork(self.modId, self.key, self.value)
    end
end
