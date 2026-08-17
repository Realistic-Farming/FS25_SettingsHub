-- Contract test for the Option-Scaling Resolver (the pure vendored library).
-- The load-bearing property is OFF == NOT-INSTALLED == NEUTRAL, and the most
-- delicate case is off-neutralizes-in-flight (flip a dial off mid-save and every
-- value riding it returns to neutral, never orphaned). Those are proven here.
--
--!load: src/OptionScalingResolver.lua

local R = OptionScalingResolver

-- ── curveEval: shape + neutral midpoint + x clamp + ease ─────
local curve = { at0 = 0.5, at1 = 1.0, at2 = 2.0 }
T.near("curve nil -> neutral 1.0",     R.curveEval(nil, 0.3), 1.0, 1e-9)
T.near("curve neutral at x=1",         R.curveEval(curve, 1.0), 1.0, 1e-9)
T.near("curve low end at x=0",         R.curveEval(curve, 0.0), 0.5, 1e-9)
T.near("curve high end at x=2",        R.curveEval(curve, 2.0), 2.0, 1e-9)
T.near("curve mid-low at x=0.5",       R.curveEval(curve, 0.5), 0.75, 1e-9)
T.near("curve mid-high at x=1.5",      R.curveEval(curve, 1.5), 1.5, 1e-9)
T.near("curve clamps x below 0",       R.curveEval(curve, -1.0), 0.5, 1e-9)
T.near("curve clamps x above 2",       R.curveEval(curve, 3.0), 2.0, 1e-9)
T.near("curve ease^2 at x=0.5",        R.curveEval({ at0 = 0.0, at1 = 1.0, ease = 2.0 }, 0.5), 0.25, 1e-9)

-- ── resolve: OFF == NOT-INSTALLED == neutral ─────────────────
local mult = { id = "m", dial = "agronomy", base = 10.0, curve = curve }   -- neutral = 1.0 (default)
local addend = { id = "a", dial = "economy", base = 5.0, curve = curve, neutral = 0.0 }

T.near("resolve nil profile -> neutral (multiplier)", R.resolve(mult, nil), 1.0, 1e-9)
T.near("resolve nil profile -> neutral (addend 0)",   R.resolve(addend, nil), 0.0, 1e-9)

local function profile(dials, switches, preset)
    return { dials = dials or {}, switches = switches or {}, preset = preset }
end

-- dial ON at neutral intensity -> base * 1.0
local onNeutral = profile({ agronomy = 1.0 }, { agronomy = true })
T.near("resolve on, neutral intensity", R.resolve(mult, onNeutral), 10.0, 1e-9)

-- dial ON at intensity 0 -> base * 0.5
local onLow = profile({ agronomy = 0.0 }, { agronomy = true })
T.near("resolve on, low intensity", R.resolve(mult, onLow), 5.0, 1e-9)

-- clampMax / clampMin bound the result
local clamped = { id = "c", dial = "agronomy", base = 10.0, curve = curve, clampMin = 8.0, clampMax = 15.0 }
T.near("resolve clampMax", R.resolve(clamped, profile({ agronomy = 2.0 }, { agronomy = true })), 15.0, 1e-9)
T.near("resolve clampMin", R.resolve(clamped, profile({ agronomy = 0.0 }, { agronomy = true })), 8.0, 1e-9)

-- ── the never-stuck guarantee: off neutralizes in-flight ─────
-- Same declaration, same live profile, only the dial switch flips off. The value
-- must return to neutral, not keep its last non-neutral figure.
local live = profile({ agronomy = 2.0 }, { agronomy = true })
T.near("in-flight value while ON", R.resolve(mult, live), 20.0, 1e-9)
live.switches.agronomy = false
T.near("in-flight value NEUTRALIZED when switched OFF", R.resolve(mult, live), 1.0, 1e-9)

-- ── neutralOf: default multiplier vs declared addend ─────────
T.near("neutralOf default", R.neutralOf({ id = "x", dial = "economy" }), 1.0, 1e-9)
T.near("neutralOf declared addend", R.neutralOf(addend), 0.0, 1e-9)

-- ── isDialOn ─────────────────────────────────────────────────
T.eq("isDialOn nil profile",   R.isDialOn(nil, "economy"), false)
T.eq("isDialOn switch false",  R.isDialOn(profile({}, { economy = false }), "economy"), false)
T.eq("isDialOn switch unset",  R.isDialOn(profile({}, {}), "economy"), true)
T.eq("isDialOn switch true",   R.isDialOn(profile({}, { economy = true }), "economy"), true)

