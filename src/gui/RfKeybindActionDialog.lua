-- =========================================================
-- FS25_SettingsHub - RfKeybindActionDialog
-- =========================================================
-- The Realistic Farming Control Center dialog: a live directory of every suite
-- action in the session, the key each one is actually bound to, and a trigger
-- button for the ones whose owner registered a delegate.
--
-- Structure follows DepotDialog, which is the proven MessageDialog form in this
-- suite: a fixed pool of row elements declared in XML and filled from Lua, with
-- pagination rather than runtime element creation.
--
-- Declared hot-reload safe per the Wizard 2026-08-21 law: the class table is
-- reused rather than replaced, so a live re-source does not orphan the table the
-- existing metatable points at.
-- =========================================================

---@class RfKeybindActionDialog
RfKeybindActionDialog = RfKeybindActionDialog or {}
RfKeybindActionDialog.CLASS_NAME = "RfKeybindActionDialog"
RfKeybindActionDialog.ROWS = 25

local RfKeybindActionDialog_mt = Class(RfKeybindActionDialog, MessageDialog)

local _instance
local _modDir = SettingsHubModDirectory

-- Forward declaration. register() is defined above the probe body below, and a
-- local is not in scope before its declaration, so without this the call there
-- would resolve to a nil global instead.
local probeInputApi

function RfKeybindActionDialog.new()
    local self = MessageDialog.new(nil, RfKeybindActionDialog_mt)
    self.rows      = {}
    self.pageIndex = 0
    self.slots     = {}
    return self
end

function RfKeybindActionDialog.getInstance()
    return _instance
end

--- Loads the GUI once. Safe to call repeatedly.
function RfKeybindActionDialog.register()
    if _instance ~= nil then return end
    _instance = RfKeybindActionDialog.new()
    SHLogger.info("RfKeybindActionDialog.register: loading GUI from %s", tostring(_modDir))
    g_gui:loadGui(_modDir .. "xml/gui/RfKeybindActionDialog.xml",
        RfKeybindActionDialog.CLASS_NAME, _instance)
    probeInputApi()
end

--- Opens the Control Center, refusing when the context guard says no. Returns
--- false when it declined, so the caller can log why without duplicating the
--- guard logic.
---@return boolean opened
function RfKeybindActionDialog.show()
    local canOpen, reason = RfInputContextGuard.canOpen()
    if not canOpen then
        SHLogger.info("Control Center not opened: %s", tostring(reason))
        return false
    end

    if _instance == nil then
        RfKeybindActionDialog.register()
    end

    _instance.pageIndex = 0
    g_gui:showDialog(RfKeybindActionDialog.CLASS_NAME)
    return true
end

-- === Lifecycle ===========================================

function RfKeybindActionDialog:onCreate()
    local ok, err = pcall(function() RfKeybindActionDialog:superClass().onCreate(self) end)
    if not ok then
        SHLogger.error("RfKeybindActionDialog:onCreate error: %s", tostring(err))
    end
end

function RfKeybindActionDialog:onGuiSetupFinished()
    RfKeybindActionDialog:superClass().onGuiSetupFinished(self)

    self.titleText  = self:getDescendantById("rfccTitleText")
    self.pageLabel  = self:getDescendantById("pageLabel")
    self.statusText = self:getDescendantById("statusText")
    self.summonHint = self:getDescendantById("summonHint")
    self.prevPageBtn = self:getDescendantById("prevPageBtn")
    self.nextPageBtn = self:getDescendantById("nextPageBtn")

    -- Cache the fixed row pool once. Slot indices are 1 based, element ids 0 based.
    self.slots = {}
    for i = 1, RfKeybindActionDialog.ROWS do
        local n = tostring(i - 1)
        self.slots[i] = {
            module = self:getDescendantById("row" .. n .. "module"),
            action = self:getDescendantById("row" .. n .. "action"),
            key    = self:getDescendantById("row" .. n .. "key"),
            button = self:getDescendantById("row" .. n .. "btn"),
            rebind = self:getDescendantById("row" .. n .. "rebind"),
        }
    end
end

function RfKeybindActionDialog:onOpen()
    RfKeybindActionDialog:superClass().onOpen(self)
    self:refresh()
