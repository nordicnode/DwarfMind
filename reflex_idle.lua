-- MVP reflex: announce idle citizens to the console.
-- This is the simplest possible Sense→Think→Act loop: sense who is
-- idle, decide "nothing to do but log it", act by writing to the console.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_idle')

local sensors = reqscript('dwarfmind/sensors')
local logger  = reqscript('dwarfmind/logger')
local log     = logger.for_module('reflex_idle')

-- Cooldown so we don't spam the console with the same names every cycle.
-- Re-announce a given unit at most once per ANNOUNCE_INTERVAL ticks.
-- Each entry stores {tick=N, hist_id=N, birth=N} — both hist_id and
-- birth_year are compared so we catch ID recycling even when migrants
-- haven't yet been linked to history (hist_figure_id = -1 for both).
local ANNOUNCE_INTERVAL = 1000
local last_announce = {} -- [unit_id] = {tick=N, hist_id=N, birth=N}

-- One reflex cycle. Returns the number of idle citizens detected.
function run()
    if not sensors.is_fort_loaded() then return 0 end

    local idle, ok = sensors.get_idle_dwarves()
    if not ok then
        log.warn('get_idle_dwarves failed')
        return 0
    end
    local now = sensors.current_tick()

    if #idle == 0 then
        log.debug('no idle citizens')
        return 0
    end

    log.info(string.format('detected %d idle citizen(s)', #idle))

    for _, u in ipairs(idle) do
        local entry = last_announce[u.id]
        -- Discard stale entry if the unit ID was recycled.  Compare both
        -- hist_figure_id and birth_year: two fresh migrants can both have
        -- hist_figure_id == -1 before DF links them to history, so
        -- hist_id alone isn't enough.
        if entry and (entry.hist_id ~= u.hist_figure_id or entry.birth ~= u.birth_year) then
            entry = nil
        end
        local last_tick = entry and entry.tick or -math.huge
        if (now - last_tick) >= ANNOUNCE_INTERVAL then
            log.info('  idle: ' .. sensors.describe_unit(u))
            last_announce[u.id] = {tick=now, hist_id=u.hist_figure_id, birth=u.birth_year}
        end
    end
    return #idle
end

-- For tests / hot reloading: clear the cooldown table.
function reset()
    last_announce = {}
end

return _ENV
