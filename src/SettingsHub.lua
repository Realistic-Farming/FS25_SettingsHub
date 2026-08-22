-- =========================================================
-- FS25_SettingsHub - core class
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Settings bedrock for the Realistic Farming ecosystem. Companion mods
-- register their settings and one onChange callback; SettingsHub owns a
-- throttled async queue (max N callbacks per frame) so a heavy callback
-- (e.g. rebuilding a 365-day price array on a slider tick) never freezes
-- the Lua thread, and it routes admin-only changes through the server.
--
--   g_settingsHub:registerModule(modId, {
--       adminSettings = { { id, type, default, adminOnly, min, max, step, values, label }, ... },
--       onChange      = function(key, value, playerId) ... end,
--   })
--   g_settingsHub:getValue(modId, key)
--   g_settingsHub:setValue(modId, key, value, playerId)   -- from the UI
--
-- Scope:
--   adminOnly = true  -> server-shared. Applied server-side, persisted via
--                        StateLedger, broadcast to clients via NetworkSync.
--   adminOnly = false -> player-local. Applied immediately on this client,
--                        persisted to SettingsHub's own local file. (No
--                        per-playerId server storage in v1; local prefs
--                        stay local, which is SoilFertilizer Point 7.)
-- =========================================================

SettingsHub = SettingsHub or {}
local SettingsHub_mt = Class(SettingsHub)

SettingsHub.MAX_PER_FRAME = 2
SettingsHub.LOCAL_FILE    = "FS25_SettingsHub_local.xml"
SettingsHub.LEDGER_MODULE = "FS25_SettingsHub"

