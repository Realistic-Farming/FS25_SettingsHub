-- maint258_hub_mirror_pull_test.lua - MAINTENANCE row 258: the hub shows a selfPersisted companion's live
-- value through its reader, so a change made in the companion's own UI reaches the hub, its broadcast and
-- every Tablet.
--
-- WHY. For a selfPersisted module the hub stored the value the companion registered with (registerModule,
-- mod.values[id] = def.default) and only the hub's own path ever wrote it again (setValue, onReadState). A
-- change made in the companion's own dialog never reached it: the Tablet (getModules) and the hub's broadcast
-- (onWriteState) kept the stale value, on every machine. Bob's R-15 on row 258 (Desk Office/Drafts/
-- BOB-R15-MAINT258-HUB-MIRROR-SHAPE-2026-10-08.md): PULL. A selfPersisted companion may pass read(key); an
-- admin key is read on the server only and republished within a second when it moves; a local key is read
-- on its own machine; the value is snapped and validated; a failing read shows the mirror and logs once; a
-- key with a change in flight shows the mirror.
--
-- THE ENTRY-POINT BAR (R-18). The machines are row 241's (maint241_bedrock_binding_test.lua): each machine
-- is one game process, StateLedger and NetworkSync stand-ins as mods 1 and 2 put their handles on the
-- mission, and SettingsHub's main.lua and every file it sources run in a mod environment shaped as mods.lua's.
-- The companions register through mission.settingsHub at Mission00.load as the fleet does, and each OWNS
-- its values: its onChange writes its own table and its reader answers from it, as a companion's bridge
-- reads its manager. A change "outside the hub" is a write to that table, as the companion's own dialog
-- makes it. The server's broadcast reaches a client through NetworkSync's tagged encoding (float32). The
-- NetworkSync stand-in models syncNow only, not its 30 s drift floor (NetworkSync.lua:37, :289-293), so a
-- client value that arrives in these rows arrived through the hub's republish.
--
-- Groups:
--   E  the entry point: both machines booted, the companions registered with their readers
--   S  a server change outside the hub shows in the server's getModules at once and a client's within the
--      republish interval; the client never reads its own stale companion for an admin key
--   L  a local key changed outside the hub shows on its own machine, and is never broadcast
--   F  a read that fails validation shows the mirror and logs once
--   N  a module without a reader behaves as before
--   D  a change in flight is not stepped from the companion's not-yet-applied value
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


-- A companion's own number as xmlFile:getFloat gives it: float32 (see f32 above).
local F32_08, F32_09 = f32(0.8), f32(0.9)

-- ── the companions: each owns its values (its onChange writes its table; its reader answers from it) ──
local DEPOT, PLAIN, BAD = "FS25_DepotBench", "FS25_PlainBench", "FS25_BadReadBench"
local function companionSpecs(machine)
    local own = machine.own
    local function owner(modId) return function(key, value) own[modId][key] = value end end
    local function reader(modId) return function(key) return own[modId][key] end end
    local ENUM = { 0.7, 0.8, 0.9 }
    return {
        -- FertilizerDepot's shape: its sellRatio comes from xmlFile:getFloat, so it is float32-inexact.
        { DEPOT, { selfPersisted = true, onChange = owner(DEPOT), read = reader(DEPOT), adminSettings = {
            { id = "sellRatio", type = "enum", values = ENUM, default = own[DEPOT].sellRatio, adminOnly = true },
            { id = "showHud", type = "bool", default = own[DEPOT].showHud, adminOnly = false } } } },
        -- A selfPersisted companion that passes no reader: the hub shows its mirror, as before.
        { PLAIN, { selfPersisted = true, onChange = owner(PLAIN), adminSettings = {
            { id = "sellRatio", type = "enum", values = ENUM, default = own[PLAIN].sellRatio, adminOnly = true } } } },
        -- A reader that answers a value no option explains.
        { BAD, { selfPersisted = true, onChange = owner(BAD), read = function() return 0.75 end, adminSettings = {
            { id = "sellRatio", type = "enum", values = ENUM, default = 0.8, adminOnly = true } } } },
    }
end

