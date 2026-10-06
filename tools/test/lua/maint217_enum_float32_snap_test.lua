-- maint217_enum_float32_snap_test.lua - MAINTENANCE row 217: an enum option float32 cannot hold
-- exactly survives both network paths.
--
-- WHY THIS BAR EXISTS. A number that is not whole crosses the network as float32: the admin event
-- (src/SettingsHubAdminEvent.lua, writeStream and readStream) and NetworkSync's sync frames
-- (FS25_NetworkSync/src/RealisticFarmingSyncEvent.lua, writeValue and readValue, :49-84). So a declared
-- 0.8 arrives as 0.800000011920929, and _validate's exact enum check refused it with no log: a client
-- admin's change never applied on the server, and a host admin's change never reached a client.
--
-- ENTRY POINTS (R-18). Server: the real SettingsHubAdminEvent, written and read through a stream that
-- rounds a float to float32 as the engine's streamWriteFloat32 does; its own run() decides the sender is
-- a master user and calls the hub. Client: the hub's own _bindBedrock registering on a NetworkSync
-- stand-in, which carries each value with NetworkSync's own tagged encoding (int32 for a whole number,
-- float32 otherwise) into the onReadState the hub registered. No hub value is set by hand: every value
-- is reached through registerModule, setValue or the wire.
--
--!load: src/Logger.lua, src/SettingsHubAdminEvent.lua, src/AdminControlRegistry.lua, src/OptionScalingResolver.lua, src/OptionScalingSpine.lua, src/SettingsHub.lua

local WARN = {}
SHLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SHLogger.info = function() end
SHLogger.debug = function() end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

--- x rounded to float32 (24 significant bits, ties to even), by exact steps of two: what the
--- engine's streamWriteFloat32 then streamReadFloat32 hand back.
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

-- ── a stream: the engine's stream functions over a queue; a float leaves as float32 ──
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

local MOD = "FS25_Bench"
local function defs()
    return {
        { id = "rate", type = "enum", values = { 0.08, 0.15, 0.25, 0.8, 1 }, default = 1, adminOnly = true },
        { id = "mode", type = "enum", values = { 0, 1, 2 }, default = 0, adminOnly = true },
        { id = "fine", type = "float", default = 0.5, min = 0, max = 1, adminOnly = true },
    }
end
local function hubWith()
    local hub = SettingsHub.new()
    local ok = hub:registerModule(MOD, { adminSettings = defs(), onChange = function() end })
    return hub, ok
end
local function lastQueued(hub, key)
    for i = #hub.pending, 1, -1 do
        local p = hub.pending[i]
        if p.modId == MOD and p.key == key then return p.value end
    end
    return nil
end
local function queuedCount(hub, key)
    local n = 0
    for _, p in ipairs(hub.pending) do if p.modId == MOD and p.key == key then n = n + 1 end end
    return n
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE SERVER: A CLIENT ADMIN'S CHANGE, THROUGH THE REAL ADMIN EVENT
-- ══════════════════════════════════════════════════════════════════════════
local SYNCS = 0
local function server()
    local hub, ok = hubWith()
    g_settingsHub = hub
    SYNCS = 0
    g_networkSync = { syncNow = function() SYNCS = SYNCS + 1 end, registerModule = function() end }
    g_currentMission = { getIsServer = function() return true end,
                         userManager = { getUserByConnection = function(_, c) return c.user end } }
    return hub, ok
end
local ADMIN = { getIsServer = function() return false end, user = { getIsMasterUser = function() return true end } }
local PLAYER = { getIsServer = function() return false end, user = { getIsMasterUser = function() return false end } }
--- A client's request: the real event written on the client, read on the server (readStream ends in run).
local function overTheWire(key, value, conn)
    local out = SettingsHubAdminEvent.new(MOD, key, value)
    local s = newStream()
    out:writeStream(s, nil)
    local inn = SettingsHubAdminEvent.emptyNew()
    inn:readStream(s, conn)
    return inn, s
end
local function wireTag(s) return s.q[3] and s.q[3][2] end

