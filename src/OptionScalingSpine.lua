-- =========================================================
-- FS25_SettingsHub - Option-Scaling Spine (the profile module)
-- =========================================================
-- Author: TisonK
-- Governance: cross-suite AUTHORITY #1 (Arissani design, SDS v2.0 seven-dial,
--   co-signed 2026-07-18). Brief: ecosystem-dev-tracking/systems/option-scaling-spine/
-- =========================================================
-- THE SETTINGSHUB-SIDE HALF of the Option-Scaling Spine. Where the resolver
-- (OptionScalingResolver.lua) is the pure library every consumer vendors, this
-- module is the single WRITER: it registers the difficulty profile as one
-- ordinary SettingsHub admin module, so server authority, admin gating, MP
-- propagation and persistence all come from SettingsHub for free. It adds no new
-- core API (the brief's hard boundary): the profile is data inside SettingsHub,
-- the resolver is a bundled pure function, and nothing here is networked itself.
--
-- The profile it registers:
--   * seven dial FLOATS  (intensity 0..2, neutral 1.0), one per dial
--   * seven switch BOOLS (default on), one per dial
--   * one preset ENUM    (relaxed / standard / realistic / punishing / custom)
-- All adminOnly, so only the server (via an admin) can move them and every client
-- derives identical effective values from the one synced profile.
--
-- NUMBERS ARE NOT HERE. The intensity band, the per-preset dial configurations
-- and every curve endpoint are the ratio pass (BACKLOG-20). This module builds
-- the structure and defaults every dial to neutral, so a fresh world runs exactly
-- as it does today until the ratio pass tunes it.
-- =========================================================

OptionScalingSpine = {}
local OptionScalingSpine_mt = Class(OptionScalingSpine)

OptionScalingSpine.MODULE = OptionScalingResolver.MODULE

-- Human-readable dial names for the fallback labels (the 26-language pass fills
-- the l10n keys oss_dial_<id> / oss_switch_<id> / oss_preset_label later).
local DIAL_NAMES = {
    economy     = "Economy",
    labor       = "Labor",
    agronomy    = "Agronomy",
    biological  = "Biological (Crops)",
    livestock   = "Livestock",
    worldEvents = "World Events",
    community   = "Community",
}

function OptionScalingSpine.new(settingsHub)
    local self = setmetatable({}, OptionScalingSpine_mt)
    self.settingsHub = settingsHub
    self.registered  = false
    return self
end

-- Resolve an l10n key to text with a fallback, so labels are readable before the
-- 26-language pass lands (same helper shape as the Admin Control Registry).
local function OSS_text(key, fallback)
    if g_i18n ~= nil then
        if g_i18n.hasText ~= nil then
            if g_i18n:hasText(key) then return g_i18n:getText(key) end
            return fallback
        end
        local t = g_i18n:getText(key)
        if t ~= nil and t ~= "" and string.find(t, "missing", 1, true) == nil then return t end
    end
    return fallback
end

-- Build the adminSettings def list: seven dial floats, seven switch bools, one
-- preset enum. Every dial defaults to the neutral intensity, so the framework is
-- balance-neutral until the ratio pass sets curves.
function OptionScalingSpine:_buildDefs()
    local defs = {}
    for _, dial in ipairs(OptionScalingResolver.DIALS) do
        local name = DIAL_NAMES[dial] or dial
        defs[#defs + 1] = {
            id       = OptionScalingResolver.dialKey(dial),
            type     = "float",
            default  = OptionScalingResolver.INTENSITY_NEUTRAL,
            min      = OptionScalingResolver.INTENSITY_MIN,
            max      = OptionScalingResolver.INTENSITY_MAX,
            step     = 0.05,
            adminOnly = true,
            label    = OSS_text("oss_dial_" .. dial, name),
        }
        defs[#defs + 1] = {
            id       = OptionScalingResolver.switchKey(dial),
            type     = "bool",
            default  = true,
            adminOnly = true,
            label    = OSS_text("oss_switch_" .. dial, name .. " System"),
        }
    end

    defs[#defs + 1] = {
        id       = OptionScalingResolver.PRESET_KEY,
        type     = "enum",
        default  = OptionScalingResolver.DEFAULT_PRESET,
        values   = OptionScalingResolver.PRESETS,
        adminOnly = true,
        label    = OSS_text("oss_preset_label", "Difficulty Preset"),
    }
    return defs
end

-- Register the profile as a SettingsHub admin module. Deferred to onMissionLoaded
-- so g_i18n + SettingsHub are alive (matches the registry's flag-module timing).
function OptionScalingSpine:_registerProfileModule()
    if self.registered or self.settingsHub == nil then return end
    local ok = self.settingsHub:registerModule(OptionScalingSpine.MODULE, {
        adminSettings = self:_buildDefs(),
        onChange = function(key, value, _playerId)
            -- Resolvers read the profile live per resolve point, so there is
            -- nothing to recompute here; note the change for diagnostics. The
            -- ratio pass delivered the per-preset intensities
            -- (OptionScalingResolver.PRESET_INTENSITY); wiring the writer to push
            -- a chosen preset onto the seven dials belongs to a later follow-up,
            -- kept out of this numbers fold.
            SHLogger.debug("spine: %s -> %s", tostring(key), tostring(value))
        end,
        selfPersisted = false,   -- SettingsHub owns persistence + MP sync
    })
    if ok then
        self.registered = true
        SHLogger.info("Option-Scaling Spine registered (7 dials + 7 switches + preset)")
    end
end

-- Convenience read: the current profile, in the shape the resolver consumes.
-- Consumers vendor OptionScalingResolver and call readProfile themselves; this is
-- for SettingsHub-side callers (the console command, a future debug panel).
function OptionScalingSpine:getProfile()
    return OptionScalingResolver.readProfile(self.settingsHub)
end

function OptionScalingSpine:onMissionLoaded()
    self:_registerProfileModule()
end

function OptionScalingSpine:consoleCommandStatus()
    local profile = self:getProfile()
    if profile == nil then
        return "Option-Scaling Spine: profile not registered"
    end
    local lines = { string.format("Option-Scaling Spine: preset=%s", tostring(profile.preset)) }
    for _, dial in ipairs(OptionScalingResolver.DIALS) do
        lines[#lines + 1] = string.format("  %-12s intensity=%.2f  switch=%s",
            dial, profile.dials[dial] or -1, tostring(profile.switches[dial]))
    end
    return table.concat(lines, "\n")
end
