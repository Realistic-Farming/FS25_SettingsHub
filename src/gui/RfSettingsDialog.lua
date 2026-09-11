-- =========================================================
-- FS25_SettingsHub - RfSettingsDialog
-- =========================================================
-- The Realistic Farming Control Center: Settings tab. A live, editable
-- directory of every setting the suite has registered with the hub. Rows are
-- flattened from g_settingsHub:getModules() and edited through the shipped
-- write path g_settingsHub:setValue (validate -> route by scope -> persist ->
-- sync). Nothing here owns state; SettingsHub remains source of truth.
--
-- Structure mirrors RfKeybindActionDialog (itself following DepotDialog): a
-- fixed pool of row elements declared in XML and filled from Lua, with
-- pagination rather than runtime element creation.
--
-- Admin (server-shared) settings are editable only for the host / a master
-- user (hub:isLocalAdmin()); locked for everyone else. That gate is
-- presentation only: SettingsHubAdminEvent re-checks master rights server-side
-- and is the sole authority.
--
-- Hot-reload safe per the Wizard 2026-08-21 law: the class table is reused, not
-- replaced, so a live re-source does not orphan the metatable's target.
-- =========================================================

---@class RfSettingsDialog
RfSettingsDialog = RfSettingsDialog or {}
RfSettingsDialog.CLASS_NAME = "RfSettingsDialog"
RfSettingsDialog.ROWS = 20

local RfSettingsDialog_mt = Class(RfSettingsDialog, MessageDialog)

local _instance
local _modDir = SettingsHubModDirectory

-- === Pure value helpers (shared shape with the FarmTablet editor) =========

local function clampNum(v, mn, mx)
    if mn ~= nil and v < mn then v = mn end
    if mx ~= nil and v > mx then v = mx end
    return v
end

local function roundToStep(v, step)
    if step == nil or step == 0 then return v end
    return math.floor(v / step + 0.5) * step
end