group("S", function()
    local hub, ok = server()
    local base = queuedCount(hub, "rate")   -- registerModule queues each setting once (apply-on-load)
    T.ok("S0 [entry point] the bench module registered on a real hub (three admin settings)", ok == true and hub:getValue(MOD, "rate") == 1)
    local inn, s = overTheWire("rate", 0.8, ADMIN)
    T.eq("S1 the request crossed the wire as a float, and what the server read is float32's 0.8, not 0.8",
        tostring(wireTag(s) == SettingsHubAdminEvent.T_FLOAT) .. "/" .. tostring(inn.value ~= 0.8) .. "/" .. string.format("%.15f", inn.value), "true/true/0.800000011920929")
    T.eq("S2 NAMED: without the snap the exact check refuses that value (the defect's input)",
        tostring(hub:_validate(hub.modules[MOD].defs.rate, inn.value)), "nil")
    T.eq("S3 NAMED: a client admin's 0.8 applies on the server as the declared option 0.8 exactly, queued once, broadcast once",
        tostring(hub:getValue(MOD, "rate") == 0.8) .. "/" .. tostring(lastQueued(hub, "rate") == 0.8) .. "/" .. (queuedCount(hub, "rate") - base) .. "/" .. SYNCS, "true/true/1/1")
    overTheWire("rate", 0.15, ADMIN)
    local at15 = hub:getValue(MOD, "rate")
    overTheWire("rate", 0.08, ADMIN)
    T.eq("S4 the same for 0.15 and 0.08", tostring(at15 == 0.15) .. "/" .. tostring(hub:getValue(MOD, "rate") == 0.08), "true/true")
    overTheWire("rate", 0.7, ADMIN)
    T.eq("S5 NAMED: a value no option explains is still refused: the setting keeps 0.08, nothing queued or broadcast",
        tostring(hub:getValue(MOD, "rate") == 0.08) .. "/" .. (queuedCount(hub, "rate") - base) .. "/" .. SYNCS, "true/3/3")
    overTheWire("rate", 0.800001, ADMIN)
    T.eq("S6 NAMED: a value a millionth from 0.8 (ten float32 steps) is not 0.8: refused", tostring(hub:getValue(MOD, "rate") == 0.08) .. "/" .. SYNCS, "true/3")
    overTheWire("rate", 0.25, ADMIN)
    overTheWire("mode", 2, ADMIN)
    local _, sInt = overTheWire("mode", 1, ADMIN)
    T.eq("S7 an option float32 holds exactly (0.25) and a whole-number enum (sent as int32) apply as before",
        tostring(hub:getValue(MOD, "rate") == 0.25) .. "/" .. tostring(hub:getValue(MOD, "mode")) .. "/" .. tostring(wireTag(sInt) == SettingsHubAdminEvent.T_INT), "true/1/true")
    overTheWire("rate", 0.8, PLAYER)
    T.eq("S8 a client that is not a master user is still refused by the event's own gate", tostring(hub:getValue(MOD, "rate") == 0.25), "true")
    overTheWire("fine", 0.3, ADMIN)
    T.eq("S9 a float setting is not snapped: it keeps the float32 value it was sent", string.format("%.15f", hub:getValue(MOD, "fine")), string.format("%.15f", f32(0.3)))
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE CLIENT: A HOST ADMIN'S CHANGE, THROUGH THE HUB'S OWN NETWORKSYNC REGISTRATION
-- ══════════════════════════════════════════════════════════════════════════
--- NetworkSync's tagged encoding (RealisticFarmingSyncEvent.lua:49-84): a whole number in int32 range
--- as int32, any other number as float32, booleans and strings as themselves.
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
local function valueIn(arr, key)
    for i = 1, #arr - 2, 3 do if arr[i] == MOD and arr[i + 1] == key then return arr[i + 2] end end
    return nil
end

group("C", function()
    local host = server()
    -- NetworkSync is present before the client hub's first registerModule, which binds the hub
    -- (registerModule ends in _bindBedrock, src/SettingsHub.lua:179; idempotent after that).
    local REG = {}
    g_stateLedger = nil
    g_networkSync = { registerModule = function(_, name, spec) REG[name] = spec end, syncNow = function() SYNCS = SYNCS + 1 end }
    local client = hubWith()
    local cbase = queuedCount(client, "rate")
    local spec = REG[SettingsHub.LEDGER_MODULE]
    T.ok("C0 [entry point] the client hub registered itself on NetworkSync through its own registerModule and _bindBedrock, on its channel",
        spec ~= nil and spec.channel == "SettingsHub_Sync" and type(spec.onReadState) == "function" and client.bedrockBound == true)
    g_settingsHub = host
    local okSet = host:setValue(MOD, "rate", 0.8)
    local frame = nsCarry(host:onWriteState())
    local carried = valueIn(frame, "rate")
    T.eq("C1 the host stored 0.8 exactly, and its frame carried float32's 0.8 to the client",
        tostring(okSet) .. "/" .. tostring(host:getValue(MOD, "rate") == 0.8) .. "/" .. string.format("%.15f", carried), "true/true/0.800000011920929")
    T.eq("C2 NAMED: without the snap the client's exact check refuses the carried value (the defect's input)",
        tostring(client:_validate(client.modules[MOD].defs.rate, carried)), "nil")
    spec.onReadState(frame)
    T.eq("C3 NAMED: the host's 0.8 reaches the client as the declared option 0.8 exactly, queued once",
        tostring(client:getValue(MOD, "rate") == 0.8) .. "/" .. tostring(lastQueued(client, "rate") == 0.8) .. "/" .. (queuedCount(client, "rate") - cbase), "true/true/1")
    spec.onReadState(frame)
    T.eq("C4 the same frame again changes nothing and queues nothing", queuedCount(client, "rate") - cbase, 1)
    host:setValue(MOD, "rate", 0.15)
    host:setValue(MOD, "mode", 2)
    spec.onReadState(nsCarry(host:onWriteState()))
    T.eq("C5 0.15 arrives as 0.15, and a whole-number enum as before",
        tostring(client:getValue(MOD, "rate") == 0.15) .. "/" .. tostring(client:getValue(MOD, "mode")), "true/2")
    spec.onReadState(nsCarry({ MOD, "rate", 0.7, MOD, "mode", 7 }))
    T.eq("C6 NAMED: a carried value no option explains is still refused on the client (rate keeps 0.15, mode keeps 2)",
        tostring(client:getValue(MOD, "rate") == 0.15) .. "/" .. tostring(client:getValue(MOD, "mode")), "true/2")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. THE SNAP'S OWN EDGES
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    local hub = SettingsHub.new()
    local enum = { type = "enum", values = { 0, 0.8, "low" } }
    --- The snap called under pcall, so a raise fails the row that names it, not the whole group.
    local function snap(def, v)
        local ok, r = pcall(hub._snapNetworkValue, hub, def, v)
        if not ok then return "raised: " .. tostring(r) end
        return r
    end
    T.eq("U1 zero is matched only exactly: a tiny number is not taken as the option 0", tostring(hub:_snapNetworkValue(enum, 1e-30)), "1e-30")
    T.eq("U2 NAMED: a string value is left to the exact check, never raised on", tostring(snap(enum, "low")), "low")
    T.eq("U3 NAMED: a non-number value passes through unchanged, never raised on", tostring(snap(enum, true)), "true")
    T.eq("U4 a float or int def is never snapped", string.format("%.15f", hub:_snapNetworkValue({ type = "float" }, f32(0.8))), "0.800000011920929")
    T.eq("U5 NaN is returned as it came, for the exact check to refuse", tostring(hub:_snapNetworkValue(enum, 0 / 0) ~= hub:_snapNetworkValue(enum, 0 / 0)), "true")
    T.eq("U6 the only warning logged is S8's refusal of a non-admin sender", #WARN .. "/" .. tostring(WARN[1] ~= nil and WARN[1]:find("non%-admin") ~= nil), "1/true")
end)
