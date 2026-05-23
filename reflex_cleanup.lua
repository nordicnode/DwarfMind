-- DwarfMind reflex: claim forbidden rotting items/corpses to prevent miasma.
-- Scans subterranean, inside tiles of the fort for forbidden rotting remains.
-- Claims/unforbids them so haulers can safely clean them up.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_cleanup')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_cleanup')

-- Cooldown to avoid logging the same items continuously.
local ANNOUNCE_INTERVAL = 2000
local last_announce = {} -- [item_id] = tick

function run()
    if not sensors.is_fort_loaded() then return end

    local refuse, ok = sensors.get_rotting_refuse()
    if not ok then
        log.warn('get_rotting_refuse failed')
        return
    end

    if #refuse == 0 then
        log.debug('no rotting refuse inside fort')
        return
    end

    log.info(string.format('detected %d forbidden rotting item(s) inside the fort', #refuse))

    local now, tick_ok = sensors.current_tick()
    if tick_ok and now >= 0 then
        -- Prune expired entries to prevent memory leaks from deconstructed/disappeared refuse.
        for id, last in pairs(last_announce) do
            if (now - last) >= ANNOUNCE_INTERVAL then
                last_announce[id] = nil
            end
        end
    else
        now = 0
    end

    for _, it in ipairs(refuse) do
        local last = last_announce[it.id] or -math.huge
        if (now - last) >= ANNOUNCE_INTERVAL then
            log.warn(string.format('  unforbidding rotting refuse: item #%d @ (%d,%d,%d)',
                it.id, it.pos.x, it.pos.y, it.pos.z))
            
            actuators.unforbid_item(it)
            last_announce[it.id] = now
        end
    end
end

function reset()
    last_announce = {}
end

return _ENV