function SettingsHub.new()
    local self = setmetatable({}, SettingsHub_mt)

    self.modules       = {}   -- modId -> { order, defs, values, onChange }
    self.registerOrder = {}
    self.pending       = {}   -- async callback queue
    self.savedAdmin    = {}   -- modId -> { key -> value } restored before a module registered
    self.savedLocal    = {}   -- modId -> { key -> value } from the local file
    self.localLoaded   = false
    self.bedrockBound  = false

    -- Admin Control Registry (API-8) rides inside the hub as an extension.
    self.registry = AdminControlRegistry.new(self)

    -- Option-Scaling Spine (Authority #1): the difficulty profile rides inside
    -- the hub as one admin module; the resolver is a bundled pure library.
    self.spine = OptionScalingSpine.new(self)

    return self
end

-- =========================================================
-- Validation
-- =========================================================

function SettingsHub:_validate(def, value)
    local t = def.type
    if t == "bool" then
        if type(value) ~= "boolean" then return nil end
        return value
    elseif t == "int" then
        if type(value) ~= "number" then return nil end
        if value ~= value or value == math.huge or value == -math.huge then return nil end
        value = math.floor(value)
        if def.min ~= nil and value < def.min then value = def.min end
        if def.max ~= nil and value > def.max then value = def.max end
        return value
    elseif t == "float" then
        if type(value) ~= "number" then return nil end
        if value ~= value or value == math.huge or value == -math.huge then return nil end
        if def.min ~= nil and value < def.min then value = def.min end
        if def.max ~= nil and value > def.max then value = def.max end
        return value
    elseif t == "enum" then
        if def.values == nil then return nil end
        for _, allowed in ipairs(def.values) do
            if value == allowed then return value end
        end
        return nil
    end
    return nil
end

-- =========================================================
-- Registration
-- =========================================================

function SettingsHub:registerModule(modId, spec)
    if type(modId) ~= "string" or modId == "" then
        SHLogger.warning("registerModule: invalid modId '%s'", tostring(modId)); return false
    end
    if type(spec) ~= "table" or type(spec.adminSettings) ~= "table" or type(spec.onChange) ~= "function" then
        SHLogger.warning("registerModule('%s'): needs { adminSettings = {..}, onChange = fn }", modId); return false
    end

    -- selfPersisted: the companion owns its own save file and loads its own values
    -- before it registers. For such a module the hub must NOT restore its own stale
    -- stored copy over the freshly-registered value, nor replay it back through onChange
    -- on load - doing so clobbered the companion's real setting every load (the
    -- SoilFertilizer master `enabled` reset-to-false bug). The hub then acts as a
    -- display mirror + live-edit forwarder only; the companion remains source of truth.
    local mod = { order = {}, defs = {}, values = {}, onChange = spec.onChange,
                  selfPersisted = spec.selfPersisted == true }
    for _, def in ipairs(spec.adminSettings) do
        if type(def) == "table" and type(def.id) == "string" then
            def.adminOnly = def.adminOnly == true
            mod.defs[def.id] = def
            table.insert(mod.order, def.id)
            mod.values[def.id] = def.default
        else
            SHLogger.warning("registerModule('%s'): skipping malformed setting def", modId)
        end
    end

    if self.modules[modId] == nil then table.insert(self.registerOrder, modId) end
    self.modules[modId] = mod

    -- Admin Control Registry (API-8): capture any declared administrative controls.
    -- Additive and backward compatible - existing callers pass no adminControls and
    -- are unaffected. The ack is the affirmative acknowledgement an adopter must hold
    -- before it retires its own local rendering (brief section 7).
    if type(spec.adminControls) == "table" and self.registry ~= nil then
        mod.controlAck = self.registry:register(modId, spec.adminControls)
    end

    -- Apply any values restored before this module registered (load is
    -- order-independent: StateLedger / the local file may arrive first).
    local restoredAdmin = self.savedAdmin[modId]
    local restoredLocal = self.savedLocal[modId]
    for _, id in ipairs(mod.order) do
        local def = mod.defs[id]
        -- Self-persisted companions keep the value they just registered (their own load
        -- already ran); skip the hub restore + apply-on-load replay entirely so a stale
        -- hub copy can never overwrite the companion's real setting.
        if not mod.selfPersisted then
            local restored
            if def.adminOnly then
                restored = restoredAdmin and restoredAdmin[id]
            else
                restored = restoredLocal and restoredLocal[id]
            end
            if restored ~= nil then
                local v = self:_validate(def, restored)
                if v ~= nil then mod.values[id] = v end
            end
            -- apply-on-load: queue the current value so the companion applies it
            self:_queue(modId, id, mod.values[id], nil)
        end
    end

    self:_bindBedrock()
    SHLogger.debug("Registered module '%s' (%d setting(s))", modId, #mod.order)
    return true
end

-- =========================================================
-- Read / write
-- =========================================================

function SettingsHub:getValue(modId, key)
    local mod = self.modules[modId]
    if mod == nil then return nil end
    if mod.values[key] ~= nil then return mod.values[key] end
    local def = mod.defs[key]
    return def ~= nil and def.default or nil
end

-- UI entry point. Validates, then routes by scope.
function SettingsHub:setValue(modId, key, value, playerId)
    local mod = self.modules[modId]
    if mod == nil then return false end
    local def = mod.defs[key]
    if def == nil then return false end

    local v = self:_validate(def, value)
    if v == nil then
        SHLogger.warning("setValue('%s','%s'): value rejected by validation", modId, key)
        return false
    end

    if def.adminOnly then
        if g_currentMission ~= nil and g_currentMission:getIsServer() then
            self:applyAdminChangeFromNetwork(modId, key, v)      -- authoritative + broadcast
        else
            self:_requestAdminChange(modId, key, v)              -- ask the server
        end
    else
        self:_applyLocal(modId, key, v, playerId)
    end
    return true
end

function SettingsHub:_applyLocal(modId, key, value, playerId)
    local mod = self.modules[modId]
    mod.values[key] = value
    self:_queue(modId, key, value, playerId)
    self:_saveLocalFile()
end

-- Client asks the server to change an admin setting.
function SettingsHub:_requestAdminChange(modId, key, value)
    if g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn ~= nil then
            conn:sendEvent(SettingsHubAdminEvent.new(modId, key, value))
        end
    end
end

-- Server applies an approved admin change: set, queue, persist, broadcast.
function SettingsHub:applyAdminChangeFromNetwork(modId, key, value)
    local mod = self.modules[modId]
    if mod == nil then return end
    local def = mod.defs[key]
    if def == nil then return end
    local v = self:_validate(def, value)
    if v == nil then return end

    mod.values[key] = v
    self:_queue(modId, key, v, nil)
    -- Broadcast to clients via NetworkSync (server side).
    if g_networkSync ~= nil then
        g_networkSync:syncNow(SettingsHub.LEDGER_MODULE)
    end
end

-- =========================================================
-- Async queue (the point of SettingsHub)
-- =========================================================

function SettingsHub:_queue(modId, key, value, playerId)
    local mod = self.modules[modId]
    if mod == nil then return end
    table.insert(self.pending, { func = mod.onChange, modId = modId, key = key, value = value, playerId = playerId })
end

function SettingsHub:update(dt)
    local processed = 0
    while #self.pending > 0 and processed < SettingsHub.MAX_PER_FRAME do
        local item = table.remove(self.pending, 1)
        local ok, err = pcall(item.func, item.key, item.value, item.playerId)
        if not ok then
            SHLogger.error("onChange failed for %s.%s: %s", item.modId, item.key, tostring(err))
        end
        processed = processed + 1
    end
end

-- =========================================================
-- NetworkSync integration (admin values, server -> clients)
-- =========================================================

-- Server: flatten every adminOnly value into [modId, key, value, ...].
function SettingsHub:onWriteState()
    local arr = {}
    for _, modId in ipairs(self.registerOrder) do
        local mod = self.modules[modId]
        for _, id in ipairs(mod.order) do
            if mod.defs[id].adminOnly then
                arr[#arr + 1] = modId
                arr[#arr + 1] = id
                arr[#arr + 1] = mod.values[id]
            end
        end
    end
    return arr
end

-- Client: apply admin values, queueing onChange only for ones that changed.
function SettingsHub:onReadState(arr)
    if type(arr) ~= "table" then return end
    local i = 1
    while i + 2 <= #arr do
        local modId, key, value = arr[i], arr[i + 1], arr[i + 2]
        local mod = self.modules[modId]
        if mod ~= nil and mod.defs[key] ~= nil then
            local v = self:_validate(mod.defs[key], value)
            if v ~= nil and mod.values[key] ~= v then
                mod.values[key] = v
                self:_queue(modId, key, v, nil)
            end
        end
        i = i + 3
    end
end

-- =========================================================
-- StateLedger integration (admin values, persistence)
-- =========================================================

function SettingsHub:serializeAdmin()
    local out = {}
    for _, modId in ipairs(self.registerOrder) do
        local mod = self.modules[modId]
        local block = nil
        for _, id in ipairs(mod.order) do
            if mod.defs[id].adminOnly then
                block = block or {}
                block[id] = mod.values[id]
            end
        end
        if block ~= nil then out[modId] = block end
    end
    return out
end

function SettingsHub:deserializeAdmin(data)
    -- May arrive before companions register; stash and also apply to any
    -- already-registered module.
    self.savedAdmin = data or {}
    for modId, block in pairs(self.savedAdmin) do
        local mod = self.modules[modId]
        if mod ~= nil then
            for key, value in pairs(block) do
                local def = mod.defs[key]
                if def ~= nil and def.adminOnly then
                    local v = self:_validate(def, value)
                    if v ~= nil then
                        mod.values[key] = v
                        self:_queue(modId, key, v, nil)
                    end
                end
            end
        end
    end
end

-- Bind to the bedrock mods once (idempotent). Safe if they are absent.
function SettingsHub:_bindBedrock()
    if self.bedrockBound then return end
    if g_stateLedger ~= nil then
        g_stateLedger:registerModule(SettingsHub.LEDGER_MODULE, {
            serialize   = function() return self:serializeAdmin() end,
            deserialize = function(data) self:deserializeAdmin(data) end,
        })
    end
    if g_networkSync ~= nil then
        g_networkSync:registerModule(SettingsHub.LEDGER_MODULE, {
            channel      = "SettingsHub_Sync",
            onWriteState = function() return self:onWriteState() end,
            onReadState  = function(arr) self:onReadState(arr) end,
        })
    end
    if g_stateLedger ~= nil or g_networkSync ~= nil then
        self.bedrockBound = true
    end
end

-- =========================================================
-- Local (player-scoped) persistence
-- =========================================================

function SettingsHub:_localFilePath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil
        or g_currentMission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory .. "/" .. SettingsHub.LOCAL_FILE
end

function SettingsHub:loadLocalFile()
    self.localLoaded = true
    local path = self:_localFilePath()
    if path == nil or not fileExists(path) then return end
    local xml = XMLFile.loadIfExists("SettingsHub_local", path)
    if xml == nil then return end
    local i = 0
    while true do
        local base = string.format("settings.value(%d)", i)
        local modId = xml:getString(base .. "#mod")
        if modId == nil then break end
        local key = xml:getString(base .. "#key")
        local vtype = xml:getString(base .. "#t")
        local value
        if vtype == "bool" then value = xml:getBool(base .. "#v", false)
        elseif vtype == "num" then value = tonumber(xml:getString(base .. "#v"))
        else value = xml:getString(base .. "#v") end
        if modId ~= nil and key ~= nil then
            self.savedLocal[modId] = self.savedLocal[modId] or {}
            self.savedLocal[modId][key] = value
        end
        i = i + 1
    end
    xml:delete()
end

function SettingsHub:_saveLocalFile()
    local path = self:_localFilePath()
    if path == nil then return end
    local xml = XMLFile.create("SettingsHub_local", path, "settings")
    if xml == nil then return end
    local idx = 0
    for _, modId in ipairs(self.registerOrder) do
        local mod = self.modules[modId]
        for _, id in ipairs(mod.order) do
            if not mod.defs[id].adminOnly then
                local base = string.format("settings.value(%d)", idx)
                xml:setString(base .. "#mod", modId)
                xml:setString(base .. "#key", id)
                local v = mod.values[id]
                if type(v) == "boolean" then
                    xml:setString(base .. "#t", "bool"); xml:setBool(base .. "#v", v)
                elseif type(v) == "number" then
                    xml:setString(base .. "#t", "num"); xml:setString(base .. "#v", tostring(v))
                else
                    xml:setString(base .. "#t", "str"); xml:setString(base .. "#v", tostring(v))
                end
                idx = idx + 1
            end
        end
    end
    xml:save()
    xml:delete()
end

-- =========================================================
-- FarmTablet surface (read-only model for the System Settings app)
-- =========================================================

-- FarmTablet's AppRegistry:autoDetect() reads g_currentMission.settingsHub
-- and renders a System Settings app from this. SettingsHub does NOT call
-- FarmTablet directly (per the AppRegistry Point-3 contract).
function SettingsHub:getModules()
    local out = {}
    for _, modId in ipairs(self.registerOrder) do
        local mod = self.modules[modId]
        local settings = {}
        for _, id in ipairs(mod.order) do
            local def = mod.defs[id]
            settings[#settings + 1] = {
                id = id, type = def.type, value = mod.values[id], default = def.default,
                adminOnly = def.adminOnly, min = def.min, max = def.max, step = def.step,
                values = def.values, label = def.label,
            }
        end
        out[#out + 1] = { modId = modId, settings = settings }
    end
    return out
end

-- =========================================================
-- Lifecycle
-- =========================================================

-- After loadLocalFile populates savedLocal, apply saved values to
-- already-registered modules (registerModule runs before mission load).
function SettingsHub:_applySavedLocal()
    for _, modId in ipairs(self.registerOrder) do
        local mod = self.modules[modId]
        local restoredLocal = self.savedLocal[modId]
        if not mod.selfPersisted and restoredLocal ~= nil then
            for _, id in ipairs(mod.order) do
                local def = mod.defs[id]
                if not def.adminOnly then
                    local restored = restoredLocal[id]
                    if restored ~= nil then
                        local v = self:_validate(def, restored)
                        if v ~= nil and mod.values[id] ~= v then
                            mod.values[id] = v
                            self:_queue(modId, id, v, nil)
                        end
                    end
                end
            end
        end
    end
end

function SettingsHub:onMissionLoaded()
    if not self.localLoaded then
        self:loadLocalFile()
    end
    self:_applySavedLocal()
    self:_bindBedrock()
    if self.registry ~= nil then
        self.registry:onMissionLoaded()   -- register the creative flag + bind the invoke action
    end
    if self.spine ~= nil then
        self.spine:onMissionLoaded()      -- register the seven-dial difficulty profile
    end
end

-- =========================================================
-- Admin Control Registry (API-8) accessors for adopters
-- =========================================================

-- The single registry instance. Adopters check
-- reg.CAPABILITY_VERSION before relying on it (a capability handle).
function SettingsHub:getRegistry()
    return self.registry
end

-- The affirmative registration acknowledgement for a module's declared controls,
-- or nil if the module declared none. An adopter must not retire its own local
-- rendering until this returns an ack with ok == true.
function SettingsHub:getControlAck(modId)
    local mod = self.modules[modId]
    return mod ~= nil and mod.controlAck or nil
end

function SettingsHub:consoleCommandStatus()
    local lines = {}
    table.insert(lines, string.format("SettingsHub: %d module(s), %d queued, bedrock=%s",
        #self.registerOrder, #self.pending, tostring(self.bedrockBound)))
    for _, modId in ipairs(self.registerOrder) do
        local mod = self.modules[modId]
        table.insert(lines, string.format("  %s (%d setting(s))", modId, #mod.order))
    end
    return table.concat(lines, "\n")
end
