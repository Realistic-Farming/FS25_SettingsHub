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
--       selfPersisted = true,                       -- optional: the companion owns its own save
--       read          = function(key) return v end, -- optional, selfPersisted only: its live value
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
SettingsHub.REPUBLISH_MS  = 1000   -- [MAINTENANCE row 258] at most one read-moved check a second

function SettingsHub.new()
    local self = setmetatable({}, SettingsHub_mt)

    self.modules       = {}   -- modId -> { order, defs, values, onChange }
    self.registerOrder = {}
    self.pending       = {}   -- async callback queue
    self.savedAdmin    = {}   -- modId -> { key -> value } restored before a module registered
    self.savedLocal    = {}   -- modId -> { key -> value } from the local file
    self.localLoaded   = false
    self.bedrockBound  = false    -- either handle bound (MAINTENANCE row 241: each binds on its own)
    self.stateLedgerBound = false
    self.networkSyncBound = false
    self.readWarned       = {}   -- [MAINTENANCE row 258] "modId.key" -> true once a failing read logged
    self.published        = {}   -- modId -> { key -> admin value last sent by onWriteState }
    self.republishTimer   = 0

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

-- [MAINTENANCE row 217] A number that crossed the network did so as float32: the admin event
-- writes a non-integer with streamWriteFloat32 (SettingsHubAdminEvent.lua) and NetworkSync
-- broadcasts numbers the same way, so a declared 0.8 arrives as 0.800000011920929 and the
-- exact enum check above refused it, silently. This gives such a value back as the declared
-- option it stands for, only when it lies within float32 rounding of that option (2^-23 of its
-- size); anything else is returned unchanged, so a value no option explains is still refused.
SettingsHub.FLOAT32_REL = 2 ^ -23

function SettingsHub:_snapNetworkValue(def, value)
    if type(def) ~= "table" or def.type ~= "enum" or type(def.values) ~= "table" then return value end
    if type(value) ~= "number" or value ~= value then return value end
    local best, bestDiff = nil, nil
    for _, option in ipairs(def.values) do
        if type(option) == "number" then
            local d = math.abs(option - value)
            if d <= math.abs(option) * SettingsHub.FLOAT32_REL and (bestDiff == nil or d < bestDiff) then
                best, bestDiff = option, d
            end
        end
    end
    if best ~= nil then return best end
    return value
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
    -- [MAINTENANCE row 258] A selfPersisted companion may also pass read(key), its live value; the hub then
    -- shows that instead of its own mirror (_shownValue). Ignored for a module the hub persists itself.
    local mod = { order = {}, defs = {}, values = {}, onChange = spec.onChange,
                  selfPersisted = spec.selfPersisted == true }
    if mod.selfPersisted and type(spec.read) == "function" then mod.read = spec.read end
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
    local shown = self:_shownValue(modId, key)
    if shown ~= nil then return shown end
    local def = mod.defs[key]
    return def ~= nil and def.default or nil
end

