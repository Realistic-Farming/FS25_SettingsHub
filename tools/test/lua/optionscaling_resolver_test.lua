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
T.eq("gate hard -> blocked",          R.isToolAllowed(profile({}, {}, "hard")), false)
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