-- ── readProfile: absence detection + defaults ────────────────
local function hub(vals)
    return { getValue = function(_self, modId, key)
        if modId ~= R.MODULE then return nil end
        return vals[key]
    end }
end

T.eq("readProfile nil hub -> nil", R.readProfile(nil), nil)
T.eq("readProfile absent spine (nil preset) -> nil", R.readProfile(hub({})), nil)

do
    local p = R.readProfile(hub({
        [R.PRESET_KEY]        = "standard",
        [R.dialKey("economy")]  = 1.5,
        [R.switchKey("economy")] = false,
        -- agronomy left unset: intensity defaults neutral, switch defaults on
    }))
    T.ok("readProfile present -> table", p ~= nil)
    T.eq("readProfile preset", p.preset, "standard")
    T.near("readProfile set dial", p.dials.economy, 1.5, 1e-9)
    T.eq("readProfile set switch off", p.switches.economy, false)
    T.near("readProfile unset dial -> neutral", p.dials.agronomy, R.INTENSITY_NEUTRAL, 1e-9)
    T.eq("readProfile unset switch -> on", p.switches.agronomy, true)
end

-- ── the tuning-tool difficulty gate ──────────────────────────
T.eq("gate nil profile -> allowed",   R.isToolAllowed(nil), true)
T.eq("gate relaxed -> allowed",       R.isToolAllowed(profile({}, {}, "relaxed")), true)
T.eq("gate standard -> blocked",      R.isToolAllowed(profile({}, {}, "standard")), false)
T.eq("gate realistic -> blocked",     R.isToolAllowed(profile({}, {}, "realistic")), false)
T.eq("gate punishing -> blocked",     R.isToolAllowed(profile({}, {}, "punishing")), false)
T.eq("gate custom -> blocked",        R.isToolAllowed(profile({}, {}, "custom")), false)

-- ── transitive cascade: a chain of readers all neutralize together ──
-- disease -> dog -> tablet all ride Biological; flip Biological off and every hop
-- returns neutral with no special-casing, the brief's cascade property.
local disease = { id = "d", dial = "biological", base = 3.0, curve = curve }
local dog     = { id = "g", dial = "biological", base = 7.0, curve = curve }
local tablet  = { id = "t", dial = "biological", base = 2.0, curve = curve }
local bioOn  = profile({ biological = 1.0 }, { biological = true })
local bioOff = profile({ biological = 1.0 }, { biological = false })
T.near("cascade disease ON", R.resolve(disease, bioOn), 3.0, 1e-9)
T.near("cascade dog ON",     R.resolve(dog, bioOn), 7.0, 1e-9)
T.near("cascade tablet ON",  R.resolve(tablet, bioOn), 2.0, 1e-9)
T.near("cascade disease neutral when Biological OFF", R.resolve(disease, bioOff), 1.0, 1e-9)
T.near("cascade dog neutral when Biological OFF",     R.resolve(dog, bioOff), 1.0, 1e-9)
T.near("cascade tablet neutral when Biological OFF",  R.resolve(tablet, bioOff), 1.0, 1e-9)

-- ── canonical dial curves (ratio pass v0.2) ──────────────────
-- Every dial has a curve, neutral (at1) is exactly 1.0, and a declaration with
-- no curve of its own resolves through the dial's canonical curve.
do
  local allDials = { "economy", "labor", "agronomy", "biological", "livestock", "worldEvents", "community" }
  local allHaveCurves, allNeutralAt1 = true, true
  for _, d in ipairs(allDials) do
    local c = R.dialCurve(d)
    if type(c) ~= "table" then allHaveCurves = false
    elseif math.abs(c.at1 - 1.0) > 1e-9 then allNeutralAt1 = false end
  end
  T.ok("all seven dials have a canonical curve", allHaveCurves)
  T.ok("every dial is identity (1.0) at Standard", allNeutralAt1)
end

-- Economy 0.4 / 1.0 / 1.8 applied through the canonical curve (no decl curve).
local econ = { id = "e", dial = "economy", base = 100.0 }
T.near("economy canonical at Relaxed (dial 0)",  R.resolve(econ, profile({ economy = 0.0 }, { economy = true })), 40.0,  1e-6)
T.near("economy canonical at Standard (dial 1)", R.resolve(econ, profile({ economy = 1.0 }, { economy = true })), 100.0, 1e-6)
T.near("economy canonical at Punishing (dial 2)",R.resolve(econ, profile({ economy = 2.0 }, { economy = true })), 180.0, 1e-6)

-- Community is the tightest dial (0.8 / 1.0 / 1.3).
local comm = { id = "c2", dial = "community", base = 100.0 }
T.near("community canonical at Punishing = 130", R.resolve(comm, profile({ community = 2.0 }, { community = true })), 130.0, 1e-6)