-- The value one step press produces. dir = +1 (next / increment) or -1.
local function nextValue(t, v, dir, mn, mx, step, values)
    if t == "bool" then
        return not (v == true)
    elseif t == "enum" then
        values = values or {}
        if #values == 0 then return v end
        local idx = 1
        for i, o in ipairs(values) do if o == v then idx = i break end end
        idx = ((idx - 1 + dir) % #values) + 1
        return values[idx]
    elseif t == "int" then
        step = step or 1
        local nv = (tonumber(v) or 0) + dir * step
        nv = math.floor(nv + (nv >= 0 and 0.5 or -0.5))
        return clampNum(nv, mn, mx)
    elseif t == "float" then
        step = step or 0.1
        local nv = roundToStep((tonumber(v) or 0) + dir * step, step)
        return clampNum(nv, mn, mx)
    end
    return v
end

local function fmtValue(setting, v)
    if v == nil then v = setting.value end
    if v == nil then v = setting.default end
    if type(v) == "boolean" then return v and "On" or "Off" end
    if setting.type == "float" and type(v) == "number" then
        return string.format("%.2f", v)
    end
    return tostring(v)
end

-- Friendly module name from a modId: drop the FS25_ prefix.
local function displayModule(modId)
    modId = tostring(modId or "")
    return (modId:gsub("^FS25_", ""))
end

-- === Construction =========================================

function RfSettingsDialog.new()
    local self = MessageDialog.new(nil, RfSettingsDialog_mt)
    self.rows      = {}
    self.pageIndex = 0
    self.slots     = {}
    self.isAdmin   = false
    return self
end

function RfSettingsDialog.getInstance()
    return _instance
end

--- Loads the GUI once. Safe to call repeatedly.
function RfSettingsDialog.register()
    if _instance ~= nil then return end
    _instance = RfSettingsDialog.new()
    SHLogger.info("RfSettingsDialog.register: loading GUI from %s", tostring(_modDir))
    g_gui:loadGui(_modDir .. "xml/gui/RfSettingsDialog.xml",
        RfSettingsDialog.CLASS_NAME, _instance)
end

--- Opens the Settings tab, refusing when the context guard says no.
---@return boolean opened
function RfSettingsDialog.show()
    local canOpen, reason = RfInputContextGuard.canOpen()
    if not canOpen then
        SHLogger.info("Settings dialog not opened: %s", tostring(reason))
        return false
    end
    if _instance == nil then
        RfSettingsDialog.register()
    end
    _instance.pageIndex = 0
    g_gui:showDialog(RfSettingsDialog.CLASS_NAME)
    return true
end

-- === Lifecycle ===========================================

function RfSettingsDialog:onCreate()
    local ok, err = pcall(function() RfSettingsDialog:superClass().onCreate(self) end)
    if not ok then
        SHLogger.error("RfSettingsDialog:onCreate error: %s", tostring(err))
    end
end

function RfSettingsDialog:onGuiSetupFinished()
    RfSettingsDialog:superClass().onGuiSetupFinished(self)

    self.titleText  = self:getDescendantById("rfsTitleText")
    self.pageLabel  = self:getDescendantById("pageLabel")
    self.statusText = self:getDescendantById("statusText")
    self.summonHint = self:getDescendantById("summonHint")
    self.prevPageBtn = self:getDescendantById("prevPageBtn")
    self.nextPageBtn = self:getDescendantById("nextPageBtn")

    -- Cache the fixed row pool once. Slot indices 1-based, element ids 0-based.
    self.slots = {}
    for i = 1, RfSettingsDialog.ROWS do
        local n = tostring(i - 1)
        self.slots[i] = {
            module  = self:getDescendantById("row" .. n .. "module"),
            setting = self:getDescendantById("row" .. n .. "setting"),
            value   = self:getDescendantById("row" .. n .. "value"),
            dec     = self:getDescendantById("row" .. n .. "dec"),
            inc     = self:getDescendantById("row" .. n .. "inc"),
        }
    end
end

function RfSettingsDialog:onOpen()
    RfSettingsDialog:superClass().onOpen(self)
    self:refresh()
end

--- Named rfsOnClose so the XML binds this and not the superclass handler,
--- matching the DepotDialog / keybind-dialog convention.
function RfSettingsDialog:rfsOnClose()
    RfSettingsDialog:superClass().onClose(self)
    self.rows = {}
end

function RfSettingsDialog:onClickBack()
    g_gui:closeDialogByName(RfSettingsDialog.CLASS_NAME)
end

--- Swap to the keybind tab (the other half of the Control Center).
function RfSettingsDialog:onClickKeybinds()
    g_gui:closeDialogByName(RfSettingsDialog.CLASS_NAME)
    if RfKeybindActionDialog ~= nil and RfKeybindActionDialog.show ~= nil then
        RfKeybindActionDialog.show()
    end
end

-- === Model ===============================================

--- Flat row list for the current session: one row per registered setting,
--- module order preserved. Rebuilt on every open and after each edit so a
--- freshly loaded companion or a value change both show without a restart.
---@return table rows array of { modId, setting }
function RfSettingsDialog.getRows()
    local rows = {}
    local hub = g_settingsHub
    if hub == nil or hub.getModules == nil then return rows end
    local ok, modules = pcall(function() return hub:getModules() end)
    if not ok or type(modules) ~= "table" then return rows end
    for _, mod in ipairs(modules) do
        for _, s in ipairs(mod.settings or {}) do
            rows[#rows + 1] = { modId = mod.modId, setting = s }
        end
    end
    return rows
end

-- === Rendering ===========================================

function RfSettingsDialog:refresh()
    local hub = g_settingsHub
    self.isAdmin = hub ~= nil and hub.isLocalAdmin ~= nil and hub:isLocalAdmin() == true

    self.rows = RfSettingsDialog.getRows()

    local pageCount = self:getPageCount()
    if self.pageIndex >= pageCount then
        self.pageIndex = math.max(0, pageCount - 1)
    end

    self:paintPage()
    self:paintFooter()
end

function RfSettingsDialog:getPageCount()
    local total = #self.rows
    if total == 0 then return 1 end
    return math.ceil(total / RfSettingsDialog.ROWS)
end

function RfSettingsDialog:paintPage()
    local first = self.pageIndex * RfSettingsDialog.ROWS
    for slot = 1, RfSettingsDialog.ROWS do
        local row = self.rows[first + slot]
        if row == nil then
            self:clearSlot(slot)
        else
            self:paintSlot(slot, row)
        end
    end
end

function RfSettingsDialog:paintSlot(slot, row)
    local cells = self.slots[slot]
    if cells == nil then return end
    local s = row.setting
    local locked = s.adminOnly and not self.isAdmin

    if cells.module ~= nil then cells.module:setText(displayModule(row.modId)) end

    if cells.setting ~= nil then
        local label = s.label or s.id
        if s.adminOnly then
            label = tostring(label) .. (locked and "  (admin, locked)" or "  (admin)")
        end
        cells.setting:setText(tostring(label))
    end

    -- Widget by type. Bool shows its state on the single (inc) button; enum and
    -- numbers get a [-]/[<] and [+]/[>] pair with the value between.
    local dec, inc = cells.dec, cells.inc
    if locked then
        if dec ~= nil then dec:setVisible(false) end
        if inc ~= nil then inc:setVisible(false) end
        if cells.value ~= nil then cells.value:setText(fmtValue(s, s.value)) end
    elseif s.type == "bool" then
        if dec ~= nil then dec:setVisible(false) end
        if inc ~= nil then
            inc:setVisible(true)
            inc:setText(s.value == true and "On" or "Off")
        end
        if cells.value ~= nil then cells.value:setText("") end
    else
        local decLbl = (s.type == "enum") and "<" or "-"
        local incLbl = (s.type == "enum") and ">" or "+"
        if dec ~= nil then dec:setVisible(true); dec:setText(decLbl) end
        if inc ~= nil then inc:setVisible(true); inc:setText(incLbl) end
        if cells.value ~= nil then cells.value:setText(fmtValue(s, s.value)) end
    end
end

function RfSettingsDialog:clearSlot(slot)
    local cells = self.slots[slot]
    if cells == nil then return end
    if cells.module  ~= nil then cells.module:setText("") end
    if cells.setting ~= nil then cells.setting:setText("") end
    if cells.value   ~= nil then cells.value:setText("") end
    if cells.dec     ~= nil then cells.dec:setVisible(false) end
    if cells.inc     ~= nil then cells.inc:setVisible(false) end
end

function RfSettingsDialog:paintFooter()
    local pageCount = self:getPageCount()

    if self.pageLabel ~= nil then
        self.pageLabel:setText(string.format("Page %d / %d   (%d settings)",
            self.pageIndex + 1, pageCount, #self.rows))
    end
    if self.prevPageBtn ~= nil then self.prevPageBtn:setVisible(pageCount > 1) end
    if self.nextPageBtn ~= nil then self.nextPageBtn:setVisible(pageCount > 1) end

    if self.summonHint ~= nil then
        local hint = "Local settings save on this machine. Server-shared (admin) settings apply to everyone."
        if not self.isAdmin then
            hint = hint .. "  You are not an admin, so admin settings are locked."
        end
        self.summonHint:setText(hint)
    end

    if self.statusText ~= nil and #self.rows == 0 then
        self.statusText:setText("No Realistic Farming settings registered in this session.")
    end
end

function RfSettingsDialog:showStatus(text)
    if self.statusText ~= nil then
        self.statusText:setText(text or "")
    end
end

-- === Paging ==============================================

function RfSettingsDialog:onPrevPage()
    if self.pageIndex > 0 then
        self.pageIndex = self.pageIndex - 1
        self:paintPage()
        self:paintFooter()
    end
end

function RfSettingsDialog:onNextPage()
    if self.pageIndex < self:getPageCount() - 1 then
        self.pageIndex = self.pageIndex + 1
        self:paintPage()
        self:paintFooter()
    end
end

-- === Editing =============================================

--- Steps the setting behind a visible slot by one press. Reads the LIVE value
--- so a stale page never writes an old value back. Admin settings are refused
--- here for non-admins (presentation gate); the server is authoritative.
function RfSettingsDialog:stepSlot(slot, dir)
    local row = self.rows[self.pageIndex * RfSettingsDialog.ROWS + slot]
    if row == nil or row.setting == nil then return end

    if not RfInputContextGuard.hasLiveMission() then
        self:showStatus("No active game to change settings in.")
        return
    end

    local hub = g_settingsHub
    if hub == nil then return end
    local s = row.setting

    if s.adminOnly and not (hub.isLocalAdmin and hub:isLocalAdmin()) then
        self:showStatus("That is a server setting. Only the host or an admin can change it.")
        return
    end

    local cur = hub:getValue(row.modId, s.id)
    if cur == nil then cur = s.default end
    local nv = nextValue(s.type, cur, dir, s.min, s.max, s.step, s.values)

    local ok = pcall(function() hub:setValue(row.modId, s.id, nv) end)
    if not ok then
        SHLogger.error("RfSettingsDialog: setValue failed for %s.%s", tostring(row.modId), tostring(s.id))
        self:showStatus("Could not change that setting. See log.txt.")
        return
    end

    self:refresh()
    local disp = s.label or s.id
    self:showStatus(tostring(disp) .. " set to " .. fmtValue(s, nv))
end

-- Generate the fixed-pool step handlers (onDec0..onDecN / onInc0..onIncN) the
-- XML binds by name. Assigned onto the class table so a re-source refreshes
-- them idempotently, matching the hot-reload law.
for i = 0, RfSettingsDialog.ROWS - 1 do
    local slot = i + 1
    RfSettingsDialog["onDec" .. i] = function(self) self:stepSlot(slot, -1) end
    RfSettingsDialog["onInc" .. i] = function(self) self:stepSlot(slot,  1) end
end

-- ---------------------------------------------------------
-- Delivery print (Wizard hot-reload law): every push announces itself, so a
-- dropped reload and a landed one are distinguishable in log.txt.
-- ---------------------------------------------------------
SHLogger.info("[RFCC] RfSettingsDialog loaded (rows=%d)", RfSettingsDialog.ROWS)
