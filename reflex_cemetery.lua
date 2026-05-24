-- DwarfMind reflex: tomb & coffin automation.
-- Periodically checks dead citizen counts, counts empty unplaced coffins and queued orders.
-- Queues ConstructCoffin work orders if there is a deficit.
-- Runs the built-in 'burial' script to automatically zone placed coffins as tombs.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_cemetery')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_cemetery')

-- Cooldown to avoid spamming work order creation / script invocation.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end

    local status, ok = sensors.check_cemetery_status()
    if not ok then
        log.warn('check_cemetery_status failed')
        return
    end

    local unburied = status.unburied_citizens or 0
    local unplaced = status.unplaced_coffins or 0
    local queued   = status.queued_coffins or 0

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    -- 1. Coffin production deficit: we want to ensure we have at least enough
    -- constructed/queued coffins to bury all currently unburied dead.
    local supply = unplaced + queued
    local deficit = unburied - supply

    if deficit > 0 then
        log.warn(string.format('cemetery deficit: %d unburied dead, but coffin supply (stock=%d, queued=%d) is short by %d',
            unburied, unplaced, queued, deficit))
        log.info(string.format('queueing workorder to construct %d coffin(s)', deficit))
        actuators.run_script('workorder', string.format('[{"job":"ConstructCoffin","amount_total":%d,"material_category":["wood","stone"]}]', deficit))
        last_action = now
    else
        log.debug(string.format('coffin supply sufficient: unburied=%d, supply=%d', unburied, supply))
    end

    -- 2. Auto-burial: run the DFHack 'burial' script with the '-c' (citizens-only) flag
    -- to automatically convert placed, unowned coffins into tomb zones.
    if unburied > 0 then
        log.info('unburied dead present; running burial auto-zoner script')
        actuators.run_script('burial', '-c')
        last_action = now
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