-- A decl with its OWN curve overrides the canonical one.
local ownCurve = { id = "o", dial = "economy", base = 100.0, curve = { at0 = 1.0, at1 = 1.0, at2 = 1.0 } }
T.near("declared curve overrides canonical", R.resolve(ownCurve, profile({ economy = 2.0 }, { economy = true })), 100.0, 1e-6)

-- ── ratio pass BACKLOG-20: authoritative preset set + per-dial numbers ──
-- Locks the authoritative values from ecosystem-dev-tracking/systems/
-- ratio-pass-BACKLOG-20/README.md, so a drift from the blessed set fails a line.

-- The four named presets map to their canonical intensities on the 0..2 axis.
T.near("preset relaxed -> intensity 0",     R.intensityForPreset("relaxed"),   0.0, 1e-9)
T.near("preset standard -> intensity 1.0",  R.intensityForPreset("standard"),  1.0, 1e-9)
T.near("preset realistic -> intensity 1.5", R.intensityForPreset("realistic"), 1.5, 1e-9)
T.near("preset punishing -> intensity 2.0", R.intensityForPreset("punishing"), 2.0, 1e-9)
T.eq("preset custom has no single intensity", R.intensityForPreset("custom"), nil)
T.eq("preset unknown -> nil", R.intensityForPreset("nope"), nil)

-- The enum carries exactly the five authoritative values, in bite order + custom.
do
  local want = { "relaxed", "standard", "realistic", "punishing", "custom" }
  local ok = #R.PRESETS == #want
  for i = 1, #want do if R.PRESETS[i] ~= want[i] then ok = false end end
  T.ok("PRESETS is the authoritative five in order", ok)
end

-- Per-dial authoritative endpoints (multiplier at intensity 0 / 1.0 / 2.0),
-- resolved through each dial's canonical curve (base 1.0, no decl curve).
local function endp(dial, intensity)
    return R.resolve({ id = dial, dial = dial, base = 1.0 },
                     profile({ [dial] = intensity }, { [dial] = true }))
end
local ANCHORS = {
    economy     = { 0.4, 1.8 },
    labor       = { 0.6, 1.5 },
    agronomy    = { 0.7, 1.4 },
    biological  = { 0.5, 1.6 },
    livestock   = { 0.5, 1.6 },
    worldEvents = { 0.4, 1.7 },
    community   = { 0.8, 1.3 },
}
for _, dial in ipairs(R.DIALS) do
    local a = ANCHORS[dial]
    T.near(dial .. " at0 (Relaxed, intensity 0)",   endp(dial, 0.0), a[1], 1e-6)
    T.near(dial .. " identity (Standard, 1.0)",     endp(dial, 1.0), 1.0,  1e-6)
    T.near(dial .. " at2 (Punishing, intensity 2)", endp(dial, 2.0), a[2], 1e-6)
end

-- Realistic = intensity 1.5 interpolates three-quarters from Standard to
-- Punishing on every dial: multiplier = 1.0 + (at2 - 1.0) * 0.5.
for _, dial in ipairs(R.DIALS) do
    local want = 1.0 + (ANCHORS[dial][2] - 1.0) * 0.5
    T.near(dial .. " at Realistic (1.5)", endp(dial, 1.5), want, 1e-6)
end

-- The Economy C5 escape-hatch second curve (0.2 / 1.0 / 2.75), read off the SAME
-- economy intensity via a per-declaration curve override.
local hatch = { id = "hatch", dial = "economy", base = 1.0, curve = R.ECONOMY_HATCH_CURVE }
T.near("C5 hatch at Relaxed (intensity 0)",   R.resolve(hatch, profile({ economy = 0.0 }, { economy = true })), 0.2,  1e-6)
T.near("C5 hatch at Standard (intensity 1)",  R.resolve(hatch, profile({ economy = 1.0 }, { economy = true })), 1.0,  1e-6)
T.near("C5 hatch at Punishing (intensity 2)", R.resolve(hatch, profile({ economy = 2.0 }, { economy = true })), 2.75, 1e-6)
-- Off ONE economy intensity, the hatch stings more than everyday economy at
-- Punishing (2.75x vs 1.8x) and is never free even on Relaxed.
T.ok("C5 hatch stings more than everyday economy at Punishing",
     R.resolve(hatch, profile({ economy = 2.0 }, { economy = true })) > endp("economy", 2.0))
T.ok("C5 hatch not free on Relaxed",
     R.resolve(hatch, profile({ economy = 0.0 }, { economy = true })) > 0)
