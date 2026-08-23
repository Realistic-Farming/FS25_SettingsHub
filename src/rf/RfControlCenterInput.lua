-- =========================================================
-- FS25_SettingsHub - RfControlCenterInput
-- =========================================================
-- Registers the master summon action in both the on-foot and in-vehicle input
-- contexts, so the Control Center answers the same key wherever the player is.
--
-- Shape copied from FS25_MasterHUD/main.lua, which is the pattern proven live
-- across Soil, FuelCosts and RWE. The two halves are not symmetrical for a
-- reason:
--
--   ON FOOT  wrap PlayerInputComponent.registerActionEvents at MODULE LOAD.
--            It has to be wrapped before the first registerActionEvents fires,
--            not after.
--
--   VEHICLE  hook InputBinding.endActionEventsModification instead. Vehicle
--            spec functions are copied onto each instance at spawn, so patching
--            the class afterwards is silently ignored.
--
-- Both paths re-register on every rebuild with no teardown and no stale-id
-- early return. A context is destroyed and rebuilt on spawn and on every
-- vehicle entry, which kills saved event ids while leaving them non-nil, and
-- guarding on non-nil is exactly how keys go dead in the cab. Re-registering
-- into a context that already holds the action fails silently by design, so
-- attempting every time is the safe shape.
--
-- Callbacks ignore a zero inputValue, which is key-up.
-- =========================================================

RfControlCenterInput = RfControlCenterInput or {}

local ACTION = "RF_OPEN_CONTROL_CENTER"

local playerEventId  = nil
local vehicleEventId = nil

local function onSummon(_, _, inputValue)
    if (inputValue or 0) <= 0 then return end
    RfKeybindActionDialog.show()
end

local function registerInPlayerContext()
    if g_inputBinding == nil then return end
    if InputAction == nil or InputAction[ACTION] == nil then
        SHLogger.warning("InputAction %s missing - check modDesc <actions>", ACTION)
        return
    end

    g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

    local ok, eventId = g_inputBinding:registerActionEvent(
        InputAction[ACTION], RfControlCenterInput, onSummon,
        false, true, false, true
    )
    if ok and eventId ~= nil then
        playerEventId = eventId
        g_inputBinding:setActionEventActive(eventId, true)
        -- The input-help legend is the one surface that always shows the LIVE
        -- binding, the same source Controls reads, so the row is left visible
        -- rather than hidden behind a default that may not exist.
        g_inputBinding:setActionEventTextVisibility(eventId, true)
    end

    g_inputBinding:endActionEventsModification()
end

local function registerInVehicleContext(binding)
    if binding == nil or InputAction == nil or InputAction[ACTION] == nil then return end

    binding:beginActionEventsModification(Vehicle.INPUT_CONTEXT_NAME)

    local ok, eventId = binding:registerActionEvent(
        InputAction[ACTION], RfControlCenterInput, onSummon,
        false, true, false, true
    )
    if ok and eventId ~= nil then
        vehicleEventId = eventId
        binding:setActionEventTextVisibility(eventId, true)
        SHLogger.info("%s registered in VEHICLE context", ACTION)
    end

    binding:endActionEventsModification()
end

--- Installs both hooks. Idempotent: a second call is a no-op, so a hot reload
--- cannot stack a second wrapper on top of the first.
function RfControlCenterInput.install()
    if RfControlCenterInput._installed then return end
    RfControlCenterInput._installed = true

    if PlayerInputComponent ~= nil and PlayerInputComponent.registerActionEvents ~= nil then
        local origFn = PlayerInputComponent.registerActionEvents
        PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
            origFn(inputComponent, ...)
            local isOwner = inputComponent.player ~= nil and inputComponent.player.isOwner
            if isOwner then
                registerInPlayerContext()
            end
        end
        SHLogger.info("PlayerInputComponent hook installed (Control Center)")
    else
        SHLogger.warning("PlayerInputComponent.registerActionEvents unavailable - on-foot Control Center key disabled")
    end

    if InputBinding ~= nil and InputBinding.endActionEventsModification ~= nil then
        local hookActive = false
        local origEnd = InputBinding.endActionEventsModification
        InputBinding.endActionEventsModification = function(binding, ignoreCheck)
            local contextName = ""
            if binding.registrationContext ~= nil
                and binding.registrationContext ~= InputBinding.NO_REGISTRATION_CONTEXT then
                contextName = binding.registrationContext.name or ""
            end

            origEnd(binding, ignoreCheck)

            if Vehicle == nil or contextName ~= Vehicle.INPUT_CONTEXT_NAME then return end
            if hookActive then return end
            hookActive = true
            registerInVehicleContext(binding)
            hookActive = false
        end
        SHLogger.info("InputBinding VEHICLE hook installed (Control Center)")
    else
        SHLogger.warning("InputBinding.endActionEventsModification unavailable - in-vehicle Control Center key disabled")
    end
end
