-- Structured console logging for DwarfMind.
-- Loadable as a module via reqscript('dwarfmind/logger').
--@ module = true

local _ENV = mkmodule('dwarfmind/logger')

-- ─── Levels ──────────────────────────────────────────────────────────────
LEVEL = {
    DEBUG = 1,
    INFO  = 2,
    WARN  = 3,
    ERROR = 4,
}

local LEVEL_NAMES = { [1]='DEBUG', [2]='INFO ', [3]='WARN ', [4]='ERROR' }

-- Default visible threshold. Can be raised to LEVEL.WARN in release,
-- lowered to LEVEL.DEBUG when chasing a bug.
threshold = LEVEL.INFO

-- ─── Internal formatter ──────────────────────────────────────────────────
-- Build a "[tick=NNN] [LEVEL] [tag] message" line.
-- We use df.global.world.frame_counter when available; fall back to "?"
-- so logging works even before the world is loaded.
local function fmt(level, tag, msg)
    local tick = '?'
    local ok, fc = pcall(function() return df.global.world.frame_counter end)
    if ok and type(fc) == 'number' then tick = tostring(fc) end
    return string.format('[dwarfmind tick=%s %s %s] %s',
        tick, LEVEL_NAMES[level] or '?    ', tag or '-', msg or '')
end

local function emit(level, tag, msg)
    if level < threshold then return end
    local line = fmt(level, tag, msg)
    -- DFHack convention: warnings/errors go to printerr (red); info to print.
    if level >= LEVEL.WARN then
        dfhack.printerr(line)
    else
        print(line)
    end
end

-- ─── Public API ──────────────────────────────────────────────────────────
function set_threshold(level)
    threshold = level
end

function debug(tag, msg) emit(LEVEL.DEBUG, tag, msg) end
function info (tag, msg) emit(LEVEL.INFO , tag, msg) end
function warn (tag, msg) emit(LEVEL.WARN , tag, msg) end
function err  (tag, msg) emit(LEVEL.ERROR, tag, msg) end

-- Convenience: tagged logger bound to a single module name.
-- usage:  local log = require_logger('reflex_idle')
--         log.info('saw 3 idle dwarves')
function for_module(tag)
    return {
        debug = function(m) emit(LEVEL.DEBUG, tag, m) end,
        info  = function(m) emit(LEVEL.INFO , tag, m) end,
        warn  = function(m) emit(LEVEL.WARN , tag, m) end,
        err   = function(m) emit(LEVEL.ERROR, tag, m) end,
    }
end

return _ENV
