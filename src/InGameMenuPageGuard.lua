-- =========================================================
-- FS25_SettingsHub - InGameMenuPageGuard.lua
-- =========================================================
-- Suite-wide fix for stacked ESC-menu pages (Finances /
-- Statistics / Vehicles / Map drawn at once).
--
-- Cause: TabbedMenu:onPageChange only hides the *previous*
-- currentPage. Companion mods that inject tabs (WorkerCosts,
-- MarketDynamics, SeasonalCropStress, SoilFertilizer) plus any
-- mid-click LUA error (StatisticsFrame.isa) can leave orphans
-- visible. This guard is idempotent and safe when companions
-- are missing — install once from SettingsHub.
-- =========================================================

InGameMenuPageGuard = {}

local function enforceSingleVisibleMenuPage(menu)
    if menu == nil then return end
    local current = menu.currentPage

    local function hideIfNotCurrent(el)
        if el == nil or el.setVisible == nil then return end
        local want = (el == current)
        if el.getIsVisible ~= nil then
            local ok, vis = pcall(el.getIsVisible, el)
            if ok and vis == want then return end
        elseif el.visible ~= nil and el.visible == want then
            return
        end
        pcall(el.setVisible, el, want)
    end

    if menu.pageFrames ~= nil then
        for _, frame in ipairs(menu.pageFrames) do
            hideIfNotCurrent(frame)
        end
    end

    local paging = menu.pagingElement
    if paging ~= nil then
        if paging.pages ~= nil then
            for _, pageInfo in pairs(paging.pages) do
                hideIfNotCurrent(pageInfo and pageInfo.element)
            end
        end
        if paging.elements ~= nil then
            for _, el in ipairs(paging.elements) do
                if el ~= nil and (el.getMenuButtonInfo ~= nil or el.onFrameOpen ~= nil) then
                    hideIfNotCurrent(el)
                end
            end
        end
    end

    if menu.pageRoots ~= nil then
        for frame, root in pairs(menu.pageRoots) do
            if root ~= nil and root.setVisible ~= nil then
                local want = (frame == current)
                if root.getIsVisible ~= nil then
                    local ok, vis = pcall(root.getIsVisible, root)
                    if not (ok and vis == want) then
                        pcall(root.setVisible, root, want)
                    end
                else
                    pcall(root.setVisible, root, want)
                end
            end
        end
    end
end

InGameMenuPageGuard.enforce = enforceSingleVisibleMenuPage

local function installStatisticsFrameMouseGuard()
    if InGameMenuStatisticsFrame == nil then return end
    if InGameMenuStatisticsFrame._rfMouseGuard then return end
    InGameMenuStatisticsFrame._rfMouseGuard = true

    if InGameMenuStatisticsFrame.mouseEvent ~= nil then
        InGameMenuStatisticsFrame.mouseEvent = Utils.overwrittenFunction(
            InGameMenuStatisticsFrame.mouseEvent,
            function(self, superFunc, posX, posY, isDown, isUp, button, eventUsed)
                local ok, ret = pcall(superFunc, self, posX, posY, isDown, isUp, button, eventUsed)
                if not ok then
                    SHLogger.debug("StatisticsFrame.mouseEvent suppressed: %s", tostring(ret))
                    local menu = g_gui and (g_gui.screenControllers[InGameMenu] or g_inGameMenu)
                    enforceSingleVisibleMenuPage(menu)
                    return eventUsed
                end
                return ret
            end
        )
    end

    for _, fname in ipairs({"onClickSubCategory", "onSubCategoryChanged", "onClickPaging"}) do
        if InGameMenuStatisticsFrame[fname] ~= nil then
            InGameMenuStatisticsFrame[fname] = Utils.appendedFunction(
                InGameMenuStatisticsFrame[fname],
                function(self, ...)
                    local menu = g_gui and (g_gui.screenControllers[InGameMenu] or g_inGameMenu)
                    enforceSingleVisibleMenuPage(menu)
                end
            )
        end
    end
end

function InGameMenuPageGuard.install()
    if InGameMenu == nil then return false end

    if not InGameMenu._rfPageVisibilityGuard then
        InGameMenu._rfPageVisibilityGuard = true
        -- Compat with SoilFertilizer's earlier local guard flag
        InGameMenu._sfPageVisibilityGuard = true

        if InGameMenu.onPageChange ~= nil then
            InGameMenu.onPageChange = Utils.overwrittenFunction(
                InGameMenu.onPageChange,
                function(self, superFunc, pageIndex, pageMappingIndex, element, skipTabVisualUpdate)
                    local ok, err = pcall(superFunc, self, pageIndex, pageMappingIndex, element, skipTabVisualUpdate)
                    if not ok then
                        SHLogger.warning("InGameMenu.onPageChange error (recovering page visibility): %s", tostring(err))
                    end
                    enforceSingleVisibleMenuPage(self)
                end
            )
        end

        if InGameMenu.onOpen ~= nil then
            InGameMenu.onOpen = Utils.appendedFunction(InGameMenu.onOpen, function(self)
                enforceSingleVisibleMenuPage(self)
            end)
        end

        if InGameMenu.goToPage ~= nil then
            InGameMenu.goToPage = Utils.appendedFunction(InGameMenu.goToPage, function(self)
                enforceSingleVisibleMenuPage(self)
            end)
        end

        SHLogger.info("InGameMenuPageGuard: single-page visibility guard installed")
    end

    if not InGameMenu._rfPageVisibilityDrawGuard then
        InGameMenu._rfPageVisibilityDrawGuard = true
        InGameMenu._sfPageVisibilityDrawGuard = true
        local drawName = (InGameMenu.draw ~= nil) and "draw" or ((InGameMenu.onDraw ~= nil) and "onDraw" or nil)
        if drawName ~= nil then
            InGameMenu[drawName] = Utils.appendedFunction(InGameMenu[drawName], function(self)
                enforceSingleVisibleMenuPage(self)
            end)
            SHLogger.info("InGameMenuPageGuard: draw-time page visibility guard installed")
        end
    end

    installStatisticsFrameMouseGuard()
    return true
end

function InGameMenuPageGuard.update(dt)
    if g_gui == nil then return end
    if not (g_gui.getIsGuiVisible and g_gui:getIsGuiVisible()) then return end
    if g_gui.currentGuiName ~= "InGameMenu" then return end
    local menu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
    enforceSingleVisibleMenuPage(menu)
end
