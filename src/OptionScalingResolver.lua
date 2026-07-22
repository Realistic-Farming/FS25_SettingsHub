-- =========================================================
-- FS25_SettingsHub - Option-Scaling Resolver (the pure library)
-- =========================================================
-- Author: TisonK
-- Governance: cross-suite AUTHORITY #1 (Arissani design, SDS v2.0 seven-dial,
--   co-signed 2026-07-18). Brief: ecosystem-dev-tracking/systems/option-scaling-spine/
-- =========================================================
-- THE VENDORED HALF of the Option-Scaling Spine. This file is PURE: it depends
-- on nothing but standard Lua and a duck-typed settingsHub handle. It is meant
-- to be copied verbatim into every consumer mod, so the KEY CONTRACT (the module
-- id, the dial names, the value-key shapes) lives here and stays identical
-- across the whole suite by being the same source in every clone.
--
-- The SettingsHub-side profile module (OptionScalingSpine.lua) uses these same
-- constants to register the admin settings, so the writer and every reader agree
-- on the wire names by construction.
--
-- What a consumer does with this file:
--   1. DECLARE each scalable value once:
--        { id, dial, base, curve = {at0,at1,at2,ease}, clampMin, clampMax, neutral }
--   2. READ the profile once per resolve point:
--        local profile = OptionScalingResolver.readProfile(g_currentMission.settingsHub)
--   3. RESOLVE:
--        local eff = OptionScalingResolver.resolve(decl, profile)
--   ...and treat OFF / absent as neutral. Never write back.
--
-- OFF == NOT-INSTALLED == NEUTRAL is the load-bearing contract: an absent hub, an
-- unregistered profile, or a switched-off dial all resolve to the declared
-- neutral, so a system can be turned fully off and the game still plays.
-- =========================================================

OptionScalingResolver = {}

-- Bump only on a wire-contract change (a renamed dial, a new key shape). A
-- consumer can compare this against its vendored copy to detect drift.
OptionScalingResolver.CONTRACT_VERSION = 1

-- The SettingsHub module id the profile registers under. Readers pass this to
-- getValue; it must match OptionScalingSpine.MODULE exactly.
OptionScalingResolver.MODULE = "OptionScalingSpine"

-- The seven dials, in canonical order. Each has one float (intensity) and one
-- bool (its on/off switch) in the profile module.
OptionScalingResolver.DIALS = {
    "economy", "labor", "agronomy", "biological",
    "livestock", "worldEvents", "community",
}

-- Intensity band. A dial float runs 0..2 with 1.0 the neutral midpoint, so a
-- curve whose at1 is 1.0 produces a neutral multiplier at the Standard preset.
-- The exact band and the per-curve endpoints are the ratio pass (BACKLOG-20);
-- these are the structural defaults, not balance.
OptionScalingResolver.INTENSITY_MIN     = 0.0
OptionScalingResolver.INTENSITY_MAX     = 2.0
OptionScalingResolver.INTENSITY_NEUTRAL = 1.0

-- Value-key builders, so the writer and readers never hand-type a key.
function OptionScalingResolver.dialKey(dial)   return "dial_" .. dial end
function OptionScalingResolver.switchKey(dial) return "switch_" .. dial end
OptionScalingResolver.PRESET_KEY = "preset"

-- Preset enum values + a coarse difficulty rank for the tuning-tool gate. The
-- NAMES and RANKS here are provisional structure; the authoritative preset set
-- and the per-preset dial configurations are Arissani's call + the ratio pass.
-- "custom" ranks at Standard so a hand-tuned world does not silently unlock the
-- tuning tools.
OptionScalingResolver.PRESETS = { "relaxed", "standard", "hard", "custom" }
OptionScalingResolver.PRESET_RANK = {
    relaxed = 0, standard = 1, hard = 2, custom = 1,
}
OptionScalingResolver.DEFAULT_PRESET = "standard"

-- The default tuning-tool gate threshold: tools are available BELOW this rank
-- and blocked at it and above (so blocked at Standard+). Arissani owns the final
-- threshold; this is the brief's stated default.
OptionScalingResolver.TOOL_GATE_THRESHOLD = 1  -- PRESET_RANK.standard

-- =========================================================
-- Pure math
-- =========================================================

local function clampNumber(v, lo, hi)
    if lo ~= nil and v < lo then v = lo end
    if hi ~= nil and v > hi then v = hi end
    return v
end

