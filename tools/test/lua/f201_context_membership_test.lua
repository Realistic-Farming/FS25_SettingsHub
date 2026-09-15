--!load: src/rf/RfContextInput.lua, src/rf/RfControlCenterInput.lua
-- RSF-F201 effective design v1.4 (2026-09-14), ported from the certified bar and
-- re-pointed at production at build (F201 handoff, ACCEPTED LIMITATIONS last bullet).
-- GROUP A executes the real SettingsHub input helper against a MODELED binding
-- as post-build conformance: one registration per context, no retry on an
-- unchanged context, membership asked of the wrap's own context.
-- GROUPS B-E test the proposed narrow context-target/membership/forwarding shape.
-- GROUP E composes six REFERENCE participants with optional/failure cleanup.
-- GROUPS F-H cover R1 multi-action batching, mission-owner retirement and
-- per-mod update-interval attempt admission. These are unbuilt reference rules.
-- They do NOT prove the other five production wrappers, native key delivery,
-- real mission teardown ordering, frame time, saves or MP.
-- Fixture names, two contexts, dummy owners and payload numbers are synthetic
-- branch discriminators, not gameplay values or a production performance budget.
-- Model provenance: engine 1.21.1.0 InputEvent.lua:3-23,56-61 (complement),
-- official InputBinding.lua:4121-4129 context lists, PlayerInputComponent.lua:149-212.
-- The mangled decompiled registerActionEvent body is deliberately NOT copied.

local function pack(...) return { n = select('#', ...), ... } end
local function noop() end
local function eventId(action, target)
    -- Modeled triggerDown-only identity; real makeId omits the context.
    return action .. '|' .. tostring(target) .. '|1'
end

local function newBinding()
    local b = { contexts = {}, nameActions = {}, events = {}, attempts = 0,
                created = 0, begun = 0, ended = 0,
                mission = { isClient = true, localOwner = true, isExitingGame = false },
                NO_REGISTRATION_CONTEXT = { name = '' } }
    b.registrationContext = b.NO_REGISTRATION_CONTEXT
    function b:context(name)
        if not self.contexts[name] then self.contexts[name] = { name = name, actionEvents = {} } end
        return self.contexts[name]
    end
    function b:beginActionEventsModification(name)
        self.begun = self.begun + 1
        self.registrationContext = self:context(name)
    end
    function b:endActionEventsModification()
        self.ended = self.ended + 1
        self.registrationContext = self.NO_REGISTRATION_CONTEXT
    end
    function b:registerActionEvent(action, target, callback, up, down, always, startActive, callbackState)
        self.attempts = self.attempts + 1
        if self.throwAction == action then error('synthetic registration failure', 0) end
        if self.refuseAll or self.refuseAction == action then return false, nil end
        local ctx = self.registrationContext
        assert(ctx ~= self.NO_REGISTRATION_CONTEXT, 'model requires a registration context')
        self.nameActions[action] = self.nameActions[action] or { name = action }
        local key = self.nameActions[action]
        ctx.actionEvents[key] = ctx.actionEvents[key] or {}
        -- Minimal duplicate semantics for this probe only. Not a reconstruction
        -- of native collision resolution or its return tuple.
        if #ctx.actionEvents[key] > 0 then return false, nil end
        local event = { id = eventId(action, target), actionName = action,
                        targetObject = target, callback = callback,
                        triggerUp = up, triggerDown = down, triggerAlways = always,
                        isActive = startActive == true, callbackState = callbackState }
        ctx.actionEvents[key][1] = event
        self.events[event.id] = event
        self.created = self.created + 1
        return true, event.id
    end
    function b:setActionEventTextVisibility(id, visible)
        if self.events[id] then self.events[id].displayIsVisible = visible end
    end
    function b:setActionEventActive(id, active)
        if self.events[id] then self.events[id].isActive = active end
    end
    function b:removeActionEvent(id)
        local ctx = self.registrationContext
        for _, list in pairs(ctx.actionEvents) do
            for i = #list, 1, -1 do
                if list[i].id == id then
                    self.events[id] = nil
                    table.remove(list, i)
                end
            end
        end
    end
    function b:deleteContext(name)
        local ctx = self.contexts[name]
        if ctx then
            for _, list in pairs(ctx.actionEvents) do
                for _, event in ipairs(list) do self.events[event.id] = nil end
            end
        end
        self.contexts[name] = nil
    end
    return b
end

-- GROUP A: production conformance for the SettingsHub participant. The real
-- RfControlCenterInput + RfContextInput run against the MODELED binding. This
-- group was the source-transition alarm before the build; it now witnesses the
-- repaired shape and must stay green.
do
    local b = newBinding()
    InputBinding, g_inputBinding = b, b
    Vehicle = { INPUT_CONTEXT_NAME = 'VEHICLE' }
    PlayerInputComponent = { INPUT_CONTEXT_NAME = 'PLAYER', registerActionEvents = noop }
    InputAction = { RF_OPEN_CONTROL_CENTER = 'RF_OPEN_CONTROL_CENTER' }
    SHLogger = { info = noop, warning = noop }
    local shown = 0
    RfKeybindActionDialog = { show = function() shown = shown + 1 end }
    g_localPlayer = { isOwner = true }
    RfControlCenterInput.install()
    RfControlCenterInput.activate(g_currentMission)

    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    local firstAttempts = b.attempts
    T.eq('A1 repaired helper registers the summon action once', firstAttempts, 1)
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('A2 repaired helper does not retry an unchanged context', b.attempts, firstAttempts)
    T.eq('A3 model holds one event', b.created, 1)
    local event = b.contexts.VEHICLE.actionEvents[b.nameActions.RF_OPEN_CONTROL_CENTER][1]
    T.ok('A3b the target is a private VEHICLE forwarder, not the module table',
        event.targetObject ~= RfControlCenterInput and event.targetObject.__f201Context == 'VEHICLE')
    T.eq('A3c the event id is stored on the owner', RfControlCenterInput.vehicleEventId, event.id)
    event.callback(event.targetObject, event.actionName, 0)
    T.eq('A4 real summon callback ignores key-up value', shown, 0)
    event.callback(event.targetObject, event.actionName, 1)
    T.eq('A5 real summon callback reaches its existing dialog', shown, 1)

    -- PLAYER half through the wrapped registerActionEvents.
    local ic = { player = { isOwner = true } }
    PlayerInputComponent.registerActionEvents(ic)
    T.eq('A6 player wrapper registers once', b.attempts, firstAttempts + 1)
    local pev = b.contexts.PLAYER.actionEvents[b.nameActions.RF_OPEN_CONTROL_CENTER][1]
    T.ok('A7 player and vehicle identities differ', pev.id ~= event.id)
    PlayerInputComponent.registerActionEvents(ic)
    T.eq('A8 player wrapper does not retry a complete set', b.attempts, firstAttempts + 1)
    PlayerInputComponent.registerActionEvents({ player = { isOwner = false } })
    T.eq('A8b a non-owning player callback registers nothing', b.attempts, firstAttempts + 1)

    -- A lost handle is recovered from the live list, not re-registered.
    RfControlCenterInput.playerEventId = nil
    RfControlCenterInput.resetAdmission()
    PlayerInputComponent.registerActionEvents(ic)
    T.eq('A9 lost id recovered without a registration', RfControlCenterInput.playerEventId, pev.id)
    T.eq('A9b and no attempt was spent', b.attempts, firstAttempts + 1)

    -- Cab rebuild: the VEHICLE context is deleted and recreated; PLAYER survives.
    b:deleteContext('VEHICLE')
    T.ok('A10 the PLAYER event survives the VEHICLE delete', b.events[pev.id] ~= nil)
    RfControlCenterInput.resetAdmission()
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('A11 the rebuilt cab gets one fresh registration', b.attempts, firstAttempts + 2)

    -- Admission: a refused registration is not retried inside one update interval.
    b:deleteContext('VEHICLE')
    b.refuseAll = true
    RfControlCenterInput.resetAdmission()
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('A11b one refused attempt per update interval', b.attempts, firstAttempts + 3)
    b.refuseAll = false
    RfControlCenterInput.resetAdmission()
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('A11c the next interval retries once and succeeds', b.attempts, firstAttempts + 4)

    -- Retire: old targets inert, the predecessor is NOT restored.
    local wrapped = InputBinding.endActionEventsModification
    local wrappedPlayer = PlayerInputComponent.registerActionEvents
    RfControlCenterInput.retire()
    T.eq('A12 retire does not restore the vehicle predecessor', InputBinding.endActionEventsModification, wrapped)
    T.eq('A12b retire does not restore the player predecessor', PlayerInputComponent.registerActionEvents, wrappedPlayer)
    shown = 0
    event.callback(event.targetObject, event.actionName, 1)
    T.eq('A13 a retired target forwards to nobody', shown, 0)
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('A14 a retired owner registers nothing', b.attempts, firstAttempts + 4)
    RfControlCenterInput.install()
    T.eq('A15 a second install stacks no wrapper', InputBinding.endActionEventsModification, wrapped)
