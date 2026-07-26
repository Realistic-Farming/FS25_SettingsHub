-- Truth-table test of AdminControlRegistry:evaluate() — the two-gate algebra.
-- The verdict is the security-critical core: a wrong answer here IS the
-- MarketDynamics/ProStaff defect class the whole registry exists to prevent.
--
--!load: src/AdminControlRegistry.lua

-- ── extra stubs the registry touches (beyond prelude) ─────────
SHLogger = { info=function() end, warning=function() end, error=function() end, debug=function() end }

FarmManager = { SPECTATOR_FARM_ID = 0 }

local usersById = {
  [10] = { getIsMasterUser = function() return true  end },  -- admin, farm 1
  [11] = { getIsMasterUser = function() return false end },  -- member, farm 1
  [12] = { getIsMasterUser = function() return false end },  -- member, farm 2
  [13] = { getIsMasterUser = function() return false end },  -- spectator, no farm
}
local farmsByUser = {
  [10] = { farmId = 1 },
  [11] = { farmId = 1 },
  [12] = { farmId = 2 },
  [13] = { farmId = 0 },   -- spectator -> resolves to nil in the registry
}

g_currentMission.getIsServer = function() return true end
g_currentMission.userManager = { getUserByUserId = function(_self, id) return usersById[id] end }
g_farmManager = { getFarmByUserId = function(_self, id) return farmsByUser[id] end }

local mockHub = {
  _creative = false,
  getValue = function(self, modId, key)
    if modId == AdminControlRegistry.FLAG_MODULE and key == AdminControlRegistry.FLAG_KEY then
      return self._creative
    end
    return nil
  end,
  registerModule = function() return true end,
  setValue = function() end,
}

local reg = AdminControlRegistry.new(mockHub)

local function ctl(kind, scope, extra)
  local c = { id = "c_"..kind.."_"..scope, kind = kind, scope = scope, label = "lbl",
              invocation = function() end }
  if extra then for k,v in pairs(extra) do c[k] = v end end
  return c
end

local admFarm  = ctl("administrative", "farm")
local admGlob  = ctl("administrative", "global")
local creaFarm = ctl("creative", "farm")
local creaGlob = ctl("creative", "global")
local recFarm  = ctl("recovery", "farm")
local diagFarm = ctl("diagnostic", "farm")   -- invocation only, no setter (read)

local function perm(control, userId, opts) return reg:evaluate(control, userId, opts).permitted end
local function reason(control, userId, opts) return reg:evaluate(control, userId, opts).reason end

-- ── Administrative + farm (brief: closes the MarketDynamics class) ──
T.eq("adm-farm member DENIED",         perm(admFarm, 11), false)
T.eq("adm-farm member reason",         reason(admFarm, 11), "needs_admin")
T.eq("adm-farm admin PERMITTED",       perm(admFarm, 10), true)
T.eq("adm-farm admin cross-farm override", perm(admFarm, 10, { farmId = 2 }), true)
T.eq("adm-farm host PERMITTED",        perm(admFarm, nil), true)

-- ── Administrative + global ──
T.eq("adm-global member DENIED",       perm(admGlob, 11), false)
T.eq("adm-global admin PERMITTED",     perm(admGlob, 10), true)
T.eq("adm-global host PERMITTED",      perm(admGlob, nil), true)

-- ── Creative gate, flag OFF (fail-closed) ──
mockHub._creative = false
T.eq("crea-farm flagOFF DENIED",       perm(creaFarm, 11), false)
T.eq("crea-farm flagOFF reason",       reason(creaFarm, 11), "not_creative_world")
T.eq("crea-global flagOFF DENIED",     perm(creaGlob, 10), false)

-- ── Creative gate, flag ON ──
mockHub._creative = true
T.eq("crea-farm ON member-own PERMITTED", perm(creaFarm, 11), true)
-- stranger (farm 2) charging farm 1 -> gate 2 refuses (closes the ProStaff class)
T.eq("crea-farm ON stranger DENIED",   perm(creaFarm, 12, { farmId = 1 }), false)
T.eq("crea-farm ON stranger reason",   reason(creaFarm, 12, { farmId = 1 }), "not_member")
T.eq("crea-global ON member DENIED",   perm(creaGlob, 11), false)
T.eq("crea-global ON admin PERMITTED", perm(creaGlob, 10), true)
T.eq("crea-farm ON host PERMITTED",    perm(creaFarm, nil), true)

-- ── Recovery: ungateable by rights + creative flag, BOUNDED to own farm ──
mockHub._creative = false
T.eq("recovery non-admin PERMITTED",   perm(recFarm, 11), true)
T.eq("recovery spectator DENIED",      perm(recFarm, 13), false)
T.eq("recovery spectator reason",      reason(recFarm, 13), "no_own_farm")
-- caller tries to target farm 2, but recovery is forced to the requester's OWN farm (1)
do
  local d = reg:evaluate(recFarm, 11, { farmId = 2 })
  T.eq("recovery bound permitted",     d.permitted, true)
  T.eq("recovery bound target = own",  d.targetFarmId, 1)
end
T.eq("recovery host PERMITTED",        perm(recFarm, nil), true)

-- ── Diagnostic: read-only, own-farm bounded ──
T.eq("diagnostic member PERMITTED",    perm(diagFarm, 11), true)
T.eq("diagnostic spectator DENIED",    perm(diagFarm, 13), false)

-- ── Declaration validation ──
do
  local ack = reg:register("FS25_Test", {
    { id = "ok1", kind = "administrative", scope = "farm", label = "l", invocation = function() end },
    { id = "bad_kind", kind = "wizard", scope = "farm", label = "l", invocation = function() end },
    { id = "ok1", kind = "administrative", scope = "farm", label = "l", invocation = function() end }, -- dup
    { id = "no_effect", kind = "administrative", scope = "farm", label = "l" },                        -- no fn
    { id = "diag_setter", kind = "diagnostic", scope = "farm", label = "l",
      valueBinding = { valueId = "v", setter = function() end } },                                     -- diag w/ setter
  })
  T.eq("register ok count", #ack.accepted, 1)
  T.eq("register rejected count", #ack.rejected, 4)
  T.eq("register ack ok", ack.ok, true)
  T.eq("register version", ack.version, 1)
end