-- Evaluate a curve at an intensity. A curve is three anchor factors at intensity
-- 0 / 1 / 2 with an optional ease exponent, interpolated piecewise:
--   x <= 1 : between at0 and at1
--   x  > 1 : between at1 and at2
-- ease shapes the segment (1 = linear, >1 = slow start, <1 = fast start). A nil
-- curve, or nil anchors, default to 1.0 so a missing curve is a neutral one.
function OptionScalingResolver.curveEval(curve, x)
    if type(x) ~= "number" then x = OptionScalingResolver.INTENSITY_NEUTRAL end
    x = clampNumber(x, OptionScalingResolver.INTENSITY_MIN, OptionScalingResolver.INTENSITY_MAX)

    if type(curve) ~= "table" then return 1.0 end
    local at0  = curve.at0  or 1.0
    local at1  = curve.at1  or 1.0
    local at2  = curve.at2  or 1.0
    local ease = curve.ease or 1.0

    local a, b, t
    if x <= 1.0 then
        a, b, t = at0, at1, x
    else
        a, b, t = at1, at2, x - 1.0
    end
    if ease ~= 1.0 and t > 0 then t = t ^ ease end
    return a + (b - a) * t
end

-- =========================================================
-- Profile reads (duck-typed over any settingsHub with :getValue)
-- =========================================================

-- Is the whole spine present? getValue returns nil for an unregistered module,
-- so a nil preset means the profile never registered (spine not installed) and
-- every read must fall to neutral.
local function spinePresent(settingsHub)
    if settingsHub == nil or type(settingsHub.getValue) ~= "function" then return false end
    return settingsHub:getValue(OptionScalingResolver.MODULE, OptionScalingResolver.PRESET_KEY) ~= nil
end

-- Read the current profile into a plain table the resolver consumes:
--   { dials = { dial -> intensity }, switches = { dial -> bool }, preset = str }
-- Returns nil when the spine is absent, which every consumer treats as neutral.
function OptionScalingResolver.readProfile(settingsHub)
    if not spinePresent(settingsHub) then return nil end

    local dials, switches = {}, {}
    for _, dial in ipairs(OptionScalingResolver.DIALS) do
        local intensity = settingsHub:getValue(OptionScalingResolver.MODULE, OptionScalingResolver.dialKey(dial))
        local sw        = settingsHub:getValue(OptionScalingResolver.MODULE, OptionScalingResolver.switchKey(dial))
        dials[dial]    = (type(intensity) == "number") and intensity or OptionScalingResolver.INTENSITY_NEUTRAL
        switches[dial] = sw ~= false   -- nil (unset) reads as on
    end

    local preset = settingsHub:getValue(OptionScalingResolver.MODULE, OptionScalingResolver.PRESET_KEY)
    return { dials = dials, switches = switches, preset = preset }
end

-- Is a dial switched on? A nil profile or a nil switch table means the spine is
-- absent, which is OFF for every dial. A present profile defaults an unset dial
-- switch to on.
function OptionScalingResolver.isDialOn(profile, dial)
    if profile == nil or profile.switches == nil then return false end
    return profile.switches[dial] ~= false
end

-- =========================================================
-- The resolve + the neutral contract
-- =========================================================

-- The declared neutral for a value, defaulting to 1.0 (a multiplier). A consumer
-- declaring an addend sets neutral = 0. Status / collection reads are not scalars
-- and do not go through resolve(): the consumer gates those on isDialOn() and
-- returns nil / {} itself.
function OptionScalingResolver.neutralOf(decl)
    if decl ~= nil and decl.neutral ~= nil then return decl.neutral end
    return 1.0
end

-- Turn (declaration, profile) into an effective scalar.
--   effective = clamp( base * curveEval(curve, dialIntensity), clampMin, clampMax )
-- OFF / absent short-circuits to the declared neutral BEFORE any math, so no
-- half-arrived profile can produce a non-neutral value.
function OptionScalingResolver.resolve(decl, profile)
    if type(decl) ~= "table" then return 1.0 end
    local neutral = OptionScalingResolver.neutralOf(decl)

    if profile == nil then return neutral end
    if not OptionScalingResolver.isDialOn(profile, decl.dial) then return neutral end

    local intensity = profile.dials and profile.dials[decl.dial]
    if type(intensity) ~= "number" then intensity = OptionScalingResolver.INTENSITY_NEUTRAL end

    local base   = decl.base or 1.0
    local factor = OptionScalingResolver.curveEval(decl.curve, intensity)
    local eff    = base * factor
    return clampNumber(eff, decl.clampMin, decl.clampMax)
end

-- =========================================================
-- The tuning-tool difficulty gate (a consumer of the profile)
-- =========================================================

-- Should a tuning / bypass tool be available under this profile? A nil profile
-- (spine absent) returns true, so a tool falls back to its own local gate rather
-- than being locked by a spine that is not there. Otherwise the preset rank is
-- compared to the threshold: available strictly below it, blocked at and above.
function OptionScalingResolver.isToolAllowed(profile, threshold)
    if profile == nil then return true end
    threshold = threshold or OptionScalingResolver.TOOL_GATE_THRESHOLD
    local rank = OptionScalingResolver.PRESET_RANK[profile.preset]
    if rank == nil then rank = OptionScalingResolver.PRESET_RANK[OptionScalingResolver.DEFAULT_PRESET] end
    return rank < threshold
end