end

local function locate(b, contextName, actionName, target, callback)
    -- Reference read shape, not a new API. Do not mutate the native store.
    local ctx, action = b.contexts[contextName], b.nameActions[actionName]
    local list = ctx and action and ctx.actionEvents[action] or nil
    for _, event in ipairs(list or {}) do
        if event.actionName == actionName and event.targetObject == target
            and event.callback == callback and event.triggerDown == true
            and event.triggerUp == false and event.triggerAlways == false then
            return event
        end
    end
    return nil
end

-- GROUP B: same logical action and same target can alias between contexts.
do
    local b, owner, callback = newBinding(), {}, noop
    b:beginActionEventsModification('PLAYER')
    local _, playerId = b:registerActionEvent('SYNTHETIC_ACTION', owner, callback, false, true, false)
    b:beginActionEventsModification('VEHICLE')
    local _, vehicleId = b:registerActionEvent('SYNTHETIC_ACTION', owner, callback, false, true, false)
    T.eq('B1 modeled native identity omits context', playerId, vehicleId)
    b:deleteContext('VEHICLE')
    T.ok('B2 player event remains in its own context', locate(b, 'PLAYER', 'SYNTHETIC_ACTION', owner, callback) ~= nil)
    T.eq('B3 global index alone would falsely report missing player event', b.events[playerId], nil)
    T.eq('B4 player membership does not imply vehicle membership', locate(b, 'VEHICLE', 'SYNTHETIC_ACTION', owner, callback), nil)
end

-- GROUP C: proposed distinct context targets, same original handler and owner.
do
    local b, owner = newBinding(), { calls = 0 }
    local function handler(realOwner, action, value, state, tail)
        realOwner.calls = realOwner.calls + 1
        realOwner.received = pack(action, value, state, tail)
        return 'receipt', nil, 7
    end
    local function forward(target, ...)
        if target.alive then return handler(target.owner, ...) end
    end
    local player = { owner = owner, alive = true }
    local vehicle = { owner = owner, alive = true }
    b:beginActionEventsModification('PLAYER')
    local _, pId = b:registerActionEvent('SYNTHETIC_ACTION', player, forward, false, true, false)
    b:beginActionEventsModification('VEHICLE')
    local _, vId = b:registerActionEvent('SYNTHETIC_ACTION', vehicle, forward, false, true, false)
    T.ok('C1 distinct targets make context IDs distinct in the model', pId ~= vId)
    local pEvent = locate(b, 'PLAYER', 'SYNTHETIC_ACTION', player, forward)
    local result = pack(pEvent.callback(pEvent.targetObject, 'SYNTHETIC_ACTION', 1, nil, 'tail'))
    T.eq('C2 forwarding reaches the real owner', owner.calls, 1)
    T.eq('C3 forwarding preserves argument count with interior nil', owner.received.n, 4)
    T.eq('C4 forwarding preserves trailing argument', owner.received[4], 'tail')
    T.eq('C5 forwarding preserves return count', result.n, 3)
    T.eq('C6 forwarding preserves interior nil result', result[2], nil)
    T.eq('C7 forwarding preserves trailing result', result[3], 7)
    b:deleteContext('VEHICLE')
    T.eq('C8 cab removal leaves the distinct player index intact', b.events[pId], pEvent)
    T.eq('C9 removed cab context cannot pass lookup', locate(b, 'VEHICLE', 'SYNTHETIC_ACTION', vehicle, forward), nil)
    b:context('VEHICLE')
    T.eq('C10 recreated empty context is not validated by a stale saved ID', locate(b, 'VEHICLE', 'SYNTHETIC_ACTION', vehicle, forward), nil)
    T.eq('C11 another callback is not an owned match', locate(b, 'PLAYER', 'SYNTHETIC_ACTION', player, noop), nil)
    player.alive = false
    pEvent.callback(pEvent.targetObject, 'SYNTHETIC_ACTION', 1)
    T.eq('C12 deactivated target cannot operate the retired owner', owner.calls, 1)
end

-- GROUP D: membership means correct context, not whether a physical key is bound.
do
    local b, target, callback = newBinding(), {}, noop
    b:beginActionEventsModification('PLAYER')
    b:registerActionEvent('UNBOUND_BUT_REGISTERED', target, callback, false, true, false)
    T.ok('D1 registered unbound action remains a valid event', locate(b, 'PLAYER', 'UNBOUND_BUT_REGISTERED', target, callback) ~= nil)
    T.eq('D2 missing context query creates no context', locate(b, 'GUI', 'UNBOUND_BUT_REGISTERED', target, callback), nil)
    T.eq('D3 read-only query did not manufacture the GUI context', b.contexts.GUI, nil)
    T.eq('D4 query does not register an event', b.attempts, 1)
end

-- GROUP E: REFERENCE composition, not the six production modules.
-- Six labels come from the F201 source cohort. Each gets one synthetic action
-- to isolate composition from the actual per-mod action inventory.
local function makeParticipant(label, mission)
    local p = { alive = true, guard = false, action = 'MODEL_' .. label,
                owner = { calls = 0 }, mission = mission, attempted = {},
                wanted = { PLAYER = true, VEHICLE = true } }
    p.actions = { p.action }
    p.targets = { PLAYER = { owner = p.owner, alive = true }, VEHICLE = { owner = p.owner, alive = true } }
    p.forward = function(target, ...)
        if p.alive and target.alive and target.owner == p.owner and target.owner ~= nil then
            target.owner.calls = target.owner.calls + 1
        end
    end
    return p