--- One machine. kind: "server" or "client". opts.admin (client master user), opts.dir (savegame),
--- opts.depotOwn (the depot's own saved value), opts.ns / opts.sl (false: that mod not installed),
--- opts.nilFirst (a module whose admin value is nil registers first),
--- opts.lateNs (NetworkSync's handle appears only at loadMission00Finished).
local function newMachine(kind, opts)
    opts = opts or {}
    local m = { kind = kind, calls = {}, setter = {}, depotOwn = opts.depotOwn, users = {}, nilFirst = opts.nilFirst,
                own = { ["FS25_DepotBench"] = { sellRatio = F32_08, showHud = true }, ["FS25_PlainBench"] = { sellRatio = 0.8 },
                        ["FS25_BadReadBench"] = {} } }
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

local function shown(m, modId, key)
    local hub = hubOf(m)
    for _, mod in ipairs(on(m, function() return hub:getModules() end)) do
        if mod.modId == modId then
            for _, s in ipairs(mod.settings) do if s.id == key then return s.value end end
        end
    end
    return nil
end
local function sentKeys(m)
    local arr = on(m, function() return hubOf(m):onWriteState() end)
    local out = {}
    for i = 1, #arr, 3 do out[#out + 1] = arr[i] .. "." .. arr[i + 1] end
    return table.concat(out, ",")
end
local function warnings(prefix)
    local n = 0
    for _, w in ipairs(LOG) do if w:find(prefix, 1, true) then n = n + 1 end end
    return n
end
local function world()
    local server = newMachine("server", { dir = "s258" })
    local client = newMachine("client", { admin = false })
    connect(client, server, 7, false)
    boot(server) boot(client)
    tick(server) tick(client)
    return server, client
end

group("E", function()
    local server, client = world()
    T.ok("E0 [reached] main.lua ran in each machine's mod environment, the hub bound the mission's NetworkSync, and the companions registered with their readers",
        hubOf(server) ~= nil and hubOf(client) ~= nil and hubOf(server).networkSyncBound == true
        and hubOf(server).modules[DEPOT] ~= nil and type(hubOf(server).modules[DEPOT].read) == "function"
        and hubOf(server).modules[PLAIN] ~= nil and hubOf(server).modules[PLAIN].read == nil)
end)

group("S", function()
    local server, client = world()
    -- The depot's own dialog on the server sets 0.9, as its manager holds it: float32 from getFloat.
    server.own[DEPOT].sellRatio = F32_09
    T.eq("S1 [entry point] NAMED (row 258): a server change made outside the hub shows in the server's getModules at once, as the declared 0.9 (snapped)",
        tostring(exact(shown(server, DEPOT, "sellRatio"), 0.9)), "true")
    T.eq("S2 and the client's Tablet still shows its stale mirror (the 0.8 its companion registered, float32), before the republish interval",
        tostring(exact(shown(client, DEPOT, "sellRatio"), F32_08)), "true")
    tick(server, 70)   -- 70 frames of 16 ms: past the hub's one-second republish check
    T.eq("S3 within the republish interval the client's getModules shows the server's 0.9, though the client's own companion still holds 0.8 (an admin key is read on the server only)",
        tostring(exact(shown(client, DEPOT, "sellRatio"), 0.9)) .. "/" .. tostring(exact(client.own[DEPOT].sellRatio, F32_08)), "true/true")
end)

group("L", function()
    local server, client = world()
    client.own[DEPOT].showHud = false   -- the client's own dialog, a player-local key
    T.eq("L1 a local key changed outside the hub on a client shows in that client's getModules",
        tostring(shown(client, DEPOT, "showHud")), "false")
    T.eq("L2 the server still shows its own machine's value for it", tostring(shown(server, DEPOT, "showHud")), "true")
    T.ok("L3 a local key is never in the hub's broadcast", not sentKeys(server):find(DEPOT .. ".showHud", 1, true), sentKeys(server))
end)

group("F", function()
    local server = world()
    local before = warnings("read('" .. BAD .. "','sellRatio')")
    local a = shown(server, BAD, "sellRatio")
    local b = shown(server, BAD, "sellRatio")
    T.eq("F1 a read value that fails validation (0.75, no option) shows the hub's mirror (0.8)",
        tostring(exact(a, 0.8)) .. "/" .. tostring(exact(b, 0.8)), "true/true")
    T.eq("F2 and logs once, naming the module and key, however often it is read",
        warnings("read('" .. BAD .. "','sellRatio')") - before, 1)
end)

group("N", function()
    local server, client = world()
    server.own[PLAIN].sellRatio = 0.9   -- changed in its own dialog, but it passed no reader
    tick(server, 70)
    T.eq("N1 a module without a reader shows its mirror, as before, on the server and the client",
        tostring(exact(shown(server, PLAIN, "sellRatio"), 0.8)) .. "/" .. tostring(exact(shown(client, PLAIN, "sellRatio"), 0.8)),
        "true/true")
end)

group("D", function()
    local server = world()
    on(server, function() hubOf(server):setValue(DEPOT, "sellRatio", 0.7) end)
    T.eq("D1 a change in flight: before the hub's queue applies it, the server shows the value just set (0.7), not the companion's not-yet-applied 0.8",
        tostring(exact(on(server, function() return hubOf(server):getValue(DEPOT, "sellRatio") end), 0.7))
        .. "/" .. tostring(exact(server.own[DEPOT].sellRatio, F32_08)), "true/true")
    tick(server, 2)
    T.eq("D2 once the queue applied it, the companion holds 0.7 and the hub reads it from the companion",
        tostring(exact(server.own[DEPOT].sellRatio, 0.7)) .. "/" .. tostring(exact(shown(server, DEPOT, "sellRatio"), 0.7)), "true/true")
end)
