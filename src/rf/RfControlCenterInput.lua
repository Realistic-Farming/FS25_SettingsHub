-- =========================================================
-- FS25_SettingsHub - RfControlCenterInput
-- =========================================================
-- Registers the master summon action in both the on-foot and in-vehicle input
-- contexts, so the Control Center answers the same key wherever the player is.
--
-- RSF-F201 (context-qualified input). The two halves are still not symmetrical:
--
--   ON FOOT  wrap PlayerInputComponent.registerActionEvents at MODULE LOAD.
--            It has to be wrapped before the first registerActionEvents fires,
--            not after.
--
--   VEHICLE  hook InputBinding.endActionEventsModification instead. Vehicle
--            spec functions are copied onto each instance at spawn, so patching
--            the class afterwards is silently ignored.
--
-- What changed under F201, and why:
--   * Each context registers through its own private forwarding target. The
--     engine keys an event by action, target and trigger shape only, so one
--     shared target made the PLAYER and VEHICLE registrations a single global
--     slot that vehicle entry wiped. Separate targets separate the slots.
--   * Membership is asked of the wrap's own context by walking the native
--     lists, never inferred from a non-nil stored id, and a complete set means
--     no registration transaction at all. The old shape retried the same valid
--     vehicle context on every close of that context.
--   * The captured predecessors are held on this module table for the whole
--     session and never restored per mission. Mission teardown only retires the
--     current owner and makes old targets inert.
--
-- Callbacks ignore a zero inputValue, which is key-up.
-- =========================================================

RfControlCenterInput = RfControlCenterInput or {}

local ACTION = "RF_OPEN_CONTROL_CENTER"

-- F201 item 12: the persistent hook record lives on this module table, which
-- already carried the install latch and survives mission teardown.
local record = RfContextInput.record(RfControlCenterInput, "_f201Input")

--- Summon handler. Resolved on the owner (this module) at call time by the
--- forwarding target, with the engine's argument sequence untouched.
function RfControlCenterInput.onSummon(_, _, inputValue)
    if (inputValue or 0) <= 0 then return end
    RfKeybindActionDialog.show()
end

-- The input-help legend is the one surface that always shows the LIVE binding,
-- the same source Controls reads, so the row is left visible rather than
-- hidden behind a default that may not exist.
local function afterPlayer(binding, eventId)
    binding:setActionEventActive(eventId, true)
    binding:setActionEventTextVisibility(eventId, true)
end

local function afterVehicle(binding, eventId)
    binding:setActionEventTextVisibility(eventId, true)
    SHLogger.info("%s registered in VEHICLE context", ACTION)
end

local PLAYER_SPECS = {
    { action = ACTION, handler = "onSummon", idField = "playerEventId",
      up = false, down = true, always = false, startActive = true, after = afterPlayer },
}

local VEHICLE_SPECS = {
    { action = ACTION, handler = "onSummon", idField = "vehicleEventId",
      up = false, down = true, always = false, startActive = true, after = afterVehicle },
}

--- Installs both wrappers once per loaded script environment. A second call is
--- a no-op, so a hot reload cannot stack a second wrapper on top of the first.
function RfControlCenterInput.install()
    if record.installed then return end
    record.installed = true

    if InputAction == nil or InputAction[ACTION] == nil then
        SHLogger.warning("InputAction %s missing - check modDesc <actions>", ACTION)
    end

    if RfContextInput.installPlayerWrapper(record, PLAYER_SPECS) then
        SHLogger.info("PlayerInputComponent hook installed (Control Center)")
    else
        SHLogger.warning("PlayerInputComponent.registerActionEvents unavailable - on-foot Control Center key disabled")
    end

    if RfContextInput.installVehicleWrapper(record, VEHICLE_SPECS) then
        SHLogger.info("InputBinding VEHICLE hook installed (Control Center)")
    else
        SHLogger.warning("InputBinding.endActionEventsModification unavailable - in-vehicle Control Center key disabled")
    end
end

--- Binds this module as the input owner of `mission` and creates fresh
--- per-context forwarding targets. Called from main.lua's Mission00.load hook
--- after the mission handle is assigned. Installs nothing.
function RfControlCenterInput.activate(mission)
    if PlayerInputComponent == nil or Vehicle == nil then return end
    RfContextInput.activate(record, RfControlCenterInput, mission,
        { [PlayerInputComponent.INPUT_CONTEXT_NAME] = PLAYER_SPECS,
          [Vehicle.INPUT_CONTEXT_NAME] = VEHICLE_SPECS })
end

--- Post-load catch-up: one complete PLAYER reconciliation from the existing
--- loadMission00Finished door, only if the local owning player and the native
--- PLAYER context already exist. No context, no timer.
function RfControlCenterInput.catchUp()
    RfContextInput.catchUpPlayer(record, PLAYER_SPECS)
end

--- Clears the per-update attempt memo. First input act in onMissionUpdate.
function RfControlCenterInput.resetAdmission()
    RfContextInput.resetAdmission(record)
end

--- Mission retirement: old targets go inert and the owner is released. The
--- captured predecessors stay installed for the next mission.
function RfControlCenterInput.retire()
    RfContextInput.retire(record)
    RfControlCenterInput.playerEventId = nil
    RfControlCenterInput.vehicleEventId = nil
end