end

local function reconcile(p, b, name, ownerPlayer)
    if b.mission == nil then return end
    local ownsInput = b.mission.localOwner
    if name == 'PLAYER' and ownerPlayer ~= nil then ownsInput = ownerPlayer.isOwner == true end
    if not p.alive or not b.contexts[name] or p.mission ~= b.mission
        or not b.mission.isClient or not ownsInput or b.mission.isExitingGame then return end
    local ctx, work = b.contexts[name], {}
    p.attempted[ctx] = p.attempted[ctx] or {}
    local attempted = p.attempted[ctx]
    for _, action in ipairs(p.actions) do
        local existing = locate(b, name, action, p.targets[name], p.forward)
        local wanted = p.wanted[name] and not (p.actionWanted and p.actionWanted[action] == false)
        if not wanted then
            attempted[action] = nil
            if existing then work[#work + 1] = { remove = existing.id } end
        elseif not existing and not attempted[action] then
            work[#work + 1] = { add = action }
        end
    end
    if #work == 0 then return end
    b:beginActionEventsModification(name)
    local ok, err = pcall(function()
        for _, item in ipairs(work) do
            if item.remove then b:removeActionEvent(item.remove) end
            if item.add then
                attempted[item.add] = true
                b:registerActionEvent(item.add, p.targets[name], p.forward, false, true, false, true, p.callbackState)
            end
        end
    end)
    local closed, closeError = pcall(b.endActionEventsModification, b)
    if not ok then error(err, 0) end
    if not closed then error(closeError, 0) end
end

local function installReference(p, b)
    if p.installedOn == b then return end
    local previous = b.endActionEventsModification
    b.endActionEventsModification = function(binding, ...)
        if p.guard or not p.alive then return previous(binding, ...) end
        local args = pack(...)
        local contextName = binding.registrationContext.name
        p.guard = true
        local returned
        local ok, err = pcall(function()
            returned = pack(previous(binding, unpack(args, 1, args.n)))
            if contextName == 'VEHICLE' then reconcile(p, binding, contextName) end
        end)
        p.guard = false
        if not ok then error(err, 0) end
        return unpack(returned, 1, returned.n)
    end
    p.installedOn = b
    p.wrapper = b.endActionEventsModification
end

-- R1 fold reference only: one private attempt memo per mod update interval.
-- It does not schedule input work. Existing native/fallback doors still drive it.
local function nextUpdate(p) p.attempted = {} end
local function retire(p)
    p.alive = false
    for _, target in pairs(p.targets) do target.alive = false; target.owner = nil end
    p.owner, p.mission, p.attempted = nil, nil, {}
end
local function activate(p, owner, mission)
    p.owner, p.mission, p.alive, p.attempted = owner, mission, true, {}
    p.targets = { PLAYER = { owner = owner, alive = true }, VEHICLE = { owner = owner, alive = true } }
end

do
    local b, participants = newBinding(), {}
    for _, name in ipairs({ 'SOIL', 'MASTERHUD', 'SETTINGSHUB', 'FUEL', 'WORKER', 'RWE' }) do
        local p = makeParticipant(name, b.mission)
        participants[#participants + 1] = p
        b:context('PLAYER')
        reconcile(p, b, 'PLAYER')
        installReference(p, b)
    end
    local before = b.attempts
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('E1 reference cohort fills each missing vehicle action once', b.attempts - before, #participants)
    before = b.attempts
    local endedBefore = b.ended
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('E2 valid reference cohort adds no registration attempts', b.attempts, before)
    T.eq('E3 valid reference cohort preserves one native finalizer call', b.ended - endedBefore, 1)
    for _, p in ipairs(participants) do
        T.ok('E4 ' .. p.action .. ' has both separate context members',
            locate(b, 'PLAYER', p.action, p.targets.PLAYER, p.forward) ~= nil
            and locate(b, 'VEHICLE', p.action, p.targets.VEHICLE, p.forward) ~= nil)
    end

    local optional = participants[1]
    optional.wanted.VEHICLE = false
    before = b.attempts
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('E5 deliberately absent action is removed, not re-registered', b.attempts, before)
    T.eq('E6 optional handover removes only the owned cab event', locate(b, 'VEHICLE', optional.action, optional.targets.VEHICLE, optional.forward), nil)
    T.ok('E7 optional handover retains the distinct player event', locate(b, 'PLAYER', optional.action, optional.targets.PLAYER, optional.forward) ~= nil)
    optional.wanted.VEHICLE = true
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('E8 ending handover restores only the missing action', b.attempts - before, 1)

    b:deleteContext('VEHICLE')
    before = b.attempts
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('E9 real model context replacement restores the whole cohort', b.attempts - before, #participants)
    b:deleteContext('VEHICLE')
    b.throwAction = participants[2].action
    b:beginActionEventsModification('VEHICLE')
    local ok, err = pcall(b.endActionEventsModification, b)
    T.eq('E10 registration failure propagates', ok, false)
    T.eq('E11 original failure text survives the wrappers', err, 'synthetic registration failure')
    T.eq('E12 own opened transaction is finalized on modeled registration failure', b.registrationContext, b.NO_REGISTRATION_CONTEXT)
    for _, p in ipairs(participants) do T.eq('E13 ' .. p.action .. ' guard is released after failure', p.guard, false) end
    b.throwAction = nil
    for _, p in ipairs(participants) do nextUpdate(p) end
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    for _, p in ipairs(participants) do
        T.ok('E14 ' .. p.action .. ' can recover after failure', locate(b, 'VEHICLE', p.action, p.targets.VEHICLE, p.forward) ~= nil)
    end

    local retired = participants[3]
    local foreignCalls, previous = 0, b.endActionEventsModification
    local foreignWrapper = function(binding, ...) foreignCalls = foreignCalls + 1; return previous(binding, ...) end
    b.endActionEventsModification = foreignWrapper
    retire(retired)
    b.mission.isExitingGame = true
    T.eq('E15a retirement preserves the already-installed outer wrapper', b.endActionEventsModification, foreignWrapper)
    local foreignBefore = foreignCalls
    before = b.attempts
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('E15 retired participant is not re-admitted', b.attempts, before)
    T.eq('E16 unrelated outer wrapper remains callable', foreignCalls - foreignBefore, 1)
    b:deleteContext('PLAYER')
    b:deleteContext('VEHICLE')
    T.eq('E17 native mission context disposal removes retired cab event', locate(b, 'VEHICLE', retired.action, retired.targets.VEHICLE, retired.forward), nil)
end

-- GROUP F: R1 structural fold, multi-action batching and admission.
-- Three synthetic actions isolate batching; not a production action count.
-- startActive=true comes from existing source register tuples; callbackState is
-- synthetic. A false return is modeled refusal, not a native collision diagnosis.
do
    local b = newBinding()
    local p = makeParticipant('BATCH', b.mission)
    p.actions = { 'MODEL_BATCH_A', 'MODEL_BATCH_B', 'MODEL_BATCH_C' }
    p.callbackState = 'synthetic callback state'
    installReference(p, b)
    b:beginActionEventsModification('VEHICLE')
    b:endActionEventsModification()
    T.eq('F1 multi-action participant registers complete set', b.attempts, #p.actions)
    T.eq('F2 batch has one own begin beyond external begin', b.begun, 2)
    local event = locate(b, 'VEHICLE', p.actions[1], p.targets.VEHICLE, p.forward)
    T.eq('F3 original startActive survives batch', event.isActive, true)
    T.eq('F4 callback state survives batch', event.callbackState, p.callbackState)
    local attempts, begun = b.attempts, b.begun
    b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
    T.eq('F5 valid multi-action repeat adds no attempts', b.attempts, attempts)
    T.eq('F6 valid repeat adds only external begin', b.begun - begun, 1)

    b:deleteContext('VEHICLE')
    b.refuseAction = p.actions[2]
    b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
    attempts, begun = b.attempts, b.begun
    b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
    T.eq('F7 refusal is not retried in the same update interval', b.attempts, attempts)
    T.eq('F8 refused-only repeat opens no own batch', b.begun - begun, 1)
    T.eq('F9 refusal is not falsely counted as a valid event', locate(b, 'VEHICLE', p.actions[2], p.targets.VEHICLE, p.forward), nil)
    b.refuseAction = nil
    nextUpdate(p)
    T.eq('F10 update reset itself schedules no registration', b.attempts, attempts)
    b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
    T.eq('F11 later native door repairs only the refused member', b.attempts - attempts, 1)

    b:deleteContext('VEHICLE')
    b.throwAction = p.actions[2]
    b:beginActionEventsModification('VEHICLE')
    local ok = pcall(b.endActionEventsModification, b)
    T.eq('F12 multi-action failure propagates', ok, false)
    T.ok('F13 first successful member survives later failure', locate(b, 'VEHICLE', p.actions[1], p.targets.VEHICLE, p.forward) ~= nil)
    T.eq('F14 failure releases local guard', p.guard, false)
    T.eq('F15 failed batch attempts matching close', b.registrationContext, b.NO_REGISTRATION_CONTEXT)
    b.throwAction = nil; nextUpdate(p)
    attempts = b.attempts
    b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
    T.eq('F16 recovery adds only two missing members', b.attempts - attempts, #p.actions - 1)
end

-- GROUP G: same private wrapper, explicit new owner; old targets stay inert.
-- Native BaseMission clears contexts during mission delete (1.21.1.0 complement
-- BaseMission.lua:190); this models that act without invoking live gameplay.
do
    local b = newBinding()
    local p = makeParticipant('LIFETIME', b.mission)
    installReference(p, b)
    local wrapper = p.wrapper
    b:context('PLAYER'); reconcile(p, b, 'PLAYER')
    local oldOwner, oldTarget = p.owner, p.targets.PLAYER
    local oldEvent = locate(b, 'PLAYER', p.action, oldTarget, p.forward)
    local begun = b.begun
    retire(p)
    T.eq('G1 retirement opens no input transaction', b.begun, begun)
    T.eq('G2 wrapper retained through retirement', b.endActionEventsModification, wrapper)
    T.eq('G3 retirement releases old owner reference', oldTarget.owner, nil)
    b:deleteContext('PLAYER'); b:deleteContext('VEHICLE')
    b.mission = { isClient = true, localOwner = true, isExitingGame = false }
    b:context('PLAYER')
    reconcile(p, b, 'PLAYER')
    T.eq('G4 new mission alone does not reactivate old participant', locate(b, 'PLAYER', p.action, oldTarget, p.forward), nil)
    local newOwner = { calls = 0 }
    activate(p, newOwner, b.mission); installReference(p, b)
    T.eq('G5 explicit activation does not stack a wrapper', b.endActionEventsModification, wrapper)
    oldEvent.callback(oldTarget, p.action, 1)
    T.eq('G6 old callback cannot reach old owner', oldOwner.calls, 0)
    T.eq('G7 old callback cannot reach new owner', newOwner.calls, 0)
    b.mission.localOwner = false; reconcile(p, b, 'PLAYER')
    T.eq('G8 non-owning player gets no local event', locate(b, 'PLAYER', p.action, p.targets.PLAYER, p.forward), nil)
    b.mission.localOwner = true; b.mission.isClient = false; reconcile(p, b, 'PLAYER')
    T.eq('G9 dedicated/non-client gets no local event', locate(b, 'PLAYER', p.action, p.targets.PLAYER, p.forward), nil)
    b.mission.isClient = true; b.mission.isExitingGame = true; reconcile(p, b, 'PLAYER')
    T.eq('G10 exiting native mission admits no registration', locate(b, 'PLAYER', p.action, p.targets.PLAYER, p.forward), nil)
    b.mission.isExitingGame = false; reconcile(p, b, 'PLAYER')
    local newEvent = locate(b, 'PLAYER', p.action, p.targets.PLAYER, p.forward)
    T.ok('G11 explicit new owner can populate existing player context', newEvent ~= nil)
    newEvent.callback(newEvent.targetObject, p.action, 1)
    T.eq('G12 current callback reaches current owner', newOwner.calls, 1)
end

-- Full production cohort re-pointing, native failure cleanup and actual
-- in-game acceptance remain outside this reference composition proof.
-- GROUP H: six three-action reference participants, every native attempt
-- refused. This deliberately thin case exposes neighbour-induced retry growth.
do
    local b, participants = newBinding(), {}
    for i = 1, 6 do
        local p = makeParticipant('REFUSAL_' .. i, b.mission)
        p.actions = { p.action .. '_A', p.action .. '_B', p.action .. '_C' }
        participants[#participants + 1] = p
        installReference(p, b)
    end
    b.refuseAll = true
    b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
    local expected = #participants * #participants[1].actions
    T.eq('H1 all-refused cohort attempts each action only once', b.attempts, expected)
    local attempts, begun = b.attempts, b.begun
    b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
    T.eq('H2 neighbour and repeated closes cannot retry refused cohort', b.attempts, attempts)
    T.eq('H3 refused repeat adds only the external begin', b.begun - begun, 1)
    for _, p in ipairs(participants) do nextUpdate(p) end
    T.eq('H4 admission reset does not schedule work', b.attempts, attempts)
    b.refuseAll = false
    b:beginActionEventsModification('VEHICLE'); b:endActionEventsModification()
    T.eq('H5 later native door admits every newly available action once', b.attempts - attempts, expected)
    T.eq('H6 previously refused cohort now has the expected event count', b.created, expected)
end
-- GROUP I: native PLAYER callback carries its own authoritative owner before
-- global-player publication; post-load catch-up uses an existing context only.
-- Source: official Player.lua:388-430,572; complement PlayerSystem.lua:259-281;
-- WorkerCosts src/main.lua:87-99,101-113. Values are reference discriminators.
do
    local b = newBinding()
    local p = makeParticipant('PLAYER_RECOVERY', b.mission)
    b.mission.localOwner = false
    b:context('PLAYER')
    reconcile(p, b, 'PLAYER', { isOwner = true })
    T.ok('I1 native owner argument works before global owner is published', locate(b, 'PLAYER', p.action, p.targets.PLAYER, p.forward) ~= nil)
    b:deleteContext('PLAYER'); b:context('PLAYER'); nextUpdate(p)
    b.mission.localOwner = true
    reconcile(p, b, 'PLAYER', { isOwner = false })
    T.eq('I2 remote callback cannot borrow the local global owner', locate(b, 'PLAYER', p.action, p.targets.PLAYER, p.forward), nil)
    reconcile(p, b, 'PLAYER') -- models the existing post-load callback
    T.ok('I3 post-load catch-up fills the missed first PLAYER registration', locate(b, 'PLAYER', p.action, p.targets.PLAYER, p.forward) ~= nil)
    local attempts, begun = b.attempts, b.begun
    reconcile(p, b, 'PLAYER')
    T.eq('I4 repeated post-load check does not rebuild valid input', b.attempts, attempts)
    T.eq('I5 valid post-load check opens no transaction', b.begun, begun)
    b:deleteContext('PLAYER')
    reconcile(p, b, 'PLAYER')
    T.eq('I6 post-load catch-up never manufactures a missing context', b.contexts.PLAYER, nil)
end

-- GROUP J: TaxMod's PLAYER-only lifecycle companion. This is a structural
-- reference, not execution of Tax main.lua. The bad restore matches READ source
-- FS25_TaxMod/main.lua:869-906,1006-1008. No Tax cab actions or tax logic modeled.
do
    local counts = { native = 0, inner = 0, tax = 0, outer = 0 }
    local taxAlive = true
    local native = function() counts.native = counts.native + 1; return 'native', nil, 9 end
    local inner = function(...) local values = pack(native(...)); counts.inner = counts.inner + 1; return unpack(values, 1, values.n) end
    local tax = function(...) local values = pack(inner(...)); if taxAlive then counts.tax = counts.tax + 1 end; return unpack(values, 1, values.n) end
    local outer = function(...) local values = pack(tax(...)); counts.outer = counts.outer + 1; return unpack(values, 1, values.n) end
    local current = outer
    current()
    T.eq('J1 fixture contains a later wrapper outside Tax', counts.outer, 1)
    current = inner -- old Tax unload restores its pre-Tax captured predecessor
    current()
    T.eq('J2 bad captured restore drops the later wrapper', counts.outer, 1)
    current = outer
    taxAlive = false -- corrected Tax unload retires state, not the shared method
    local returned = pack(current())
    T.eq('J3 retired Tax leaves later wrapper reachable', counts.outer, 2)
    T.eq('J4 retired Tax does no own callback work', counts.tax, 1)
    T.eq('J5 retirement preserves native return arity', returned.n, 3)
    T.eq('J6 retirement preserves the nil return slot', returned[2], nil)
    taxAlive = true -- next owner activation reuses the installed wrapper
    current()
    T.eq('J7 next mission reuses one Tax layer', counts.tax, 2)
    T.eq('J8 next mission preserves the outer layer', counts.outer, 3)
    T.eq('J9 fixed lifecycle does not replace the shared method', current, outer)
end
-- GROUP K: reference Income restoration, same-owner reactivation and explicit
-- reset-before-recovery ordering. Source: IncomeManager.lua:68-140,308-339;
-- SoilFertilityManager.lua:1729,1793-1801. No Income money behavior is modeled.
do
    local calls = { native = 0, income = 0, later = 0 }
    local owner = { alive = true }
    local native = function() calls.native = calls.native + 1 end
    local income = function() native(); if owner.alive then calls.income = calls.income + 1 end end
    local later = function() income(); calls.later = calls.later + 1 end
    local current = later
    current = native -- current Income delete restores its captured predecessor
    current()
    T.eq('K1 Income captured restore drops later player layers', calls.later, 0)
    current = later; owner.alive = false; current()
    T.eq('K2 retained Income wrapper preserves later layer during retirement', calls.later, 1)
    T.eq('K3 retired Income wrapper performs no own work', calls.income, 0)
    owner.alive = true; current()
    T.eq('K4 new Income owner reuses the retained layer once', calls.income, 1)

    local b = newBinding()
    local p = makeParticipant('ORDER', b.mission)
    b:context('PLAYER'); b.refuseAction = p.action
    nextUpdate(p) -- first statement of the existing update interval
    reconcile(p, b, 'PLAYER') -- existing one-shot recovery later in that update
    local attempted = b.attempts
    reconcile(p, b, 'PLAYER')
    T.eq('K5 no second reset erases recovery admission in the same update', b.attempts, attempted)
    local sameOwner, oldTarget = p.owner, p.targets.PLAYER
    retire(p); b:deleteContext('PLAYER')
    b.mission = { isClient = true, localOwner = true, isExitingGame = false }
    activate(p, sameOwner, b.mission)
    T.eq('K6 surviving singleton can be rebound as the current owner', p.owner, sameOwner)
    T.ok('K7 surviving singleton still receives fresh context targets', p.targets.PLAYER ~= oldTarget)
    T.eq('K8 old target remains inert after same-owner activation', oldTarget.alive, false)
end

-- GROUP L: reference post-load catch-up after optional owner publication.
-- One settings action and one local HUD action isolate the expected-set change.
-- This neither models a new provider notification nor schedules frame retries.
do
    local b = newBinding()
    local p = makeParticipant('POST_LOAD', b.mission)
    p.actions = { 'MODEL_SETTINGS', 'MODEL_LOCAL_HUD' }
    b:context('PLAYER'); reconcile(p, b, 'PLAYER')
    local settingsEvent = locate(b, 'PLAYER', p.actions[1], p.targets.PLAYER, p.forward)
    local attempts = b.attempts
    p.actionWanted = { MODEL_LOCAL_HUD = false }
    reconcile(p, b, 'PLAYER') -- existing post-load door after provider publication
    T.eq('L1 post-load owner check removes only obsolete local HUD input', locate(b, 'PLAYER', p.actions[2], p.targets.PLAYER, p.forward), nil)
    T.eq('L2 post-load check keeps the original settings event', locate(b, 'PLAYER', p.actions[1], p.targets.PLAYER, p.forward), settingsEvent)
    T.eq('L3 owner publication causes no needless settings registration', b.attempts, attempts)
    local begun = b.begun
    reconcile(p, b, 'PLAYER')
    T.eq('L4 settled post-load repeat opens no batch', b.begun, begun)
end
T.summary()

-- =========================================================================
-- GROUP M: the broad-round fold. Each block witnesses one correction folded
-- into RSF-F201-EFFECTIVE-DESIGN v1.2 after the round-two returns. These are
-- reference models of the design's own rules. They do NOT prove native
-- InputBinding, key delivery, real reload ordering, frame time, saves or MP.
-- Homes, table shapes and reload semantics are modeled from clone source read
-- firsthand; the engine half stays reconstruction, as the document says.
-- =========================================================================

-- M1. The identifier-keyed setter set is six, not five. The sixth resolves
-- through the same table and fails the same way once the slot is nil, so a
-- repair bound to the five earlier symbols leaves one live failure in place.
do
    local b = newBinding()
    -- The model ships two setters; add the other four in the same shape the
    -- decompiled bodies use, each resolving its argument against self.events.
    function b:setActionEventText(id, text)
        if self.events[id] then self.events[id].text = text; return true end
        return false
    end
    function b:getActionEventsHasBinding(id)
        if self.events[id] then return self.events[id].hasBinding == true end
        return false
    end
    function b:setActionEventIcon(id, icon)
        if self.events[id] then self.events[id].icon = icon; return true end
        return false
    end
    function b:setActionEventTextPriority(id, priority)
        if self.events[id] then self.events[id].displayPriority = priority; return true end
        return false
    end

    b:beginActionEventsModification('PLAYER')
    local ok, id = b:registerActionEvent('SF_CAB_STRIP', 'ownerA', noop, false, true, false, true)
    b:endActionEventsModification()
    T.ok('F201 M1 the probe action registered', ok and id ~= nil)

    T.eq('F201 M1 text lands while the slot is live', b:setActionEventText(id, 'Cab strip'), true)
    T.eq('F201 M1 icon lands while the slot is live', b:setActionEventIcon(id, 'icon'), true)
    T.eq('F201 M1 priority lands while the slot is live', b:setActionEventTextPriority(id, 3), true)
    b:setActionEventTextVisibility(id, true)
    b:setActionEventActive(id, true)
    T.eq('F201 M1 visibility reached the event', b.events[id].displayIsVisible, true)
    T.eq('F201 M1 active reached the event', b.events[id].isActive, true)

    -- Now clear the slot the way a deleted context clears it.
    b.events[id] = nil

    T.eq('F201 M1 text silently fails on a nil slot', b:setActionEventText(id, 'x'), false)
    T.eq('F201 M1 icon silently fails on a nil slot', b:setActionEventIcon(id, 'y'), false)
    T.eq('F201 M1 hasBinding silently fails on a nil slot', b:getActionEventsHasBinding(id), false)
    T.eq('F201 M1 priority silently fails on a nil slot too, which is the sixth',
        b:setActionEventTextPriority(id, 9), false)
    b:setActionEventTextVisibility(id, false)
    b:setActionEventActive(id, false)
    T.eq('F201 M1 visibility had nothing to write to', b.events[id], nil)
end

-- M2. The RandomWorldEvents home, decided rather than left open. Three
-- candidate homes are modeled across one script reload. The reload is modeled
-- as re-running the file's declarations, which is what replaces a bare literal
-- and what a latch prevents.
do
    -- The settings table as the clone actually declares it: a bare literal
    -- carrying live defaults and lifecycle state (RandomWorldEvents.lua:43-102).
    local function loadBareSettings(env)
        env.Settings = {
            events = { enabled = true, frequency = 5 },
            hudScale = 1.0,
            isInitialized = false,
            tickHandlers = {},
        }
        return env.Settings
    end

    -- The same table declared with the reuse latch, which is the option the
    -- fold considered and refused.
    local function loadLatchedSettings(env)
        env.Settings = env.Settings or {
            events = { enabled = true, frequency = 5 },
            hudScale = 1.0,
            isInitialized = false,
            tickHandlers = {},
        }
        return env.Settings
    end

    -- The separate mod-private latched record table, which is the option the
    -- fold chose. It carries the hook record and nothing else.
    local function loadHookRecord(env)
        env.RWE_InputHookRecord = env.RWE_InputHookRecord or {}
        return env.RWE_InputHookRecord
    end

    -- Arm one: the record on the bare literal. It does not survive a reload,
    -- which is the hazard item 12 named.
    local envA = {}
    local settingsA = loadBareSettings(envA)
    settingsA.playerHookOriginal = 'predecessor'
    settingsA.installed = true
    loadBareSettings(envA)
    T.eq('F201 M2 a record on the bare literal is lost on reload', envA.Settings.playerHookOriginal, nil)
    T.eq('F201 M2 and its install latch is lost with it', envA.Settings.installed, nil)

    -- Arm two: latch the settings table. The record survives, and that is
    -- exactly why this arm looks attractive.
    local envB = {}
    local settingsB = loadLatchedSettings(envB)
    settingsB.playerHookOriginal = 'predecessor'
    settingsB.installed = true
    -- The farmer changes a setting and the mission runs.
    settingsB.events.frequency = 1
    settingsB.hudScale = 2.5
    settingsB.isInitialized = true
    settingsB.tickHandlers['economic'] = noop
    loadLatchedSettings(envB)
    T.eq('F201 M2 the latch does keep the hook record', envB.Settings.playerHookOriginal, 'predecessor')
    -- And here is the cost, which is why the fold refuses this arm.
    T.eq('F201 M2 but the latch also stops the defaults being re-established', envB.Settings.events.frequency, 1)
    T.eq('F201 M2 the HUD scale carries last session forward as the new default', envB.Settings.hudScale, 2.5)
    T.eq('F201 M2 isInitialized stays true into a mission that has not initialised', envB.Settings.isInitialized, true)
    T.ok('F201 M2 and stale tick handlers survive to be registered a second time',
        envB.Settings.tickHandlers['economic'] ~= nil)

    -- Arm three: the chosen home. The record survives and the defaults are
    -- re-established, because the two concerns are kept in separate tables.
    local envC = {}
    local settingsC = loadBareSettings(envC)
    local recordC = loadHookRecord(envC)
    recordC.playerHookOriginal = 'predecessor'
    recordC.installed = true
    settingsC.events.frequency = 1
    settingsC.hudScale = 2.5
    settingsC.isInitialized = true
    loadBareSettings(envC)
    loadHookRecord(envC)
    T.eq('F201 M2 the chosen home keeps the hook record across the reload',
        envC.RWE_InputHookRecord.playerHookOriginal, 'predecessor')
    T.eq('F201 M2 and keeps the install latch, so the wrap does not stack',
        envC.RWE_InputHookRecord.installed, true)
    T.eq('F201 M2 while the settings defaults are re-established as before',
        envC.Settings.events.frequency, 5)
    T.eq('F201 M2 the HUD scale is back to its declared default', envC.Settings.hudScale, 1.0)
    T.eq('F201 M2 and isInitialized is false again for the new mission', envC.Settings.isInitialized, false)
    T.ok('F201 M2 so the record location and the settings declaration stay independent',
        envC.RWE_InputHookRecord ~= envC.Settings)
end

-- M3. Vehicle entry does not always rebuild the context. Modeled from the two
-- guards in the reconstructed driving state: the stack replacement is skipped
-- when the outgoing context is already PLAYER, and the createNew call is
-- reached only from root, PLAYER or the animal-riding variant.
do
    local PLAYER, VEHICLE, ROOT, RIDING = 'PLAYER', 'VEHICLE', 'ROOT', 'PLAYER_RIDING'
    local function onStateEnteredDriving(b, oldContext)
        local createdNew = false
        if oldContext == ROOT or oldContext == PLAYER or oldContext == RIDING then
            -- setContext(VEHICLE, createNew = true, ...) deletes the old context first
            b:deleteContext(VEHICLE)
            b:context(VEHICLE)
            createdNew = true
        end
        return createdNew
    end

    local b = newBinding()
    -- One target object shared by a PLAYER and a VEHICLE registration, which is
    -- the aliasing this repair removes.
    b:beginActionEventsModification(PLAYER)
    local _, playerId = b:registerActionEvent('MH_TOGGLE', 'sharedOwner', noop, false, true, false, true)
    b:endActionEventsModification()
    b:beginActionEventsModification(VEHICLE)
    local _, vehicleId = b:registerActionEvent('MH_TOGGLE_CAB', 'sharedOwner', noop, false, true, false, true)
    b:endActionEventsModification()
    T.ok('F201 M3 both registrations hold live slots', b.events[playerId] ~= nil and b.events[vehicleId] ~= nil)

    T.eq('F201 M3 mounting from foot rebuilds the vehicle context', onStateEnteredDriving(b, PLAYER), true)
    T.eq('F201 M3 which clears the cab slot', b.events[vehicleId], nil)

    -- Re-register into the fresh context, then swap straight to another vehicle.
    b:beginActionEventsModification(VEHICLE)
    local _, vehicleId2 = b:registerActionEvent('MH_TOGGLE_CAB', 'sharedOwner', noop, false, true, false, true)
    b:endActionEventsModification()
    T.ok('F201 M3 the cab slot is live again', b.events[vehicleId2] ~= nil)

    T.eq('F201 M3 stepping vehicle to vehicle creates no new context', onStateEnteredDriving(b, VEHICLE), false)
    T.ok('F201 M3 so the previous cab registration is still sitting there', b.events[vehicleId2] ~= nil)
    T.ok('F201 M3 which is why a repair must not assume a rebuild cleaned up between two vehicles',
        b.contexts[VEHICLE] ~= nil)

    T.eq('F201 M3 entering from the root context does rebuild', onStateEnteredDriving(b, ROOT), true)
    T.eq('F201 M3 and from the riding variant', onStateEnteredDriving(b, RIDING), true)
    T.eq('F201 M3 but never from an already-vehicle context', onStateEnteredDriving(b, VEHICLE), false)
end

-- M4. Membership asked of the live context, not of a stored identifier. A
-- frequent caller such as the activatable-objects system ends a modification
-- bracket on every nearest-object change, so a non-nil test reintroduces the
-- amplification this repair removes.
do
    local b = newBinding()
    b:beginActionEventsModification('VEHICLE')
    local _, id = b:registerActionEvent('SF_CAB_STRIP', 'vehicleOwner', noop, false, true, false, true)
    b:endActionEventsModification()

    local stored = id
    local function memberByStoredId() return stored ~= nil end
    local function memberByLiveContext()
        local ctx = b.contexts['VEHICLE']
        if ctx == nil then return false end
        for _, list in pairs(ctx.actionEvents) do
            for _, ev in ipairs(list) do if ev.id == stored then return true end end
        end
        return false
    end

    T.eq('F201 M4 both tests agree while the context is live', memberByStoredId(), memberByLiveContext())

    b:deleteContext('VEHICLE')
    T.eq('F201 M4 the stored identifier is still non-nil after the context is gone', memberByStoredId(), true)
    T.eq('F201 M4 the live-context test correctly says absent', memberByLiveContext(), false)
    T.ok('F201 M4 so the two disagree exactly when it matters', memberByStoredId() ~= memberByLiveContext())

    -- The frequency that makes the disagreement expensive.
    b:context('VEHICLE')
    b:beginActionEventsModification('VEHICLE')
    local _, liveId = b:registerActionEvent('SF_CAB_STRIP', 'vehicleOwner', noop, false, true, false, true)
    b:endActionEventsModification()
    stored = liveId
    local attemptsBefore, begunBefore = b.attempts, b.begun
    for _ = 1, 20 do
        -- a nearest-object change: begin and end with no delta to apply
        b:beginActionEventsModification('VEHICLE')
        if not memberByLiveContext() then
            b:registerActionEvent('SF_CAB_STRIP', 'vehicleOwner', noop, false, true, false, true)
        end
        b:endActionEventsModification()
    end
    T.eq('F201 M4 twenty nearest-object changes cost no registration attempts', b.attempts, attemptsBefore)
    T.eq('F201 M4 while the brackets really were opened twenty times', b.begun - begunBefore, 20)
    T.eq('F201 M4 and every one of them was closed', b.begun, b.ended)
end

-- M5. TaxMod needs no new home. A record already on a module table outlives the
-- per-mission instance, so the fold's correction is that its live defect is
-- stacking and restore rather than relocation.
do
    local moduleTable = {}
    local instance = { _playerInputHookOriginal = 'predecessorOnInstance' }
    moduleTable._inputHookOriginal = 'predecessorOnModule'

    -- mission teardown discards the instance
    T.eq('F201 M5 the instance held its own copy before teardown', instance._playerInputHookOriginal, 'predecessorOnInstance')
    instance = nil
    T.eq('F201 M5 the instance record is gone with the mission', instance, nil)
    T.eq('F201 M5 the module-table record survives it', moduleTable._inputHookOriginal, 'predecessorOnModule')

    -- but with no install latch the wrap stacks on a second load
    local installs = 0
    local function installNoLatch() installs = installs + 1 end
    installNoLatch(); installNoLatch()
    T.eq('F201 M5 without a latch two loads install twice', installs, 2)

    local installs2, latched = 0, {}
    local function installWithLatch()
        if latched.installed then return end
        latched.installed = true
        installs2 = installs2 + 1
    end
    installWithLatch(); installWithLatch()
    T.eq('F201 M5 with a latch two loads install once', installs2, 1)
    T.ok('F201 M5 so the fix is the latch and the restore, not a move', moduleTable._inputHookOriginal ~= nil)
end

-- =========================================================================
-- GROUP N: broad round three fold. Three claims from that round that are
-- actually testable. Reference models of the design's own rules; they do NOT
-- prove native InputBinding, key delivery or real state-machine ordering.
-- =========================================================================

-- N1. Identity carries the trigger code and no context term. Two registrations
-- that share action, target and trigger shape collide; changing only the
-- trigger shape separates them; changing only the context does not.
do
    local function triggerCode(up, down, always)
        local c = 0
        if down then c = c + 1 end
        if up then c = c + 2 end
        if always then c = c + 4 end
        return c
    end
    local function makeId(action, target, up, down, always)
        return string.format('%s|%s|%d', tostring(action), tostring(target), triggerCode(up, down, always))
    end

    T.eq('F201 N1 the trigger code sums the three flags, down alone is 1 (InputEvent.lua:60)', triggerCode(false, true, false), 1)
    T.eq('F201 N1 up and down together are distinct from down alone', triggerCode(true, true, false), 3)

    local playerSide = makeId('SF_CAB_STRIP', 'sharedOwner', false, true, false)
    local vehicleSide = makeId('SF_CAB_STRIP', 'sharedOwner', false, true, false)
    T.eq('F201 N1 same action, same target, same trigger shape is one identity', playerSide, vehicleSide)
    T.ok('F201 N1 and nothing in it says which context registered it', not string.find(playerSide, 'PLAYER', 1, true))
    T.ok('F201 N1 nor the other one', not string.find(playerSide, 'VEHICLE', 1, true))

    local differentTarget = makeId('SF_CAB_STRIP', 'vehicleOwner', false, true, false)
    T.ok('F201 N1 a per-context target separates them, which is the repair', playerSide ~= differentTarget)

    local differentShape = makeId('SF_CAB_STRIP', 'sharedOwner', true, true, false)
    T.ok('F201 N1 a different trigger shape also separates them', playerSide ~= differentShape)
    T.ok('F201 N1 so a membership test that ignores trigger shape can match the wrong event',
        makeId('SF_CAB_STRIP', 'sharedOwner', true, false, false) ~= playerSide)
end

-- N2. The two vehicle-entry guards are not the same. Driving admits the
-- animal-riding variant; the passenger equivalent does not.
do
    local ROOT, PLAYER, VEHICLE, RIDING = 'ROOT', 'PLAYER', 'VEHICLE', 'PLAYER_RIDING'
    local function drivingCreatesNew(oldContext)
        return oldContext == ROOT or oldContext == PLAYER or oldContext == RIDING
    end
    local function passengerCreatesNew(oldContext)
        return oldContext == ROOT or oldContext == PLAYER
    end

    T.eq('F201 N2 driving rebuilds from the root context', drivingCreatesNew(ROOT), true)
    T.eq('F201 N2 driving rebuilds from on foot', drivingCreatesNew(PLAYER), true)
    T.eq('F201 N2 driving rebuilds from animal riding', drivingCreatesNew(RIDING), true)
    T.eq('F201 N2 driving does not rebuild from another vehicle', drivingCreatesNew(VEHICLE), false)

    T.eq('F201 N2 the passenger seat rebuilds from the root context', passengerCreatesNew(ROOT), true)
    T.eq('F201 N2 and from on foot', passengerCreatesNew(PLAYER), true)
    T.eq('F201 N2 but NOT from animal riding, which driving does', passengerCreatesNew(RIDING), false)
    T.eq('F201 N2 and not from another vehicle either', passengerCreatesNew(VEHICLE), false)

    T.ok('F201 N2 so the two guards disagree on exactly one entry path',
        drivingCreatesNew(RIDING) ~= passengerCreatesNew(RIDING))
end

-- N3. Membership must be asked of the context the wrap belongs to, not of
-- whichever context happens to be live. A removal that runs with a different
-- context open leaves the VEHICLE list untouched while the live list is empty.
do
    local b = newBinding()
    b:beginActionEventsModification('VEHICLE')
    local _, vehId = b:registerActionEvent('MH_TOGGLE_CAB', 'vehicleOwner', noop, false, true, false, true)
    b:endActionEventsModification()
    b:beginActionEventsModification('PLAYER')
    local _, playerId = b:registerActionEvent('MH_TOGGLE', 'playerOwner', noop, false, true, false, true)
    b:endActionEventsModification()

    local function memberOf(contextName, id)
        local ctx = b.contexts[contextName]
        if ctx == nil then return false end
        for _, list in pairs(ctx.actionEvents) do
            for _, ev in ipairs(list) do if ev.id == id then return true end end
        end
        return false
    end

    T.eq('F201 N3 the cab event is in the VEHICLE list', memberOf('VEHICLE', vehId), true)
    T.eq('F201 N3 and not in the PLAYER list', memberOf('PLAYER', vehId), false)

    -- A removal that opens a different context and clears it, the shape the
    -- official update request produces when it removes with no VEHICLE begin.
    b:beginActionEventsModification('PLAYER')
    b:removeActionEvent(playerId)
    b:endActionEventsModification()

    T.eq('F201 N3 the PLAYER slot is gone', b.events[playerId], nil)
    T.eq('F201 N3 the cab event is untouched by a removal in another context', memberOf('VEHICLE', vehId), true)
    T.ok('F201 N3 so asking the live context would have answered for the wrong list',
        memberOf('PLAYER', vehId) == false and memberOf('VEHICLE', vehId) == true)
end


-- =========================================================================
-- GROUP O: the targeted fold-check. Two asserted contracts moved in that
-- fold and are witnessed here. Reference models of the design's own rules;
-- they do NOT prove native InputBinding or real state-machine ordering.
-- =========================================================================

-- O1. The vehicle-to-vehicle path skips the createNew call but still runs the
-- stack replacement. GROUP N modelled only the first half, and the design used
-- to claim neither guard fires, which the fold-check corrected.
do
    local ROOT, PLAYER, VEHICLE, RIDING = 'ROOT', 'PLAYER', 'VEHICLE', 'PLAYER_RIDING'
    local function replaceRuns(oldContext) return oldContext ~= PLAYER end
    local function createNewRuns(oldContext)
        return oldContext == ROOT or oldContext == PLAYER or oldContext == RIDING
    end

    T.eq('F201 O1 entering from on foot skips the replace', replaceRuns(PLAYER), false)
    T.eq('F201 O1 and does rebuild the context', createNewRuns(PLAYER), true)

    T.eq('F201 O1 vehicle to vehicle DOES run the stack replacement', replaceRuns(VEHICLE), true)
    T.eq('F201 O1 and does NOT rebuild the context', createNewRuns(VEHICLE), false)
    T.ok('F201 O1 so exactly one of the two guards fires on that path, not neither',
        replaceRuns(VEHICLE) ~= createNewRuns(VEHICLE))

    T.eq('F201 O1 from the root context both run', replaceRuns(ROOT) and createNewRuns(ROOT), true)
    T.eq('F201 O1 from animal riding both run', replaceRuns(RIDING) and createNewRuns(RIDING), true)
end

-- O2. TaxMod restores its captured predecessor on unload today, and the repair
-- removes that restore rather than adding one. A per-mission restore undoes the
-- session-lived wrapper, which is why item 7 forbids it.
do
    local engine = { registerActionEvents = 'nativeOriginal' }
    local taxModule = {}

    local function install()
        if taxModule._installed then return end
        taxModule._inputHookOriginal = engine.registerActionEvents
        engine.registerActionEvents = 'taxWrapper'
        taxModule._installed = true
    end

    -- today's unload, read from the clone
    local function unloadWithRestore()
        if taxModule._inputHookOriginal then
            engine.registerActionEvents = taxModule._inputHookOriginal
            taxModule._inputHookOriginal = nil
        end
    end

    install()
    T.eq('F201 O2 the wrapper is installed', engine.registerActionEvents, 'taxWrapper')
    T.eq('F201 O2 and the predecessor is held on the module table', taxModule._inputHookOriginal, 'nativeOriginal')

    unloadWithRestore()
    T.eq('F201 O2 today the mission teardown puts the native back', engine.registerActionEvents, 'nativeOriginal')
    T.eq('F201 O2 and drops the predecessor', taxModule._inputHookOriginal, nil)

    -- the next mission installs again, and the latch no longer protects anything
    -- because the record it keyed on was cleared by the restore.
    taxModule._installed = nil
    install()
    T.eq('F201 O2 so the next mission reinstalls the wrapper', engine.registerActionEvents, 'taxWrapper')
    T.ok('F201 O2 which is a per-mission install and teardown, not a session-lived wrapper',
        taxModule._inputHookOriginal == 'nativeOriginal')

    -- the repair: the session-lived wrapper stays installed across missions and
    -- the record survives, so a second load installs nothing.
    local engine2 = { registerActionEvents = 'nativeOriginal' }
    local taxModule2 = {}
    local installs = 0
    local function installOnce()
        if taxModule2._installed then return end
        taxModule2._inputHookOriginal = engine2.registerActionEvents
        engine2.registerActionEvents = 'taxWrapper'
        taxModule2._installed = true
        installs = installs + 1
    end
    installOnce()
    -- mission teardown with the restore REMOVED, as item 7 requires
    installOnce()
    T.eq('F201 O2 with the restore removed the wrapper installs once across two missions', installs, 1)
    T.eq('F201 O2 and stays installed through the teardown', engine2.registerActionEvents, 'taxWrapper')
    T.eq('F201 O2 with its predecessor still held', taxModule2._inputHookOriginal, 'nativeOriginal')
end
