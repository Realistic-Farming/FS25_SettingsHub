-- maint241_bedrock_binding_test.lua - MAINTENANCE row 241: SettingsHub reaches NetworkSync and StateLedger
-- through the mission, so in a game it binds both.
--
-- WHY THIS BAR EXISTS. The engine gives every mod its own environment: a table whose __index is the real
-- _G, with _G set to itself and a getfenv that answers it (dataS mods.lua:482-520, 1.24). NetworkSync and
-- StateLedger write their handles into THEIR environments (getfenv(0), NetworkSync main.lua:41,
-- StateLedger main.lua:36) and onto the mission (:87, :46). SettingsHub read g_networkSync and
-- g_stateLedger as bare globals, nil in a game, so it bound neither: a client admin's change applied on
-- the server and never came back (jamesw8439's Sell Price Ratio), nothing persisted through StateLedger,
-- and the Admin Control Registry's network action never bound. #23's bench assigned g_networkSync as a
-- global, so its fixture supplied the world the code should have found (Bob's trace).
--
-- THE ENTRY-POINT BAR (R-18, Tyson's ruling of 2026-09-22). Each MACHINE is one game process: its own
-- Mission00 / FSBaseMission / FSCareerMissionInfo class tables; StateLedger and NetworkSync stand-ins
-- loaded first as mods 1 and 2, whose Mission00.load puts each handle on the mission and nowhere else;
-- SettingsHub's main.lua and every file it sources run in a mod environment shaped as mods.lua's (no
-- file is in this test's --!load); companions after it register through mission.settingsHub, as the
-- fleet does. The mission runs in the engine's order: Mission00.load, loadMission00Finished, then
-- FSBaseMission.update ticks. A client's request crosses to the server through the real
-- SettingsHubAdminEvent, written in the client's environment and read in the server's through a stream
-- that rounds a float to float32 as the engine does; NetworkSync's frames carry its tagged encoding
-- (RealisticFarmingSyncEvent.lua:49-84). No hub value, handle or registration is set by hand.
--
-- The stand-ins keep their real counterparts' semantics: StateLedger's registerModule delivers late
-- registrations after a parse and delivers each module once (StateLedger.lua:51-99, :122-147) and its
-- file stores numbers as %.17g (StateLedgerXML.lua:22-43), so a save round-trips exactly; NetworkSync's
-- syncNow is server-only and needs g_server (NetworkSync.lua:298-311), registerAction defaults to
-- adminOnly (:143-157), requestAction applies on a host and sends from a client (:382-398), and
-- _applyAction gates an adminOnly action on the master user and resolves the userId (:327-351).
--
-- Groups:
--   E  the entry point: both machines bind both handles from the mission; no real global exists
--   A  a client admin's change: the event, the server's apply and broadcast, the client's value; a
--      selfPersisted companion's onChange runs on the server only (Desk's option A)
--   C  a registrant that is not selfPersisted gets its onChange on a client through onReadState
--   N  a module whose admin value is nil leaves no hole in the broadcast (Bob's R-15 MAJOR)
--   P  StateLedger persistence: a relaunch restores the non-selfPersisted modules (a hub-persisted
--      companion, the Spine, the registry's flag) and never clobbers a selfPersisted companion's own value
--   R  the registry's client invoke reaches the owning mod's setter on the server (Desk's (c))
--   B  each handle binds on its own: StateLedger first never locks NetworkSync out
--
--!source: main.lua, src/Logger.lua, src/SettingsHubAdminEvent.lua, src/AdminControlRegistry.lua, src/OptionScalingResolver.lua, src/OptionScalingSpine.lua, src/SettingsHub.lua, src/InGameMenuPageGuard.lua, src/rf/RfLiveBinding.lua, src/rf/RfActionRegistry.lua, src/rf/RfInputContextGuard.lua, src/gui/RfKeybindActionDialog.lua, src/gui/RfSettingsDialog.lua, src/rf/RfContextInput.lua, src/rf/RfControlCenterInput.lua

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- The engine's GUI surface the Control Center's dialogs touch when main.lua registers them at
-- loadMission00Finished (RfKeybindActionDialog / RfSettingsDialog.register): a dialog base class and a gui
-- that loads nothing. The Control Center is not under test here.
MessageDialog = MessageDialog or { new = function(_, mt) return setmetatable({}, mt) end }
g_gui = g_gui or { loadGui = function() end, showDialog = function() end }
-- The player-local prefs file the save hook writes (SettingsHub:_saveLocalFile): an XML object that
-- takes its writes and loads nothing. Admin values persist through StateLedger, which is under test.
XMLFile = XMLFile or {
    create = function() return { setString = function() end, setBool = function() end, save = function() end, delete = function() end } end,
    loadIfExists = function() return nil end,
}

-- ── float32 and a stream (as #23's bench) ─────────────────────────────────────────────────────
local function f32(x)
    if type(x) ~= "number" or x == 0 or x ~= x or x == math.huge or x == -math.huge then return x end
    local sign = 1
    if x < 0 then sign, x = -1, -x end
    local m, e = x, 0
    while m >= 16777216 do m, e = m / 2, e + 1 end
    while m < 8388608 do m, e = m * 2, e - 1 end
    local r = math.floor(m)
    local f = m - r
    if f > 0.5 or (f == 0.5 and r % 2 == 1) then r = r + 1 end
    while e > 0 do r, e = r * 2, e - 1 end
    while e < 0 do r, e = r / 2, e + 1 end
    return sign * r
end
local function newStream() return { q = {}, i = 0 } end
local function push(s, tag, v) s.q[#s.q + 1] = { tag, v } end
local function pop(s, tag)
    s.i = s.i + 1
    local e = s.q[s.i]
    if e == nil or e[1] ~= tag then error("stream: expected " .. tag .. ", found " .. tostring(e and e[1])) end
    return e[2]
end
function streamWriteString(s, v) push(s, "str", v) end
function streamReadString(s) return pop(s, "str") end
function streamWriteUInt8(s, v) push(s, "u8", v) end
function streamReadUInt8(s) return pop(s, "u8") end
function streamWriteBool(s, v) push(s, "bool", v) end
function streamReadBool(s) return pop(s, "bool") end
function streamWriteInt32(s, v) push(s, "i32", v) end
function streamReadInt32(s) return pop(s, "i32") end
function streamWriteFloat32(s, v) push(s, "f32", f32(v)) end
function streamReadFloat32(s) return pop(s, "f32") end

--- NetworkSync's tagged encoding (RealisticFarmingSyncEvent.lua:49-84): a whole number in int32 range as
--- int32, any other number as float32, booleans and strings as themselves. Write, then read back.
local function nsCarry(arr)
    local s = newStream()
    for _, v in ipairs(arr) do
        local t = type(v)
        if t == "boolean" then
            streamWriteUInt8(s, 0) streamWriteBool(s, v)
        elseif t == "number" then
            if v == v and v ~= math.huge and v ~= -math.huge and math.floor(v) == v and v >= -2147483648 and v <= 2147483647 then
                streamWriteUInt8(s, 1) streamWriteInt32(s, v)
            else
                streamWriteUInt8(s, 2) streamWriteFloat32(s, (v == v) and v or 0)
            end
        else
            streamWriteUInt8(s, 3) streamWriteString(s, v)
        end
    end
    local out = {}
    for i = 1, #arr do
        local tag = streamReadUInt8(s)
        if tag == 0 then out[i] = streamReadBool(s)
        elseif tag == 1 then out[i] = streamReadInt32(s)
        elseif tag == 3 then out[i] = streamReadString(s)
        else out[i] = streamReadFloat32(s) end
    end
    return out
end

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepCopy(x) end
    return out
end

-- ── the engine's mod environment (dataS mods.lua:482-520, 1.24) ──────────────────────────────
local MODDIR = "mods/FS25_SettingsHub/"
local function modEnvironment(modName)
    local env = {}
    _G[modName] = env
    setmetatable(env, { __index = _G })
    env._G = env                                   -- a non-DLC mod (:491-493)
    env.getfenv = function() return env end        -- getfenv answers the mod's table for _G (:495-503)
    env.source = function(filename)                -- the file runs in the mod's environment (:512-519)
        local rel = filename:sub(#MODDIR + 1)
        local text = SOURCE_TEXT[rel]
        if text == nil then error("source: no text for " .. tostring(filename), 2) end
        local chunk, err = load(text, "@" .. rel, "t", env)
        if chunk == nil then error(err, 2) end
        chunk()
    end
    env.InitEventClass = function(classObject, className) InitEventClass(classObject, modName .. "." .. className) end
    return env
end

-- ── machines ──────────────────────────────────────────────────────────────────────────────────
local DISK = {}            -- savegameDirectory -> StateLedger's parsed master file
local LOG = {}             -- SHLogger warnings, each with the machine that logged it
local CURRENT = nil
--- Run fn as `machine`: its mission, its g_server or g_client, as each process has its own.
local function on(machine, fn, ...)
    local prev = { g_currentMission, g_server, g_client, CURRENT }
    g_currentMission, g_server, g_client, CURRENT = machine.mission, machine.server, machine.client, machine
    local res = table.pack(pcall(fn, ...))
    g_currentMission, g_server, g_client, CURRENT = prev[1], prev[2], prev[3], prev[4]
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
end

--- StateLedger, as its mod (StateLedger.lua:31-147, main.lua:36-46).
local function newStateLedger()
    local sl = { registrations = {}, registerOrder = {}, parsedData = {}, deliveredTo = {}, hasParsed = false }
    function sl:registerModule(name, hooks)
        if type(name) ~= "string" or name == "" or type(hooks) ~= "table"
            or type(hooks.serialize) ~= "function" or type(hooks.deserialize) ~= "function" then return false end
        if self.registrations[name] == nil then table.insert(self.registerOrder, name) end
        self.registrations[name] = hooks
        if self.hasParsed then self:_deliver(name) end
        return true
    end
    function sl:_deliver(name)
        if self.deliveredTo[name] then return end
        local hooks = self.registrations[name]
        if hooks == nil then return end
        self.deliveredTo[name] = true
        local ok, err = pcall(hooks.deserialize, deepCopy(self.parsedData[name]))
        if not ok then LOG[#LOG + 1] = "deserialize failed for " .. name .. ": " .. tostring(err) end
    end
    function sl:parseFile()
        if self.hasParsed then return end
        local mi = g_currentMission and g_currentMission.missionInfo
        self.parsedData = deepCopy(mi and DISK[mi.savegameDirectory] or {}) or {}
        self.hasParsed = true
        for _, name in ipairs(self.registerOrder) do self:_deliver(name) end
    end
    function sl:save()
        local mi = g_currentMission and g_currentMission.missionInfo
        if mi == nil or mi.savegameDirectory == nil then return end
        local out = {}
        for _, name in ipairs(self.registerOrder) do out[name] = deepCopy(self.registrations[name].serialize()) end
        DISK[mi.savegameDirectory] = out
    end
    return sl
end

--- NetworkSync, as its mod (NetworkSync.lua:92-157, :298-311, :327-398; main.lua:41, :87).
local function newNetworkSync()
    local ns = { schemas = {}, actions = {}, syncs = 0 }
    function ns:registerModule(modId, schema)
        if type(modId) ~= "string" or type(schema) ~= "table"
            or type(schema.onWriteState) ~= "function" or type(schema.onReadState) ~= "function" then return false end
        self.schemas[modId] = schema
        return true
    end
    function ns:registerAction(actionId, spec)
        if type(actionId) ~= "string" or type(spec) ~= "table" or type(spec.onAction) ~= "function" then return false end
        self.actions[actionId] = { onAction = spec.onAction, adminOnly = spec.adminOnly ~= false }
        return true
    end
    function ns:syncNow(modId)
        if g_currentMission == nil or not g_currentMission:getIsServer() or g_server == nil then return end
        if self.schemas[modId] == nil then return end
        self.syncs = self.syncs + 1
        g_server:broadcastEvent({ frame = true, modId = modId, values = self.schemas[modId].onWriteState() })
    end
    function ns:_applyAction(actionId, args, connection)
        if g_currentMission == nil or not g_currentMission:getIsServer() then return end
        local action = self.actions[actionId]
        if action == nil then return end
        local userId = nil
        if connection ~= nil then
            local user = g_currentMission.userManager and g_currentMission.userManager:getUserByConnection(connection)
            if action.adminOnly and (user == nil or not user:getIsMasterUser()) then return end
            userId = user ~= nil and user:getId() or nil
        end
        pcall(action.onAction, userId, args)
    end
    function ns:requestAction(actionId, args)
        if g_currentMission ~= nil and g_currentMission:getIsServer() then
            self:_applyAction(actionId, args, nil)
            return true
        end
        if g_client ~= nil then
            local conn = g_client:getServerConnection()
            if conn ~= nil then
                conn:sendEvent({ action = true, actionId = actionId, args = args })
                return true
            end
        end
        return false
    end
    --- A client receiving a frame: decode, then the module's onReadState.
    function ns:receiveFrame(ev)
        local schema = self.schemas[ev.modId]
        if schema ~= nil then schema.onReadState(nsCarry(ev.values)) end
    end
    return ns
end

-- ── the companions (registered through mission.settingsHub at Mission00.load, after mod 4) ──────
local DEPOT, CROP, REGMOD, NILMOD = "FS25_DepotBench", "FS25_HubPersistedBench", "FS25_RegistryBench", "FS25_NilBench"
local function companionSpecs(machine)
    local calls = machine.calls
    local function spy(modId) return function(key, value) calls[#calls + 1] = modId .. "." .. key .. "=" .. tostring(value) end end
    local specs = {}
    if machine.nilFirst then
        -- An admin setting with no default: its value is nil until set (registerModule, :137).
        specs[1] = { NILMOD, { onChange = spy(NILMOD), adminSettings = { { id = "unset", type = "float", adminOnly = true } } } }
    end
    local list = {
        -- FertilizerDepot's shape: selfPersisted, its own file holds sellRatio (DepotSettingsHubBridge.lua).
        { DEPOT, { selfPersisted = true, onChange = spy(DEPOT), adminSettings = {
            { id = "sellRatio", type = "enum", values = { 0.7, 0.8, 0.9 }, default = machine.depotOwn or 0.8, adminOnly = true } } } },
        -- A companion that does not persist its own settings: no selfPersisted flag, so the hub owns its
        -- persistence and calls its onChange on clients (as the hub's own Spine and registry flag).
        { CROP, { onChange = spy(CROP), adminSettings = {
            { id = "waterScale", type = "float", min = 0, max = 2, default = 1, adminOnly = true },
            { id = "mode", type = "enum", values = { 0, 1, 2 }, default = 0, adminOnly = true } } } },
        -- A mod declaring one administrative control through the registry (AdminControlRegistry:register).
        { REGMOD, { onChange = function() end, adminSettings = {}, adminControls = {
            { id = "resetThing", label = "Reset", kind = "administrative", scope = "global", widget = "toggle",
              valueBinding = { valueId = "x", default = false,
                               setter = function(v, ctx) machine.setter[#machine.setter + 1] = tostring(v) .. "/" .. tostring(ctx.userId) .. "/" .. tostring(ctx.isAdmin) end } } } } },
    }
    for _, s in ipairs(list) do specs[#specs + 1] = s end
    return specs
end

--- One machine. kind: "server" or "client". opts.admin (client master user), opts.dir (savegame),
--- opts.depotOwn (the depot's own saved value), opts.ns / opts.sl (false: that mod not installed),
--- opts.nilFirst (a module whose admin value is nil registers first),
--- opts.lateNs (NetworkSync's handle appears only at loadMission00Finished).
local function newMachine(kind, opts)
    opts = opts or {}
    local m = { kind = kind, calls = {}, setter = {}, depotOwn = opts.depotOwn, users = {}, nilFirst = opts.nilFirst }
    Mission00, FSBaseMission, FSCareerMissionInfo = {}, {}, { saveToXMLFile = function() end }
    m.classes = { Mission00 = Mission00, FSBaseMission = FSBaseMission, FSCareerMissionInfo = FSCareerMissionInfo }
    m.sl = opts.sl ~= false and newStateLedger() or nil
    m.ns = opts.ns ~= false and newNetworkSync() or nil
    -- mods 1 and 2: each puts its handle on the mission (main.lua's onMissionLoad); nothing global
    if m.sl ~= nil then
        Mission00.load = Utils.appendedFunction(Mission00.load, function(mission) mission.stateLedger = m.sl end)
        Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function() m.sl:parseFile() end)
        FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, function() m.sl:save() end)
    end
    if m.ns ~= nil then
        if opts.lateNs then
            Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function(mission) mission.networkSync = m.ns end)
        else
            Mission00.load = Utils.appendedFunction(Mission00.load, function(mission) mission.networkSync = m.ns end)
        end
    end
    -- mod 4: SettingsHub, its main.lua sourced as the engine sources it
    g_currentModDirectory, g_currentModName = MODDIR, "FS25_SettingsHub"
    m.env = modEnvironment("FS25_SettingsHub")
    assert(load(SOURCE_TEXT["main.lua"], "@main.lua", "t", m.env))()
    m.env.SHLogger.warning = function(fmt, ...) LOG[#LOG + 1] = kind .. ": " .. string.format(fmt, ...) end
    m.env.SHLogger.info = function() end
    m.env.SHLogger.debug = function() end
    -- the companions, after it
    Mission00.load = Utils.appendedFunction(Mission00.load, function(mission)
        for _, c in ipairs(companionSpecs(m)) do mission.settingsHub:registerModule(c[1], c[2]) end
    end)
    m.mission = { missionInfo = { savegameDirectory = opts.dir or "save1" }, isMasterUser = kind == "client" and opts.admin == true }
    function m.mission:getIsServer() return kind == "server" end
    if kind == "server" then
        m.server = { broadcastEvent = function(_, ev) for _, c in ipairs(m.clients) do on(c, function() c.ns:receiveFrame(ev) end) end end }
        m.clients = {}
        m.mission.userManager = {
            getUserByConnection = function(_, conn) return conn and conn.user end,
            getUserByUserId = function(_, id) return m.users[id] end,
        }
    end
    return m
end

--- Connect a client to a server: the client's server connection carries its events to the server,
--- where they arrive on the client's connection (its user: master or not).
local function connect(client, server, userId, admin)
    local user = { getId = function() return userId end, getIsMasterUser = function() return admin == true end, getNickname = function() return "p" .. userId end }
    server.users[userId] = user
    local connOnServer = { user = user, getIsServer = function() return false end }
    client.client = { getServerConnection = function()
        return { sendEvent = function(_, ev)
            if ev.action then
                local args = nsCarry(ev.args)
                on(server, function() server.ns:_applyAction(ev.actionId, args, connOnServer) end)
            else
                local s = newStream()
                ev:writeStream(s, nil)                                -- written on the client
                on(server, function()                                 -- read on the server, its own class
                    local e = server.env.SettingsHubAdminEvent.emptyNew()
                    e:readStream(s, connOnServer)
                end)
            end
        end }
    end }
    table.insert(server.clients, client)
end

local function boot(m)
    on(m, function()
        m.classes.Mission00.load(m.mission)
        m.classes.Mission00.loadMission00Finished(m.mission)
    end)
end
local function tick(m, n)
    on(m, function() for _ = 1, n or 10 do m.classes.FSBaseMission.update(m.mission, 16) end end)
end
local function hubOf(m) return m.mission.settingsHub end
local function callsOf(m, prefix)
    local out = {}
    for _, c in ipairs(m.calls) do if c:sub(1, #prefix) == prefix then out[#out + 1] = c end end
    return table.concat(out, ",")
end
local function mark(m) return #m.calls end
local function callsSince(m, n)
    local out = {}
    for i = n + 1, #m.calls do out[#out + 1] = m.calls[i] end
    return table.concat(out, ",")
end
local function exact(v, want) return v == want end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY POINT: BOTH MACHINES BIND BOTH HANDLES FROM THE MISSION
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local server = newMachine("server", { dir = "e1" })
    local client = newMachine("client", { admin = true })
    connect(client, server, 7, true)
    boot(server)
    boot(client)
    local LEDGER = server.env.SettingsHub.LEDGER_MODULE
    T.ok("E0 [reached] main.lua ran in each machine's own mod environment: the hub is on the mission and in the mod's table, and no real global names a hub or a bedrock handle",
        hubOf(server) ~= nil and hubOf(client) ~= nil and rawget(server.env, "g_settingsHub") == hubOf(server)
        and rawget(_G, "g_settingsHub") == nil and rawget(_G, "g_networkSync") == nil and rawget(_G, "g_stateLedger") == nil)
    local s = server.ns.schemas[LEDGER]
    T.eq("E1 [entry point] the server's hub registered on the mission's StateLedger and NetworkSync, on its channel",
        tostring(server.sl.registrations[LEDGER] ~= nil) .. "/" .. tostring(s ~= nil and s.channel) .. "/" .. tostring(hubOf(server).stateLedgerBound) .. "/" .. tostring(hubOf(server).networkSyncBound),
        "true/SettingsHub_Sync/true/true")
    T.eq("E2 the client's hub registered on its own mission's NetworkSync and StateLedger the same way",
        tostring(client.ns.schemas[LEDGER] ~= nil) .. "/" .. tostring(client.sl.registrations[LEDGER] ~= nil), "true/true")
    local action = server.ns.actions[server.env.AdminControlRegistry.ACTION_ID]
    T.eq("E3 the registry's invoke action bound to the mission's NetworkSync at loadMission00Finished, not admin-gated there (the registry gates each control)",
        tostring(action ~= nil) .. "/" .. tostring(action and action.adminOnly) .. "/" .. tostring(hubOf(server).registry.actionBound), "true/false/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. A CLIENT ADMIN'S CHANGE: EVENT, SERVER APPLY, BROADCAST, CLIENT VALUE
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    local server = newMachine("server", { dir = "a1" })
    local admin = newMachine("client", { admin = true })
    local other = newMachine("client", { admin = false })
    connect(admin, server, 7, true)
    connect(other, server, 8, false)
    boot(server) boot(admin) boot(other)
    tick(server) tick(admin) tick(other)
    local s0, a0, o0 = mark(server), mark(admin), mark(other)
    local syncs0 = server.ns.syncs
    on(admin, function() hubOf(admin):setValue(DEPOT, "sellRatio", 0.9) end)
    T.eq("A1 [entry point] the client admin's change crossed as the real event (float32's 0.9), the server applied it as the declared 0.9 and broadcast once through the mission's NetworkSync",
        tostring(exact(hubOf(server):getValue(DEPOT, "sellRatio"), 0.9)) .. "/" .. (server.ns.syncs - syncs0), "true/1")
    tick(server) tick(admin) tick(other)
    -- Desk's option A, the hub's own selfPersisted contract (SettingsHub.lua:124-129): for a selfPersisted
    -- module the hub is a display mirror and live-edit forwarder; the companion stays the source of truth
    -- and carries its own value to its clients. So a client's hub takes the value, and the companion's
    -- onChange runs on the server only.
    T.eq("A2 NAMED (jamesw8439's Sell Price Ratio): the broadcast reached both clients; each client's hub now holds 0.9 exactly (what the Tablet reads); the selfPersisted depot's onChange ran on the server and not on either client",
        tostring(exact(hubOf(admin):getValue(DEPOT, "sellRatio"), 0.9)) .. "/" .. tostring(exact(hubOf(other):getValue(DEPOT, "sellRatio"), 0.9))
            .. "|" .. callsSince(server, s0) .. "|" .. callsSince(admin, a0) .. "|" .. callsSince(other, o0),
        "true/true|FS25_DepotBench.sellRatio=0.9||")
    on(admin, function() hubOf(admin):setValue(DEPOT, "sellRatio", 0.7) end)
    tick(server) tick(admin)
    T.eq("A3 the next press steps on from the value the client now holds", tostring(exact(hubOf(admin):getValue(DEPOT, "sellRatio"), 0.7)) .. "/" .. tostring(exact(hubOf(server):getValue(DEPOT, "sellRatio"), 0.7)), "true/true")
    local syncs1, n0 = server.ns.syncs, #LOG
    on(other, function() hubOf(other):setValue(DEPOT, "sellRatio", 0.8) end)
    T.eq("A4 a client that is not the master user is refused on the server, logged, and nothing is broadcast",
        tostring(exact(hubOf(server):getValue(DEPOT, "sellRatio"), 0.7)) .. "/" .. (server.ns.syncs - syncs1) .. "/" .. tostring(LOG[n0 + 1]),
        "true/0/server: Rejected admin setting change from a non-admin connection")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A REGISTRANT THAT IS NOT selfPersisted GETS ITS onChange ON A CLIENT THROUGH onReadState
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local server = newMachine("server", { dir = "c1" })
    local client = newMachine("client", { admin = false })
    connect(client, server, 9, false)
    boot(server) boot(client)
    tick(server) tick(client)
    local c0 = mark(client)
    on(server, function()
        hubOf(server):setValue(CROP, "waterScale", 1.35)
        hubOf(server):setValue(CROP, "mode", 2)
    end)
    tick(client)
    T.eq("C1 [entry point] a host admin's changes reach the client's hub (1.35 as float32 carries it, 2 exactly) and each changed setting's onChange runs on the client, once",
        tostring(exact(hubOf(client):getValue(CROP, "waterScale"), f32(1.35))) .. "/" .. tostring(hubOf(client):getValue(CROP, "mode")) .. "|" .. callsSince(client, c0),
        "true/2|" .. "FS25_HubPersistedBench.waterScale=" .. tostring(f32(1.35)) .. ",FS25_HubPersistedBench.mode=2")
    local c1 = mark(client)
    on(server, function() server.ns:syncNow(server.env.SettingsHub.LEDGER_MODULE) end)
    tick(client)
    T.eq("C2 the same values again change nothing on the client and run no onChange", callsSince(client, c1), "")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. A NIL ADMIN VALUE LEAVES NO HOLE IN THE BROADCAST (Bob's R-15 MAJOR)
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    -- onWriteState's array is positional triplets; a nil value used to append nothing and shift every
    -- later triplet, so onReadState refused every module after it. Dead while nothing broadcast; live now.
    local server = newMachine("server", { dir = "n1", nilFirst = true })
    local client = newMachine("client", { admin = false, nilFirst = true })
    connect(client, server, 9, false)
    boot(server) boot(client)
    tick(server) tick(client)
    on(server, function() hubOf(server):setValue(CROP, "mode", 2) end)
    tick(client)
    local frame = on(server, function() return hubOf(server):onWriteState() end)
    T.eq("N1 NAMED: with a nil-valued module registered first, the broadcast stays whole triplets and the later module's value still reaches the client",
        (#frame % 3) .. "/" .. tostring(frame[1] ~= NILMOD) .. "/" .. tostring(hubOf(client):getValue(CROP, "mode")), "0/true/2")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. STATELEDGER PERSISTENCE ACROSS A RELAUNCH
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    local server = newMachine("server", { dir = "p1" })
    boot(server)
    tick(server)
    local RES = server.env.OptionScalingResolver
    local SPINE, DIAL = RES.MODULE, RES.dialKey("economy")
    on(server, function()
        local hub = hubOf(server)
        hub:setValue(CROP, "mode", 2)
        hub:setValue(SPINE, DIAL, 1.25)
        hub.registry:setCreativeWorld(true)
        hub:setValue(DEPOT, "sellRatio", 0.9)       -- the hub's mirror of the depot: 0.9
        server.classes.FSCareerMissionInfo.saveToXMLFile(server.mission.missionInfo)
    end)
    local saved = DISK["p1"] and DISK["p1"][server.env.SettingsHub.LEDGER_MODULE] or {}
    T.eq("P1 [entry point] the save wrote the hub's admin values through the mission's StateLedger",
        tostring(saved[CROP] and saved[CROP].mode) .. "/" .. tostring(saved[SPINE] and saved[SPINE][DIAL]) .. "/" .. tostring(saved.AdminControlRegistry and saved.AdminControlRegistry.creativeWorld),
        "2/1.25/true")
    -- A relaunch: a new process loads the save. The depot's own file says 0.7 (its own settings dialog
    -- changed it after the hub's last mirror), so it registers 0.7; the hub's stored copy says 0.9.
    local again = newMachine("server", { dir = "p1", depotOwn = 0.7 })
    boot(again)
    tick(again, 40)
    local hub = hubOf(again)
    T.eq("P2 NAMED (Desk's (b)): the relaunch restores the non-selfPersisted modules: the hub-persisted companion's mode, the Spine's dial and the registry's creative flag, and the companion's onChange applies its restored value",
        tostring(hub:getValue(CROP, "mode")) .. "/" .. tostring(hub:getValue(SPINE, DIAL)) .. "/" .. tostring(hub.registry:isCreativeWorld()) .. "|" .. callsOf(again, CROP .. ".mode"),
        "2/1.25/true|FS25_HubPersistedBench.mode=0,FS25_HubPersistedBench.mode=2")
    T.eq("P3 NAMED: the selfPersisted depot keeps its own 0.7; the hub's stored 0.9 never clobbers it, and no restore replays through its onChange",
        tostring(exact(hub:getValue(DEPOT, "sellRatio"), 0.7)) .. "|" .. callsOf(again, DEPOT), "true|")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE REGISTRY'S CLIENT INVOKE
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local server = newMachine("server", { dir = "r1" })
    local admin = newMachine("client", { admin = true })
    local other = newMachine("client", { admin = false })
    connect(admin, server, 7, true)
    connect(other, server, 8, false)
    boot(server) boot(admin) boot(other)
    on(admin, function() hubOf(admin).registry:invoke(REGMOD, "resetThing", true, 0) end)
    T.eq("R1 [entry point] NAMED (Desk's (c)): a client admin's invoke crosses through the mission's NetworkSync and the server performs it through the owning mod's setter, with the client's userId as an admin",
        table.concat(server.setter, ","), "true/7/true")
    on(other, function() hubOf(other).registry:invoke(REGMOD, "resetThing", false, 0) end)
    T.eq("R2 a client that is not the master user is refused by the registry's own gate on the server: the setter does not run",
        table.concat(server.setter, ","), "true/7/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. EACH HANDLE BINDS ON ITS OWN
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    -- StateLedger's handle is on the mission at the companions' registrations; NetworkSync's appears only
    -- at loadMission00Finished. Before this row, the first bind set one flag for both and NetworkSync
    -- was never bound (SettingsHub.lua:421 at 0e43ed6).
    local server = newMachine("server", { dir = "b1", lateNs = true })
    local client = newMachine("client", { admin = true })
    connect(client, server, 7, true)
    boot(server) boot(client)
    local LEDGER = server.env.SettingsHub.LEDGER_MODULE
    local syncs0 = server.ns.syncs
    on(client, function() hubOf(client):setValue(CROP, "mode", 1) end)
    tick(client)
    T.eq("B1 StateLedger bound first does not lock NetworkSync out: the server binds it when it appears, and a client's change comes back",
        tostring(server.ns.schemas[LEDGER] ~= nil) .. "/" .. (server.ns.syncs - syncs0) .. "/" .. tostring(hubOf(client):getValue(CROP, "mode")), "true/1/1")
    local lone = newMachine("server", { dir = "b2", ns = false, sl = false })
    boot(lone)
    T.eq("B2 with neither mod installed the hub binds nothing and still runs", tostring(hubOf(lone).bedrockBound) .. "/" .. tostring(hubOf(lone) ~= nil), "false/true")
end)
