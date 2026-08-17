-- Integration test for the Option-Scaling Spine profile module against a mock
-- SettingsHub: it must register exactly seven dials + seven switches + one preset,
-- all neutral by default, and read them back through getProfile.
--
--!load: src/OptionScalingResolver.lua, src/OptionScalingSpine.lua

SHLogger = { info = function() end, debug = function() end, warning = function() end, error = function() end }

local R = OptionScalingResolver

-- Mock hub: captures the registered spec and serves defaults back through getValue.
local store, captured = {}, nil
local hub = {
    registerModule = function(_self, modId, spec)
        captured = { modId = modId, spec = spec }
        for _, d in ipairs(spec.adminSettings) do store[d.id] = d.default end
        return true
    end,
    getValue = function(_self, modId, key)
        if modId ~= OptionScalingSpine.MODULE then return nil end
        return store[key]
    end,
}

local spine = OptionScalingSpine.new(hub)
spine:onMissionLoaded()

T.ok("registerModule was called", captured ~= nil)
T.eq("registered under the resolver's module id", captured and captured.modId, R.MODULE)

-- 7 dials + 7 switches + 1 preset = 15 defs, all adminOnly.
local defs = captured and captured.spec.adminSettings or {}
T.eq("def count = 15", #defs, 15)
do
    local adminAll, floats, bools, enums = true, 0, 0, 0
    for _, d in ipairs(defs) do
        if d.adminOnly ~= true then adminAll = false end
        if d.type == "float" then floats = floats + 1 end
        if d.type == "bool"  then bools = bools + 1 end
        if d.type == "enum"  then enums = enums + 1 end
    end
    T.ok("all defs adminOnly", adminAll)
    T.eq("7 float dials", floats, 7)
    T.eq("7 bool switches", bools, 7)
    T.eq("1 preset enum", enums, 1)
end

-- Registered idempotently: a second call must not re-register.
captured = nil
spine:onMissionLoaded()
T.eq("idempotent register (no second call)", captured, nil)

-- getProfile reads the defaults back: every dial neutral, every switch on, preset standard.
local p = spine:getProfile()
T.ok("getProfile -> table", p ~= nil)
T.eq("default preset standard", p and p.preset, R.DEFAULT_PRESET)
do
    local allNeutral, allOn = true, true
    for _, dial in ipairs(R.DIALS) do
        if math.abs((p.dials[dial] or -1) - R.INTENSITY_NEUTRAL) > 1e-9 then allNeutral = false end
        if p.switches[dial] ~= true then allOn = false end
    end
    T.ok("every dial defaults neutral", allNeutral)
    T.ok("every switch defaults on", allOn)
end
