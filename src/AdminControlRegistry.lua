-- =========================================================
-- FS25_SettingsHub - Admin Control Registry (API-8)
-- =========================================================
-- Author: TisonK
-- Governance: cross-suite AUTHORITY #9 (Arissani design, ratified 2026-07-18)
-- Brief: ecosystem-dev-tracking/systems/admin-control-registry/ v2.0
-- =========================================================
-- One place a mod DECLARES an administrative control as data, so who may use
-- it, whether this world offers it at all, and whether the requester owns the
-- thing being acted on are answered ONCE by shared machinery instead of being
-- re-answered (and sometimes answered wrong) by every mod.
--
-- The registry owns the registration table and the permission VERDICT. It owns
-- no mod's settings, no mod's state, and no money: it decides whether an
-- invocation is permitted and hands it back to the owning mod to perform.
--
-- It rides inside SettingsHub as an extension (not a sixth core service):
--   * DECLARATIONS ride SettingsHub:registerModule via an additive optional
--     `adminControls` spec field (the `selfPersisted` precedent).
--   * EXECUTION rides NetworkSync registerAction/requestAction. The action is
--     registered adminOnly=false BECAUSE the registry does its OWN two-gate
--     check per control; NetworkSync's blanket admin gate is the wrong shape.
--   * RENDERING rides MasterHUD (delegate-when-present); see getRenderModel().
--
-- Permission is TWO independent questions that COMPOSE (brief section 3):
--   Gate 1 (RIGHTS)      : is this an administrative act?
--   Gate 2 (MEMBERSHIP)  : does the requester belong to the target farm?
-- A control can be non-admin and still require ownership; a control can be
-- admin-only and be farm-agnostic. The server recomputes BOTH at receipt from
-- the requester's connection identity and is the ONLY authority. Any
-- client-side check is presentation only and is never trusted.
-- =========================================================

AdminControlRegistry = AdminControlRegistry or {}
local AdminControlRegistry_mt = Class(AdminControlRegistry)

-- Adopters check this handle before retiring their local rendering.
AdminControlRegistry.CAPABILITY_VERSION = 1

-- NetworkSync action id for a permitted-invocation request (client -> server).
AdminControlRegistry.ACTION_ID = "SettingsHub_AdminControlInvoke"

-- The creative-world flag lives as a SettingsHub adminOnly bool. SettingsHub
-- OWNS and is the single WRITER; the registry only READS it here and ships the
-- admin toggle that sets it (declared in _registerFlagModule below).
AdminControlRegistry.FLAG_MODULE = "AdminControlRegistry"
AdminControlRegistry.FLAG_KEY    = "creativeWorld"

local VALID_KINDS   = { administrative = true, creative = true, recovery = true, diagnostic = true }
local VALID_SCOPES  = { farm = true, global = true }
local VALID_WIDGETS = { action = true, toggle = true, preset = true }