end

--- Named rfccOnClose rather than onClose so the XML binds this and not the
--- superclass handler, matching the DepotDialog convention.
function RfKeybindActionDialog:rfccOnClose()
    RfKeybindActionDialog:superClass().onClose(self)
    self.rows = {}
end

function RfKeybindActionDialog:onClickBack()
    g_gui:closeDialogByName(RfKeybindActionDialog.CLASS_NAME)
end

--- Swap to the Settings tab. Closes this dialog first so the settings dialog
--- opens with clean input focus rather than stacked behind the keybind view.
function RfKeybindActionDialog:onClickSettings()
    g_gui:closeDialogByName(RfKeybindActionDialog.CLASS_NAME)
    if RfSettingsDialog ~= nil and RfSettingsDialog.show ~= nil then
        RfSettingsDialog.show()
    end
end

--- Footer "Reset Keys": restores JUST the suite actions shown in this dialog to
--- their mod-declared defaults, after a confirmation. Deliberately NOT the
--- engine's restoreDefaultBindings(), which resets every control in the game.
function RfKeybindActionDialog:onClickReset()
    if g_inputBinding == nil then
        self:showStatus("Rebinding is unavailable in this build.")
        return
    end
    if YesNoDialog ~= nil and YesNoDialog.show ~= nil then
        YesNoDialog.show(self.onResetConfirm, self,
            "Reset the Realistic Farming key bindings shown here to their defaults? "
                .. "Other game controls are not affected.",
            "Reset Key Bindings", "Reset", "Cancel")
    else
        self:onResetConfirm(true)
    end
end

--- YesNoDialog callback (yes == true when the player confirmed).
function RfKeybindActionDialog:onResetConfirm(yes)
    if yes ~= true then return end
    local n = self:_resetSuiteBindings()
    self:refresh()
    self:showStatus(string.format("Reset %d Realistic Farming key binding(s) to defaults.", n))
end

