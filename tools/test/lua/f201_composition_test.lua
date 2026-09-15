--!load: src/rf/RfContextInput.lua
-- RSF-F201 composition: two participants built on the real helper (every mod carries a
-- byte-identical private copy under its own global name) stacked on one MODELED binding.
-- Witnesses: cascade termination and balanced brackets under nesting, no double close,
-- foreign events untouched on an ownership change, retire restores nothing, a throw
-- propagates with the close attempted and in-flight protection released.
-- The model is not the native InputBinding; it proves the composition rules only.
-- The helper binds owners to g_currentMission; give the model a client mission so the
-- test does not depend on which prelude ran first.
g_currentMission = { getIsClient = function() return true end, getIsServer = function() return true end }
local function noop() end
local b = { contexts = {}, nameActions = {}, events = {}, attempts = 0, created = 0, begun = 0, ended = 0,
            NO_REGISTRATION_CONTEXT = { name = '' }, engineEnds = 0 }
b.registrationContext = b.NO_REGISTRATION_CONTEXT
function b:context(name) if not self.contexts[name] then self.contexts[name] = { name = name, actionEvents = {} } end return self.contexts[name] end
function b:beginActionEventsModification(name) self.begun = self.begun + 1; self.registrationContext = self:context(name) end
function b:endActionEventsModification() self.ended = self.ended + 1; self.engineEnds = self.engineEnds + 1; self.registrationContext = self.NO_REGISTRATION_CONTEXT end
function b:registerActionEvent(action, target, callback, up, down, always, startActive, cbs)
    self.attempts = self.attempts + 1
    local ctx = self.registrationContext
    assert(ctx ~= self.NO_REGISTRATION_CONTEXT, 'model requires a registration context')
    self.nameActions[action] = self.nameActions[action] or { name = action }
    local key = self.nameActions[action]
    ctx.actionEvents[key] = ctx.actionEvents[key] or {}
    for _, e in ipairs(ctx.actionEvents[key]) do
        local code = (e.triggerDown and 1 or 0) + (e.triggerUp and 2 or 0) + (e.triggerAlways and 4 or 0)
        local ncode = (down and 1 or 0) + (up and 2 or 0) + (always and 4 or 0)
        if code == ncode then return false, nil end
    end
    local id = action .. '|' .. tostring(target) .. '|' .. tostring((down and 1 or 0) + (up and 2 or 0) + (always and 4 or 0))
    local ev = { id = id, actionName = action, targetObject = target, callback = callback, triggerUp = up, triggerDown = down, triggerAlways = always, isActive = startActive }
    table.insert(ctx.actionEvents[key], ev); self.events[id] = ev; self.created = self.created + 1
    return true, id
end
function b:setActionEventTextVisibility(id, v) end
function b:setActionEventActive(id, v) end
function b:removeActionEvent(id)
    for _, list in pairs(self.registrationContext.actionEvents) do
        for i = #list, 1, -1 do if list[i].id == id then self.events[id] = nil; table.remove(list, i) end end
    end
end
function b:deleteContext(name)
    local ctx = self.contexts[name]
    if ctx then for _, list in pairs(ctx.actionEvents) do for _, e in ipairs(list) do self.events[e.id] = nil end end end
    self.contexts[name] = nil
end
InputBinding, g_inputBinding = b, b
Vehicle = { INPUT_CONTEXT_NAME = 'VEHICLE' }
PlayerInputComponent = { INPUT_CONTEXT_NAME = 'PLAYER', registerActionEvents = function() end }
InputAction = { A_ONE = 'A_ONE', A_TWO = 'A_TWO', A_GONE = 'A_GONE' }
g_localPlayer = { isOwner = true }

