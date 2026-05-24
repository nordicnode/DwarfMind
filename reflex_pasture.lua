-- DwarfMind reflex: pasture management.
-- Checks for tame owned grazers that are not assigned to any pasture zone.
-- Automatically assigns them to the first Pen/Pasture zone using the C++ 'zone' command.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_pasture')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_pasture')

-- Cooldown to prevent spamming assignment commands.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end

    local unpastured, ok = sensors.get_unpastured_grazers()
    if not ok then
        log.warn('get_unpastured_grazers failed')
        return
    end

    if #unpastured == 0 then
        log.debug('all grazers properly pastured')
        return
    end

    -- Find pasture zones
    local pastures, past_ok = sensors.get_pasture_zones()
    if not past_ok then
        log.warn('get_pasture_zones failed')
        return
    end

    if #pastures == 0 then
        log.warn(string.format('WARNING: %d grazer(s) are unpastured and starving, but no Pen/Pasture zones exist! Please define one in-game.',
            #unpastured))
        return
    end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    -- Use the first pasture zone for assignment
    local pasture = pastures[1]
    log.warn(string.format('pasture audit: found %d unpastured grazer(s) -> assigning all grazers to Pen/Pasture zone #%d',
        #unpastured, pasture.id))

    -- Actuate assignment using the DFHack 'zone' plugin command (not a Lua script)
    actuators.run_command('zone', 'assign', tostring(pasture.id), 'all', 'own', 'grazer', 'unassigned')
    last_action = now
end

function reset()
    last_action = -math.huge
end

return _ENV