-- [MAINTENANCE row 258] What the hub shows for a key. A selfPersisted companion that passed read(key) is
-- asked for its live value, so a change made in its own UI (a dialog, a console command, its own MP event)
-- shows here without the companion telling the hub. Where that truth lives (Bob's R-15): an admin key on
-- the server only, since a client's companion may hold a stale copy (some send no settings to clients),
-- so a client keeps the mirror the server's broadcast fills; a player-local key on its own machine. The
-- value is snapped and validated like any value that reaches the hub; one that fails shows the mirror and
-- logs once. A key with a change still queued shows the mirror too, so a quick double press steps from the
-- value just set, not from the companion's not-yet-applied one.
function SettingsHub:_isServer()
    return g_currentMission ~= nil and g_currentMission.getIsServer ~= nil and g_currentMission:getIsServer() == true
end

function SettingsHub:_hasPending(modId, key)
    for _, item in ipairs(self.pending) do
        if item.modId == modId and item.key == key then return true end
    end
    return false
end

function SettingsHub:_shownValue(modId, key)
    local mod = self.modules[modId]
    if mod == nil then return nil end
    local def = mod.defs[key]
    local mirror = mod.values[key]
    if mod.read == nil or def == nil then return mirror end
    if def.adminOnly and not self:_isServer() then return mirror end
    if self:_hasPending(modId, key) then return mirror end
    local ok, raw = pcall(mod.read, key)
    local v = nil
    if ok and raw ~= nil then v = self:_validate(def, self:_snapNetworkValue(def, raw)) end
    if v == nil then
        local tag = modId .. "." .. key
        if not self.readWarned[tag] then
            self.readWarned[tag] = true
            SHLogger.warning("read('%s','%s') gave no valid value (%s); showing the hub's copy", modId, key, tostring(raw))
        end
        return mirror
    end
    return v
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
    local v = self:_validate(def, self:_snapNetworkValue(def, value))
    if v == nil then return end

    mod.values[key] = v
    self:_queue(modId, key, v, nil)
    -- Broadcast to clients via NetworkSync (server side; the mission's handle, MAINTENANCE row 241).
    local networkSync = SettingsHub.networkSyncHandle()
    if networkSync ~= nil then
        networkSync:syncNow(SettingsHub.LEDGER_MODULE)
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

    -- [MAINTENANCE row 258] Republish. On the server, at most once a second, when a reader's admin value has
    -- moved since the hub last sent its state (a change made in the companion's own UI), send it now instead
    -- of waiting for NetworkSync's 30 s drift floor, so every client's Tablet follows within a second.
    if self.networkSyncBound and self:_isServer() then
        self.republishTimer = self.republishTimer + (dt or 0)
        if self.republishTimer >= SettingsHub.REPUBLISH_MS then
            self.republishTimer = 0
            if self:_readMoved() then
                local networkSync = SettingsHub.networkSyncHandle()
                if networkSync ~= nil then networkSync:syncNow(SettingsHub.LEDGER_MODULE) end
            end
        end
    end

    -- One-shot "suite is active" welcome message, a few seconds after load.
    if self._welcomePending then
        self._welcomeTimer = (self._welcomeTimer or 0) - dt
        if self._welcomeTimer <= 0 then
            self:_showWelcomeMessage()
        end
    end
end

-- Count the RF suite mods active this session: prefer the Control Center's own
-- directory (distinct suite groups with a live action), fall back to the mods
-- that registered settings with the hub.
function SettingsHub:_countActiveMods()
    if RfActionRegistry ~= nil and RfActionRegistry.getRows ~= nil then
        local ok, rows = pcall(RfActionRegistry.getRows)
        if ok and type(rows) == "table" then
            local seen, n = {}, 0
            for _, r in ipairs(rows) do
                if r.group ~= nil and not seen[r.group] then
                    seen[r.group] = true
                    n = n + 1
                end
            end
            if n > 0 then return n end
        end
    end
    return #(self.registerOrder or {})
end

-- Show the one-shot "Realistic Farming Suite is running" note as a top-right side
-- notification (a non-blocking toast, NOT a dialog or a centre-screen message, so
-- it never overlaps a load dialog). Client HUD only - a dedicated server has none.
function SettingsHub:_showWelcomeMessage()
    local mission = g_currentMission
    local hud     = mission ~= nil and mission.hud or nil
    if hud == nil or hud.addSideNotification == nil then
        self._welcomePending = false      -- no HUD (e.g. dedicated server): skip
        return
    end
    local n     = self:_countActiveMods()
    local color = (FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_OK) or nil
    hud:addSideNotification(color,
        string.format("Realistic Farming Suite is running  [%d mods active]", n),
        8000)
    self._welcomePending = false
    if SHLogger ~= nil then
        SHLogger.info("Suite notification shown (%d mods active)", n)
    end
end

-- =========================================================
-- NetworkSync integration (admin values, server -> clients)
-- =========================================================

-- Server: flatten every adminOnly value into [modId, key, value, ...].
-- [MAINTENANCE row 241, Bob's R-15] The array is positional triplets: a nil value would append nothing
-- and shift every later triplet, so the client would refuse every module after it. A nil value has
-- nothing to carry, so its triplet is left out.
-- [MAINTENANCE row 258] The server sends what it shows: a reader's live admin value where one is passed
-- (_shownValue), and records it, so the republish check knows what clients last received.
function SettingsHub:onWriteState()
    local arr = {}
    for _, modId in ipairs(self.registerOrder) do
        local mod = self.modules[modId]
        local sent = {}
        for _, id in ipairs(mod.order) do
            local v = mod.defs[id].adminOnly and self:_shownValue(modId, id) or nil
            if v ~= nil then
                arr[#arr + 1] = modId
                arr[#arr + 1] = id
                arr[#arr + 1] = v
                sent[id] = v
            end
        end
        self.published[modId] = sent
    end
    return arr
end

-- [MAINTENANCE row 258] True when a reader's admin value differs from what the hub last sent.
function SettingsHub:_readMoved()
    for _, modId in ipairs(self.registerOrder) do
        local mod = self.modules[modId]
        if mod.read ~= nil then
            local sent = self.published[modId]
            for _, id in ipairs(mod.order) do
                if mod.defs[id].adminOnly then
                    local v = self:_shownValue(modId, id)
                    if v ~= nil and (sent == nil or sent[id] ~= v) then return true end
                end
            end
        end
    end
    return false
end

-- Client: apply admin values, queueing onChange only for ones that changed.
-- [MAINTENANCE row 241] For a selfPersisted module the hub is a display mirror and live-edit forwarder
-- only, and the companion stays the source of truth (registerModule, above): the client's hub takes the
-- server's value so every editing UI shows it, but the companion's onChange is not called on a client.
-- Each such companion carries its own values to its clients, and several save their own settings from
-- onChange with no server guard (a joined client's savegameDirectory is set: JoinGameScreen.lua:630,
-- FSCareerMissionInfo.lua:13).
function SettingsHub:onReadState(arr)
    if type(arr) ~= "table" then return end
    local i = 1
    while i + 2 <= #arr do
        local modId, key, value = arr[i], arr[i + 1], arr[i + 2]
        local mod = self.modules[modId]
        if mod ~= nil and mod.defs[key] ~= nil then
            local v = self:_validate(mod.defs[key], self:_snapNetworkValue(mod.defs[key], value))
            if v ~= nil and mod.values[key] ~= v then
                mod.values[key] = v
                if not mod.selfPersisted then
                    self:_queue(modId, key, v, nil)
                end
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
    -- [MAINTENANCE row 241] Except a selfPersisted one: it loaded its own value before it registered
    -- and stays its own source of truth (registerModule skips the restore for it). StateLedger delivers
    -- at loadMission00Finished, after the companions registered at Mission00.load, so without this the
    -- hub's stored copy, a mirror that can lag the companion's own settings UI, would overwrite the
    -- real value on every load.
    self.savedAdmin = data or {}
    for modId, block in pairs(self.savedAdmin) do
        local mod = self.modules[modId]
        if mod ~= nil and not mod.selfPersisted then
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

-- [MAINTENANCE row 241] The bedrock handles. Each bedrock mod writes its handle into its OWN mod
-- environment (getfenv(0); the engine gives every mod its own table, mods.lua:482-505) and onto the
-- mission (NetworkSync main.lua:87, StateLedger main.lua:46). Only the mission crosses between mod
-- environments, so a bare g_networkSync / g_stateLedger read here is nil in a game: the mission comes
-- first, the bare global second.
function SettingsHub.networkSyncHandle()
    local mission = g_currentMission
    return (mission ~= nil and mission.networkSync) or g_networkSync
end

function SettingsHub.stateLedgerHandle()
    local mission = g_currentMission
    return (mission ~= nil and mission.stateLedger) or g_stateLedger
end

-- Bind to each bedrock mod once (idempotent). Safe if they are absent. Each handle binds on its own:
-- one found first never locks the other out (a later call binds it when it appears).
function SettingsHub:_bindBedrock()
    local stateLedger = SettingsHub.stateLedgerHandle()
    if not self.stateLedgerBound and stateLedger ~= nil then
        stateLedger:registerModule(SettingsHub.LEDGER_MODULE, {
            serialize   = function() return self:serializeAdmin() end,
            deserialize = function(data) self:deserializeAdmin(data) end,
        })
        self.stateLedgerBound = true
    end
    local networkSync = SettingsHub.networkSyncHandle()
    if not self.networkSyncBound and networkSync ~= nil then
        networkSync:registerModule(SettingsHub.LEDGER_MODULE, {
            channel      = "SettingsHub_Sync",
            onWriteState = function() return self:onWriteState() end,
            onReadState  = function(arr) self:onReadState(arr) end,
        })
        self.networkSyncBound = true
    end
    self.bedrockBound = self.stateLedgerBound == true or self.networkSyncBound == true
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
-- Admin gate (presentation helper for the editing UIs)
-- =========================================================

-- True when the LOCAL player may change an adminOnly setting: the host
-- (single-player or listen-server) or a granted master user on a client. This
-- is the exact predicate the base game uses to gate admin-only actions
-- (g_currentMission:getIsServer() or g_currentMission.isMasterUser); verified
-- against dataS/scripts_decompiled (FSBaseMission, FarmlandManager).
--
-- Presentation ONLY. The server re-checks master rights on receipt in
-- SettingsHubAdminEvent:run and is the sole authority; a client that lies here
-- still has its admin change rejected server-side.
function SettingsHub:isLocalAdmin()
    if g_currentMission == nil then return false end
    return g_currentMission:getIsServer() == true or g_currentMission.isMasterUser == true
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
                id = id, type = def.type, value = self:_shownValue(modId, id), default = def.default,
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

    -- Arm the one-shot suite "is running" notification: a top-right toast shown
    -- ~25s after load (clear of the load-in), once per session, via _showWelcomeMessage.
    self._welcomeTimer   = 25000
    self._welcomePending = true
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
    table.insert(lines, string.format("SettingsHub: %d module(s), %d queued, StateLedger=%s, NetworkSync=%s",
        #self.registerOrder, #self.pending, tostring(self.stateLedgerBound == true), tostring(self.networkSyncBound == true)))
    for _, modId in ipairs(self.registerOrder) do
        local mod = self.modules[modId]
        table.insert(lines, string.format("  %s (%d setting(s))", modId, #mod.order))
    end
    return table.concat(lines, "\n")
end
