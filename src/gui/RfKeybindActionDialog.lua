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

--- Sends the player to the base game menu, where key bindings actually live.
---
--- FS25 exposes no mod-callable way to write a binding. The engine source the
--- GIANTS extension extracts carries no input settings frame, the SDK ships only
--- inputActions.xml (a catalogue, not an API), and a sweep of all 1838 installed
--- mods found not one call to any binding setter on g_inputBinding: the whole
--- surface in use out there is action-event registration and help text. So the
--- Control Center reads bindings and hands rebinding back to the screen that
--- owns it rather than guessing at an engine call.
---
--- Nothing is lost by the round trip: the key column is read fresh on every
--- open, so a key changed in Controls shows here the next time it is summoned.
function RfKeybindActionDialog:onClickRebind()
    g_gui:closeDialogByName(RfKeybindActionDialog.CLASS_NAME)

    -- The route the base game's own menu toggle takes.
    local ok, err = pcall(function() g_gui:changeScreen(nil, InGameMenu) end)
    if not ok then
        SHLogger.error("Control Center: could not open the game menu: %s", tostring(err))
    end
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
end

function RfKeybindActionDialog:clearSlot(slot)
    local cells = self.slots[slot]
    if cells == nil then return end

    if cells.module ~= nil then cells.module:setText("") end
    if cells.action ~= nil then cells.action:setText("") end
    if cells.key    ~= nil then cells.key:setText("") end
    if cells.button ~= nil then cells.button:setVisible(false) end
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
