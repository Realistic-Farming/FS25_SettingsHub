-- =========================================================
-- FS25_SettingsHub - Logger
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Mod-prefixed logging so lines are greppable by "[SettingsHub]".
-- =========================================================

SHLogger = SHLogger or {}
SHLogger.PREFIX = "[SettingsHub] "
SHLogger.debugEnabled = false

function SHLogger.info(msg, ...)
    if select("#", ...) > 0 then Logging.info(SHLogger.PREFIX .. msg, ...)
    else Logging.info(SHLogger.PREFIX .. msg) end
end

function SHLogger.warning(msg, ...)
    if select("#", ...) > 0 then Logging.warning(SHLogger.PREFIX .. msg, ...)
    else Logging.warning(SHLogger.PREFIX .. msg) end
end

function SHLogger.error(msg, ...)
    if select("#", ...) > 0 then Logging.error(SHLogger.PREFIX .. msg, ...)
    else Logging.error(SHLogger.PREFIX .. msg) end
end

function SHLogger.debug(msg, ...)
    if not SHLogger.debugEnabled then return end
    if select("#", ...) > 0 then Logging.info(SHLogger.PREFIX .. "[debug] " .. msg, ...)
    else Logging.info(SHLogger.PREFIX .. "[debug] " .. msg) end
end