--- Resets only the suite actions in self.rows to their mod defaults, leaving all
--- other keybinds untouched. Engine-native mechanism: clear each target action's
--- bindings and its bindingsKnown flag, then loadModBindingDefaults() re-adds the
--- modDesc default for exactly the actions now marked unknown (every other action
--- keeps bindingsKnown = true and is skipped). Verified against InputBinding
--- loadActionBindingsFromXMLPath / loadModBindingDefaults / deleteBinding.
---@return number reset count
function RfKeybindActionDialog:_resetSuiteBindings()
    local ib = g_inputBinding
    if ib == nil or ib.getActionByName == nil then return 0 end

    local touched = {}
    for _, row in ipairs(self.rows) do
        local action = ib:getActionByName(row.action)
        if action ~= nil and action.getBindings ~= nil and touched[row.action] == nil then
            touched[row.action] = action
            -- Delete a snapshot of the action's current bindings (deleteBinding
            -- mutates the live list, so iterate a copy).
            local snapshot = {}
            for _, b in pairs(action:getBindings()) do snapshot[#snapshot + 1] = b end
            for _, b in ipairs(snapshot) do
                pcall(function() ib:deleteBinding(b.deviceId, row.action, b.index, b.axisComponent) end)
            end
            action.bindingsKnown = false   -- so loadModBindingDefaults refills this one
        end
    end

    local count = 0
    for _ in pairs(touched) do count = count + 1 end
    if count == 0 then return 0 end

    -- Re-add mod defaults for the (now unknown) suite actions only.
    pcall(function() ib:loadModBindingDefaults() end)
    -- Restore the invariant: these actions have known bindings again.
    for _, action in pairs(touched) do action.bindingsKnown = true end

    -- Apply live (assignActionPrimaryBindings + refreshEventCollections) and persist.
    pcall(function() ib:commitBindingChanges() end)
    pcall(function() ib:saveToXMLFile() end)
    return count
end

--- One-shot probe of the live input API surface, written to log.txt the first
--- time the Control Center is registered.
---
--- Static evidence says no rebinding API is reachable from a mod, but static
--- evidence is not the live engine, and the extracted InputBinding.lua is
--- stubbed to a single function so it cannot answer the question. This lists
--- what the running g_inputBinding actually exposes. If a binding setter turns
--- up in that list, in-dialog rebinding becomes buildable on verified ground
--- instead of guesswork; if it does not, the question is closed for good.
local _probed = false
probeInputApi = function()
    if _probed then return end
    _probed = true

    -- Walk a table for string-keyed functions.
    local function collect(tbl)
        local names = {}
        if type(tbl) ~= "table" then return names end
        local ok = pcall(function()
            for key, value in pairs(tbl) do
                if type(key) == "string" and type(value) == "function" then
                    names[#names + 1] = key
                end
            end
        end)
        if not ok then return {} end
        table.sort(names)
        return names
    end

    local function report(label, tbl)
        local names = collect(tbl)
        if #names == 0 then
            SHLogger.info("[RFCC probe] %s: no functions", label)
        else
            SHLogger.info("[RFCC probe] %s (%d): %s", label, #names, table.concat(names, ", "))
        end
    end

    -- The first attempt walked only g_inputBinding itself and found a single
    -- function, because the instance carries data while its methods live on the
    -- class reached through the metatable __index. Walk that chain instead.
    report("g_inputBinding instance", g_inputBinding)

    local mt = nil
    pcall(function() mt = getmetatable(g_inputBinding) end)
    if mt ~= nil then
        report("g_inputBinding metatable", mt)
        report("g_inputBinding metatable.__index", mt.__index)
    else
        SHLogger.info("[RFCC probe] g_inputBinding has no metatable")
    end

    report("InputBinding class", InputBinding)
    report("g_inputDisplayManager", g_inputDisplayManager)
end

-- === Rendering ===========================================

--- Rebuilds the row list and repaints the current page. Called on every open so
--- a key remapped in the base game Controls page, a mod installed since the last
--- open, or a delegate registered late all show up without a restart.
function RfKeybindActionDialog:refresh()
    self.rows = RfActionRegistry.getRows()

    local pageCount = self:getPageCount()
    if self.pageIndex >= pageCount then
        self.pageIndex = math.max(0, pageCount - 1)
    end

    self:paintPage()
    self:paintFooter()
end

function RfKeybindActionDialog:getPageCount()
    local total = #self.rows
    if total == 0 then return 1 end
    return math.ceil(total / RfKeybindActionDialog.ROWS)
end

function RfKeybindActionDialog:paintPage()
    local first = self.pageIndex * RfKeybindActionDialog.ROWS

    for slot = 1, RfKeybindActionDialog.ROWS do
        local row = self.rows[first + slot]
        if row == nil then
            self:clearSlot(slot)
        else
            self:paintSlot(slot, row)
        end
    end
end

function RfKeybindActionDialog:paintSlot(slot, row)
    local cells = self.slots[slot]
    if cells == nil then return end

    if cells.module ~= nil then cells.module:setText(row.group) end
    if cells.action ~= nil then cells.action:setText(row.label) end
    if cells.key    ~= nil then cells.key:setText(row.chord) end

    -- A row only gets a button when its owner registered something to run, and
    -- never for the summon action itself: the dialog is already open.
    local runnable = row.delegate ~= nil
        and row.action ~= RfActionRegistry.SUMMON_ACTION

    if cells.button ~= nil then
        cells.button:setVisible(runnable)
        if runnable then
            -- button may be a plain string or a function evaluated each paint, so
            -- a stateful delegate (e.g. a HUD hide/show) can show "Hide" or "Show"
            -- for its current state. A throwing or non-string function falls back.
            local caption = row.delegate.button
            if type(caption) == "function" then
                local okCap, txt = pcall(caption)
                caption = (okCap and type(txt) == "string" and txt) or "Run"
            end
            cells.button:setText(caption or "Run")
        end
    end

    -- Every real row is a rebindable action, so its Rebind button is always
    -- shown. Keybinds are client-local, so no admin gate is needed here.
    if cells.rebind ~= nil then cells.rebind:setVisible(true) end
end

function RfKeybindActionDialog:clearSlot(slot)
    local cells = self.slots[slot]
    if cells == nil then return end

    if cells.module ~= nil then cells.module:setText("") end
    if cells.action ~= nil then cells.action:setText("") end
    if cells.key    ~= nil then cells.key:setText("") end
    if cells.button ~= nil then cells.button:setVisible(false) end
    if cells.rebind ~= nil then cells.rebind:setVisible(false) end
end

function RfKeybindActionDialog:paintFooter()
    local pageCount = self:getPageCount()

    if self.pageLabel ~= nil then
        self.pageLabel:setText(string.format("Page %d / %d   (%d actions)",
            self.pageIndex + 1, pageCount, #self.rows))
    end

    -- Paging controls only earn their place when there is more than one page.
    if self.prevPageBtn ~= nil then self.prevPageBtn:setVisible(pageCount > 1) end
    if self.nextPageBtn ~= nil then self.nextPageBtn:setVisible(pageCount > 1) end

    if self.summonHint ~= nil then
        self.summonHint:setText("Control Center key: " .. RfActionRegistry.getSummonChord())
    end

    if self.statusText ~= nil and #self.rows == 0 then
        self.statusText:setText("No Realistic Farming actions found in this session.")
    end
end

function RfKeybindActionDialog:showStatus(text)
    if self.statusText ~= nil then
        self.statusText:setText(text or "")
    end
end

-- === Paging ==============================================

function RfKeybindActionDialog:onPrevPage()
    if self.pageIndex > 0 then
        self.pageIndex = self.pageIndex - 1
        self:paintPage()
        self:paintFooter()
    end
end

function RfKeybindActionDialog:onNextPage()
    if self.pageIndex < self:getPageCount() - 1 then
        self.pageIndex = self.pageIndex + 1
        self:paintPage()
        self:paintFooter()
    end
end

-- === Triggering ==========================================

--- Runs the delegate behind a visible slot. Every delegate is called inside a
--- pcall: a companion mod throwing must not take the Control Center, or the
--- session, down with it.
function RfKeybindActionDialog:triggerSlot(slot)
    local row = self.rows[self.pageIndex * RfKeybindActionDialog.ROWS + slot]
    if row == nil or row.delegate == nil then return end

    if not RfInputContextGuard.hasLiveMission() then
        self:showStatus("No active game to run that against.")
        return
    end

    local delegate = row.delegate

    -- Full screen targets need the Control Center out of the way first, or the
    -- new screen opens behind a dialog that still owns input.
    if delegate.closeFirst then
        g_gui:closeDialogByName(RfKeybindActionDialog.CLASS_NAME)
    end

    local ok, result = pcall(delegate.run)
    if not ok then
        SHLogger.error("Control Center: action %s failed: %s",
            tostring(row.action), tostring(result))
        if not delegate.closeFirst then
            self:showStatus("That action reported an error. See log.txt.")
        end
        return
    end

    if not delegate.closeFirst then
        -- A delegate may return a status string describing the new state (e.g.
        -- "Income HUD hidden"). Repaint first so a function-valued button caption
        -- flips in place (Hide <-> Show) without the player leaving the dialog.
        -- Both are opt in: a delegate returning nothing with a plain-string
        -- caption behaves exactly as before.
        self:paintPage()
        self:paintFooter()
        self:showStatus(type(result) == "string" and result or (row.label .. " triggered."))
    end
end

function RfKeybindActionDialog:onTrigger0() self:triggerSlot(1) end
function RfKeybindActionDialog:onTrigger1() self:triggerSlot(2) end
function RfKeybindActionDialog:onTrigger2() self:triggerSlot(3) end
function RfKeybindActionDialog:onTrigger3() self:triggerSlot(4) end
function RfKeybindActionDialog:onTrigger4() self:triggerSlot(5) end
function RfKeybindActionDialog:onTrigger5() self:triggerSlot(6) end
function RfKeybindActionDialog:onTrigger6() self:triggerSlot(7) end
function RfKeybindActionDialog:onTrigger7() self:triggerSlot(8) end
function RfKeybindActionDialog:onTrigger8() self:triggerSlot(9) end
function RfKeybindActionDialog:onTrigger9() self:triggerSlot(10) end
function RfKeybindActionDialog:onTrigger10() self:triggerSlot(11) end
function RfKeybindActionDialog:onTrigger11() self:triggerSlot(12) end
function RfKeybindActionDialog:onTrigger12() self:triggerSlot(13) end
function RfKeybindActionDialog:onTrigger13() self:triggerSlot(14) end
function RfKeybindActionDialog:onTrigger14() self:triggerSlot(15) end
function RfKeybindActionDialog:onTrigger15() self:triggerSlot(16) end
function RfKeybindActionDialog:onTrigger16() self:triggerSlot(17) end
function RfKeybindActionDialog:onTrigger17() self:triggerSlot(18) end
function RfKeybindActionDialog:onTrigger18() self:triggerSlot(19) end
function RfKeybindActionDialog:onTrigger19() self:triggerSlot(20) end
function RfKeybindActionDialog:onTrigger20() self:triggerSlot(21) end
function RfKeybindActionDialog:onTrigger21() self:triggerSlot(22) end
function RfKeybindActionDialog:onTrigger22() self:triggerSlot(23) end
function RfKeybindActionDialog:onTrigger23() self:triggerSlot(24) end
function RfKeybindActionDialog:onTrigger24() self:triggerSlot(25) end

-- === Inline rebinding (keyboard, primary binding) ========
-- v1 scope: capture ONE keyboard key/combo for a row's action and write it as
-- the primary keyboard binding. Gamepad, mouse axes and combo-mask editing are
-- left to the base Controls page (the [Change Keys] button). The whole chain is
-- the base game's own (ControlsController): startBindingChanges -> startInputCapture
-- -> updateBinding (else addBinding) -> commitBindingChanges + saveToXMLFile.
-- Keybinds are client-local, so there is no server round trip and no admin gate.

--- Enters "press a key" capture for the action behind a visible slot.
function RfKeybindActionDialog:beginRebind(slot)
    if self.rebindActive then return end

    local row = self.rows[self.pageIndex * RfKeybindActionDialog.ROWS + slot]
    if row == nil then return end

    if not RfInputContextGuard.hasLiveMission() then
        self:showStatus("No active game to rebind in.")
        return
    end
    if g_inputBinding == nil or InputAction == nil or InputAction[row.action] == nil then
        self:showStatus("That action cannot be rebound here.")
        return
    end
    if InputDevice == nil or Binding == nil then
        self:showStatus("Rebinding is unavailable in this build.")
        return
    end

    local action = g_inputBinding:getActionByName(row.action)
    if action == nil then
        self:showStatus("Action not found.")
        return
    end

    -- Replace the existing primary keyboard binding if there is one; else append.
    local kbDev = InputDevice.DEFAULT_DEVICE_NAMES.KB_MOUSE_DEFAULT
    local bindingIndex = 1
    if action.getBindings ~= nil then
        local ok, bindings = pcall(function() return action:getBindings() end)
        if ok and type(bindings) == "table" then
            for _, b in pairs(bindings) do
                if b.deviceId == kbDev and b.axisComponent == Binding.AXIS_COMPONENT.POSITIVE then
                    bindingIndex = b.index or bindingIndex
                    break
                end
            end
        end
    end

    self.rebindActive    = true
    self.rebindCommitted = false
    self.rebindState = { action = row.action, label = row.label, kbDev = kbDev,
                         bindingIndex = bindingIndex, keys = {} }

    local ok = pcall(function() g_inputBinding:startBindingChanges() end)
    if not ok then
        self.rebindActive = false
        self:showStatus("Could not start rebinding. See log.txt.")
        return
    end

    self:showStatus("Press a key for '" .. tostring(row.label) .. "'   (Esc to cancel)")

    -- Keyboard capture. Callback shape (verified against InputBinding:startInputCapture):
    --   inputCallback(target, deviceId, axisName, inputValue, initInputValue, state)
    --   abortCallback(target) ; deleteCallback(target, state)
    pcall(function()
        g_inputBinding:startInputCapture(true, false, self, self.rebindState,
            self.onRebindCapture, self.onRebindAbort, self.onRebindDelete)
    end)
end

--- Gathers held keys; assigns on release (inputValue == 0).
function RfKeybindActionDialog:onRebindCapture(_deviceId, keyName, inputValue, _initValue, state)
    if state == nil then return end
    if (inputValue or 0) > 0 then
        if keyName ~= nil then
            local seen = false
            for _, k in ipairs(state.keys) do if k == keyName then seen = true break end end
            if not seen then table.insert(state.keys, keyName) end
        end
        return
    end
    self:_assignRebind(state)
end

function RfKeybindActionDialog:onRebindAbort()
    self:_finishRebind(false, "Rebind cancelled.")
end

function RfKeybindActionDialog:onRebindDelete(_state)
    -- v1 leaves the existing binding rather than clearing it (delete/clear is a
    -- base-Controls concern); treat as a cancel.
    self:_finishRebind(false, "Rebind cancelled.")
end

--- Writes the gathered keys as the action's primary keyboard binding.
function RfKeybindActionDialog:_assignRebind(state)
    if state == nil or #state.keys == 0 then
        self:_finishRebind(false, "No key captured.")
        return
    end

    local kbDev  = state.kbDev
    local axisC  = Binding.AXIS_COMPONENT.POSITIVE
    local inputC = Binding.INPUT_COMPONENT.POSITIVE
    local action = g_inputBinding:getActionByName(state.action)

    -- Try to replace the existing binding at bindingIndex; addBinding if none.
    local success, collision, blockAdd = false, nil, false
    local pok, r1, r2, r3 = pcall(function()
        return g_inputBinding:updateBinding(kbDev, state.action, state.bindingIndex, axisC,
                                            kbDev, state.keys, inputC, 0)
    end)
    if pok then success, collision, blockAdd = r1, r2, r3 end

    if not success and not blockAdd and action ~= nil then
        local aok, added, coll = pcall(function()
            local binding = Binding.new(kbDev, state.keys, axisC, inputC, 0, state.bindingIndex)
            return g_inputBinding:addBinding(action, binding)
        end)
        if aok then
            success  = added
            collision = collision or coll
        end
    end

    if blockAdd then
        self:_finishRebind(false, "That key is already bound to this action.")
        return
    end
    if not success then
        self:_finishRebind(false, "Could not set that key.")
        return
    end

    -- commitBindingChanges applies it live; saveToXMLFile persists across restart.
    pcall(function() g_inputBinding:commitBindingChanges() end)
    pcall(function() g_inputBinding:saveToXMLFile() end)
    self.rebindCommitted = true

    local msg = "'" .. tostring(state.label) .. "' rebound."
    if collision ~= nil then msg = msg .. " (took a key from another action)" end
    self:_finishRebind(true, msg)
end

--- Ends capture, rolls back if nothing was committed, and repaints so the Key
--- column shows the new chord.
function RfKeybindActionDialog:_finishRebind(committed, statusMsg)
    if g_inputBinding ~= nil then
        pcall(function() g_inputBinding:stopInputGathering() end)
        if not (committed or self.rebindCommitted) then
            pcall(function() g_inputBinding:rollbackBindingChanges() end)
        end
    end
    self.rebindActive    = false
    self.rebindState     = nil
    self.rebindCommitted = false

    self:refresh()   -- re-reads chords via RfActionRegistry.getRows
    if statusMsg ~= nil then self:showStatus(statusMsg) end
end

-- Generate the fixed-pool rebind handlers (onRebind0..N) the XML binds by name.
-- Assigned onto the class table so a re-source refreshes them idempotently.
for i = 0, RfKeybindActionDialog.ROWS - 1 do
    local slot = i + 1
    RfKeybindActionDialog["onRebind" .. i] = function(self) self:beginRebind(slot) end
end

-- ---------------------------------------------------------
-- Delivery print (Wizard hot-reload law). Every push must announce itself:
-- without an unconditional line at load, a dropped reload and a landed one look
-- identical in log.txt. If this line is absent after a push, the reload did not
-- land and the live code is still the previous version.
--
-- Also re-runs the probe on each push. _probed is a file-local, so a re-source
-- clears it, and the report is emitted here rather than waiting for the next
-- dialog open.
-- ---------------------------------------------------------
SHLogger.info("[RFCC] RfKeybindActionDialog loaded (rows=%d)", RfKeybindActionDialog.ROWS)
probeInputApi()