local ownerA = { hits = 0, onA = function(self, _, v) self.hits = self.hits + (v or 0) end }
local ownerB = { hits = 0, onB = function(self, _, v) self.hits = self.hits + (v or 0) end, showTwo = true }
local HomeA, HomeB = {}, {}
local recA = RfContextInput.record(HomeA, 'r')
local recB = RfContextInput.record(HomeB, 'r')
local specA = { { action = 'A_ONE', handler = 'onA', idField = 'idOne' } }
local specB = { { action = 'A_TWO', handler = 'onB', idField = 'idTwo', present = function(o) return o.showTwo end } }
-- A installs first (inner), B second (outer)
RfContextInput.installPlayerWrapper(recA, specA); RfContextInput.installVehicleWrapper(recA, specA)
RfContextInput.installPlayerWrapper(recB, specB); RfContextInput.installVehicleWrapper(recB, specB)
RfContextInput.activate(recA, ownerA, g_currentMission, { PLAYER = specA, VEHICLE = specA })
RfContextInput.activate(recB, ownerB, g_currentMission, { PLAYER = specB, VEHICLE = specB })

-- engine opens and closes a VEHICLE window once
b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
T.eq('C1 both participants registered once each', b.attempts, 2)
T.eq('C2 two events exist', b.created, 2)
T.eq('C3 brackets are balanced', b.begun, b.ended)
local endsAfterFirst = b.engineEnds
b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
T.eq('C4 a second close costs no registration', b.attempts, 2)
T.eq('C5 and no extra bracket beyond the engine one', b.engineEnds, endsAfterFirst + 1)

-- PLAYER through the stacked wrappers
PlayerInputComponent.registerActionEvents({ player = { isOwner = true } })
T.eq('C6 both register in PLAYER once', b.attempts, 4)
PlayerInputComponent.registerActionEvents({ player = { isOwner = true } })
T.eq('C7 PLAYER complete set costs nothing', b.attempts, 4)

-- keypress reaches the right owner via the forwarding target
local evA = b.contexts.VEHICLE.actionEvents[b.nameActions.A_ONE][1]
evA.callback(evA.targetObject, evA.actionName, 1)
T.eq('C8 A_ONE reaches owner A', ownerA.hits, 1)
T.eq('C8b and not owner B', ownerB.hits, 0)

-- ownership change: B's action becomes obsolete, only B's event is removed
ownerB.showTwo = false
RfContextInput.resetAdmission(recB)
b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
T.eq('C9 obsolete owned event removed', b.contexts.VEHICLE.actionEvents[b.nameActions.A_TWO][1], nil)
T.ok('C9b foreign event untouched', b.contexts.VEHICLE.actionEvents[b.nameActions.A_ONE][1] ~= nil)
T.eq('C9c no registration spent on a removal', b.attempts, 4)

-- cab rebuild: only VEHICLE re-registers, PLAYER untouched
ownerB.showTwo = true
b:deleteContext('VEHICLE')
RfContextInput.resetAdmission(recA); RfContextInput.resetAdmission(recB)
b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
T.eq('C10 rebuilt cab registers both again', b.attempts, 6)
T.ok('C10b PLAYER events survived', b.contexts.PLAYER.actionEvents[b.nameActions.A_ONE][1] ~= nil)

-- retire A only: B still works, A's target inert, nothing unhooked
local top = InputBinding.endActionEventsModification
RfContextInput.retire(recA)
T.eq('C11 retire restores nothing', InputBinding.endActionEventsModification, top)
b:deleteContext('VEHICLE'); RfContextInput.resetAdmission(recB)
b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
T.eq('C12 only B registers after A retired', b.attempts, 7)
evA.callback(evA.targetObject, evA.actionName, 1)
T.eq('C13 retired A target forwards nothing', ownerA.hits, 1)

-- registration throw: close still attempted, protection released, error propagates
b.deleteContext(b, 'VEHICLE'); RfContextInput.resetAdmission(recB)
local realReg = b.registerActionEvent
b.registerActionEvent = function(...) error('synthetic', 0) end
local ok, err = pcall(function() b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification() end)
b.registerActionEvent = realReg
T.ok('C14 a registration throw propagates', not ok and tostring(err):find('synthetic') ~= nil)
T.eq('C14b brackets still balanced after the throw', b.begun, b.ended)
T.eq('C14c in-flight protection released', recB.inFlight, false)
RfContextInput.resetAdmission(recB)
b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
T.eq('C14d and the next interval registers normally', b.attempts, 8)