-- Positional wire contract for the invoke action (RealisticFarmingActionEvent
-- serializes a typed VALUE ARRAY, not a keyed table, so order is the contract):
--   [1] modId        string
--   [2] controlId    string
--   [3] valueTag     string  "none" | "bool" | "num" | "str"
--   [4] value        bool|num|str  (always present; 0 when tag == "none")
--   [5] targetFarmId number  (0 == unspecified -> default to requester's own farm)
-- No nil holes: #args is stable at 5.

-- =========================================================
-- Construction
-- =========================================================

function AdminControlRegistry.new(settingsHub)
    local self = setmetatable({}, AdminControlRegistry_mt)
    self.settingsHub    = settingsHub      -- reads the creative flag; ships its toggle
    self.controls       = {}               -- modId -> { list = {def,...}, byId = { id -> def } }
    self.modOrder       = {}               -- registration order, for stable grouped rendering
    self.acks           = {}               -- modId -> last ack table
    self.actionBound    = false
    self.flagRegistered = false
    return self
end

-- Resolve an l10n key to text, cleanly, even before the 26-language pass lands.
local function ACR_text(key, fallback)
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

-- =========================================================
-- Declaration capture
-- =========================================================

-- Validate one control declaration. Returns nil if valid, else a reason string.
function AdminControlRegistry:_validateControl(c, bucket)
    if type(c) ~= "table" then return "not_a_table" end
    if type(c.id) ~= "string" or c.id == "" then return "missing_id" end
    if bucket.byId[c.id] ~= nil then return "duplicate_id" end
    if not VALID_KINDS[c.kind] then return "invalid_kind" end
    if not VALID_SCOPES[c.scope] then return "invalid_scope" end
    if type(c.label) ~= "string" or c.label == "" then return "missing_label" end

    local widget = c.widget or "action"
    if not VALID_WIDGETS[widget] then return "invalid_widget" end
    c.widget = widget

    -- A control must be able to DO something.
    local hasInvocation = type(c.invocation) == "function"
    local hasSetter = type(c.valueBinding) == "table" and type(c.valueBinding.setter) == "function"
    if not hasInvocation and not hasSetter then return "no_effect" end

    -- Diagnostic is read-only by contract: it may not carry a mutating setter.
    if c.kind == "diagnostic" and hasSetter then return "diagnostic_has_setter" end

    return nil
end

-- Called from SettingsHub:registerModule when spec.adminControls is present.
-- Returns an ACK the adopter must hold before retiring its local rendering:
--   { ok = bool, version = N, accepted = { id, ... }, rejected = { { id, reason }, ... } }
function AdminControlRegistry:register(modId, controls)
    local ack = { ok = false, version = AdminControlRegistry.CAPABILITY_VERSION, accepted = {}, rejected = {} }
    if type(modId) ~= "string" or modId == "" or type(controls) ~= "table" then
        return ack
    end

    local bucket = self.controls[modId]
    if bucket == nil then
        bucket = { list = {}, byId = {} }
        self.controls[modId] = bucket
        table.insert(self.modOrder, modId)
    end

    for _, c in ipairs(controls) do
        local reason = self:_validateControl(c, bucket)
        if reason == nil then
            bucket.byId[c.id] = c
            table.insert(bucket.list, c)
            table.insert(ack.accepted, c.id)
        else
            table.insert(ack.rejected, { id = (type(c) == "table" and c.id) or "?", reason = reason })
            SHLogger.warning("registry: '%s' control rejected (%s): %s",
                modId, reason, tostring(type(c) == "table" and c.id or c))
        end
    end

    ack.ok = #ack.accepted > 0
    self.acks[modId] = ack
    SHLogger.debug("registry: '%s' declared %d control(s), %d rejected",
        modId, #ack.accepted, #ack.rejected)
    return ack
end

function AdminControlRegistry:getAck(modId)
    return self.acks[modId]
end

function AdminControlRegistry:_getControl(modId, controlId)
    local bucket = self.controls[modId]
    if bucket == nil then return nil end
    return bucket.byId[controlId]
end

-- =========================================================
-- Creative-world flag (read) + its admin toggle (declared)
-- =========================================================

-- Fail-CLOSED on the flag: absence means NOT creative, so Creative controls stay
-- hidden. (This is distinct from the registry's own fail-OPEN presence: a mod
-- with no registry renders its own controls exactly as before.)
function AdminControlRegistry:isCreativeWorld()
    if self.settingsHub == nil then return false end
    return self.settingsHub:getValue(AdminControlRegistry.FLAG_MODULE, AdminControlRegistry.FLAG_KEY) == true
end

-- The registry ships the admin-facing toggle by DECLARING the flag as a
-- SettingsHub adminOnly setting. SettingsHub then owns its value, persists it
-- via StateLedger and syncs it via NetworkSync. Gate + a reachable toggle thus
-- ship in the SAME version (the brief's HARD REQUIREMENT).
function AdminControlRegistry:_registerFlagModule()
    if self.flagRegistered or self.settingsHub == nil then return end
    local label = ACR_text("acr_creativeWorld_label", "Creative World")
    local ok = self.settingsHub:registerModule(AdminControlRegistry.FLAG_MODULE, {
        adminSettings = {
            { id = AdminControlRegistry.FLAG_KEY, type = "bool", default = false,
              adminOnly = true, label = label },
        },
        onChange = function(_key, value, _playerId)
            -- Creative controls are evaluated at DRAW time, per draw, so there is
            -- nothing to recompute on a flip; just note it.
            SHLogger.debug("registry: creativeWorld -> %s", tostring(value))
        end,
        selfPersisted = false,
    })
    if ok then self.flagRegistered = true end
end

-- Convenience for the toggle UI (task: rendering). Routes through SettingsHub's
-- admin path, so a non-admin client's request is refused server-side.
function AdminControlRegistry:setCreativeWorld(value, playerId)
    if self.settingsHub == nil then return end
    self.settingsHub:setValue(AdminControlRegistry.FLAG_MODULE, AdminControlRegistry.FLAG_KEY, value == true, playerId)
end

-- =========================================================
-- The two-gate verdict (server authority)
-- =========================================================

-- userId == nil means the local host (listen-server / single-player host):
-- treated as holding admin rights, belonging to no specific farm, so a
-- farm-scoped act resolves through the admin override, never through membership
-- (a host does not belong to every farm). Brief section 4.
function AdminControlRegistry:_resolveRequester(userId)
    if userId == nil then
        return { isHost = true, isAdmin = true, farmId = nil }
    end

    local isAdmin = false
    local um = g_currentMission ~= nil and g_currentMission.userManager or nil
    if um ~= nil and um.getUserByUserId ~= nil then
        local user = um:getUserByUserId(userId)
        isAdmin = user ~= nil and user.getIsMasterUser ~= nil and user:getIsMasterUser() == true
    end

    local farmId = nil
    if g_farmManager ~= nil and g_farmManager.getFarmByUserId ~= nil then
        local farm = g_farmManager:getFarmByUserId(userId)
        if farm ~= nil and farm.farmId ~= nil and farm.farmId ~= FarmManager.SPECTATOR_FARM_ID then
            farmId = farm.farmId
        end
    end

    return { isHost = false, isAdmin = isAdmin, farmId = farmId }
end

-- Returns a decision table:
--   { permitted = bool, reason = string, targetFarmId = number|nil, isAdmin = bool }
-- opts.farmId, when given, is the caller-requested target farm for an
-- Administrative/Creative farm-scoped control (ignored for Recovery/Diagnostic,
-- which are BOUNDED to the requester's own farm).
function AdminControlRegistry:evaluate(control, userId, opts)
    opts = opts or {}
    local kind, scope = control.kind, control.scope
    if not VALID_KINDS[kind]   then return { permitted = false, reason = "unknown_kind" } end
    if not VALID_SCOPES[scope] then return { permitted = false, reason = "unknown_scope" } end

    local req = self:_resolveRequester(userId)

    -- Creative-flag gate (Creative only). Fail-closed.
    if kind == "creative" and not self:isCreativeWorld() then
        return { permitted = false, reason = "not_creative_world" }
    end

    -- Resolve the target farm for farm-scoped controls.
    local targetFarmId = nil
    if scope == "farm" then
        if kind == "recovery" or kind == "diagnostic" then
            -- BOUNDED: the requester's own farm only; a caller cannot target another.
            targetFarmId = req.farmId
            if targetFarmId == nil and not req.isHost then
                return { permitted = false, reason = "no_own_farm" }
            end
        else
            targetFarmId = opts.farmId or req.farmId
        end
    end

    -- Gate 1 (RIGHTS). Recovery and Diagnostic bypass it entirely.
    local needsAdmin = (kind == "administrative") or (kind == "creative" and scope == "global")
    if needsAdmin and not req.isAdmin then
        return { permitted = false, reason = "needs_admin" }
    end

    -- Gate 2 (MEMBERSHIP / scope). BOTH gates must pass.
    if scope == "global" then
        if not req.isAdmin then
            return { permitted = false, reason = "needs_admin" }
        end
    else -- farm
        if kind ~= "recovery" and kind ~= "diagnostic" then
            local isMember = req.farmId ~= nil and targetFarmId ~= nil and req.farmId == targetFarmId
            if not (isMember or req.isAdmin) then           -- the admin override
                return { permitted = false, reason = "not_member" }
            end
        end
        -- Recovery/Diagnostic are already bounded to the own farm above.
    end

    return { permitted = true, reason = "ok", targetFarmId = targetFarmId, isAdmin = req.isAdmin }
end

-- =========================================================
-- Invocation (client -> server, server-authoritative)
-- =========================================================

-- Register the single NetworkSync action. adminOnly=false is deliberate: the
-- registry performs its OWN two-gate check per control; NetworkSync's blanket
-- admin gate would refuse Creative-farm, Recovery and Diagnostic controls that
-- correctly need no admin rights.
function AdminControlRegistry:bindNetwork()
    if self.actionBound or g_networkSync == nil then return end
    local ok = g_networkSync:registerAction(AdminControlRegistry.ACTION_ID, {
        adminOnly = false,
        onAction  = function(userId, args) self:_applyInvoke(args, userId) end,
    })
    if ok then
        self.actionBound = true
        SHLogger.debug("registry: invoke action bound to NetworkSync")
    end
end

-- UI entry point. Routes to the server (or applies directly on a host).
function AdminControlRegistry:invoke(modId, controlId, value, targetFarmId)
    local valueTag, wireValue = "none", 0
    if type(value) == "boolean" then valueTag, wireValue = "bool", value
    elseif type(value) == "number" then valueTag, wireValue = "num", value
    elseif type(value) == "string" then valueTag, wireValue = "str", value end

    local args = { tostring(modId), tostring(controlId), valueTag, wireValue,
                   (type(targetFarmId) == "number" and targetFarmId) or 0 }

    if g_networkSync ~= nil then
        -- requestAction applies directly on a host (connection nil) and sends an
        -- event on a client. Server authority is enforced in _applyInvoke either way.
        g_networkSync:requestAction(AdminControlRegistry.ACTION_ID, args)
    elseif g_currentMission ~= nil and g_currentMission:getIsServer() then
        self:_applyInvoke(args, nil)   -- NetworkSync absent but we are the server
    end
end

-- Server receipt. Recomputes both gates and, if permitted, hands the act back to
-- the owning mod's own setter / invocation. The registry never writes mod state.
function AdminControlRegistry:_applyInvoke(args, userId)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    if type(args) ~= "table" then return end

    local modId, controlId = args[1], args[2]
    local valueTag, wireValue, targetFarmId = args[3], args[4], args[5]

    local control = self:_getControl(modId, controlId)
    if control == nil then
        SHLogger.warning("registry: invoke for unknown control '%s.%s'", tostring(modId), tostring(controlId))
        return
    end

    -- Decode the carried value.
    local value = nil
    if valueTag == "bool" then value = (wireValue == true) or (wireValue == 1)
    elseif valueTag == "num" then value = tonumber(wireValue)
    elseif valueTag == "str" then value = tostring(wireValue) end

    local reqTargetFarm = (type(targetFarmId) == "number" and targetFarmId > 0) and targetFarmId or nil

    local decision = self:evaluate(control, userId, { farmId = reqTargetFarm })
    if not decision.permitted then
        SHLogger.debug("registry: invoke denied '%s.%s' (%s)", modId, controlId, decision.reason)
        return
    end

    local ctx = {
        modId = modId, controlId = controlId, userId = userId,
        farmId = decision.targetFarmId, isAdmin = decision.isAdmin, value = value,
    }

    -- Perform through the mod's OWN declared setter (value-bound controls), then
    -- its invocation (actions). A control has one or both.
    if control.valueBinding ~= nil and type(control.valueBinding.setter) == "function" and value ~= nil then
        local ok, err = pcall(control.valueBinding.setter, value, ctx)
        if not ok then SHLogger.error("registry: setter '%s.%s' failed: %s", modId, controlId, tostring(err)) end
    end
    if type(control.invocation) == "function" then
        local ok, err = pcall(control.invocation, ctx)
        if not ok then SHLogger.error("registry: invocation '%s.%s' failed: %s", modId, controlId, tostring(err)) end
    end
end

-- =========================================================
-- Render model (data only; consumed by the MasterHUD panel)
-- =========================================================

-- Grouped per mod, registration order, functions stripped. Absent mods
-- contribute nothing. Creative controls are included; the renderer hides them
-- at DRAW time when isCreativeWorld() is false.
function AdminControlRegistry:getRenderModel()
    local out = {}
    for _, modId in ipairs(self.modOrder) do
        local bucket = self.controls[modId]
        local controls = {}
        for _, c in ipairs(bucket.list) do
            local vb = nil
            if type(c.valueBinding) == "table" then
                vb = { valueId = c.valueBinding.valueId, default = c.valueBinding.default,
                       min = c.valueBinding.min, max = c.valueBinding.max, step = c.valueBinding.step }
            end
            controls[#controls + 1] = {
                id = c.id, label = c.label, kind = c.kind, scope = c.scope,
                widget = c.widget, options = c.options, valueBinding = vb,
            }
        end
        out[#out + 1] = { modId = modId, controls = controls }
    end
    return out
end

-- =========================================================
-- Lifecycle + diagnostics
-- =========================================================

function AdminControlRegistry:onMissionLoaded()
    self:_registerFlagModule()   -- needs g_i18n + SettingsHub alive
    self:bindNetwork()           -- needs g_networkSync
end

function AdminControlRegistry:consoleCommandStatus()
    local lines = {}
    table.insert(lines, string.format("AdminControlRegistry v%d: creativeWorld=%s, action bound=%s",
        AdminControlRegistry.CAPABILITY_VERSION, tostring(self:isCreativeWorld()), tostring(self.actionBound)))
    for _, modId in ipairs(self.modOrder) do
        local bucket = self.controls[modId]
        table.insert(lines, string.format("  %s: %d control(s)", modId, #bucket.list))
        for _, c in ipairs(bucket.list) do
            table.insert(lines, string.format("    - %s [%s/%s/%s]", c.id, c.kind, c.scope, c.widget))
        end
    end
    return table.concat(lines, "\n")
end
