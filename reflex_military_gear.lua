-- DwarfMind reflex: military gear & weapon forging.
-- Audits total active soldiers in squads, compares them against stockpiled and queued metal weapons/armor,
-- and automatically queues metal smithing orders via actuators to satisfy gear deficits.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_military_gear')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_military_gear')

-- Cooldown to avoid duplicate work orders.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end

    local status, ok = sensors.check_military_gear_status()
    if not ok then
        log.warn('check_military_gear_status failed')
        return
    end

    local soldiers = status.soldiers or 0
    if soldiers == 0 then
        log.debug('no soldiers assigned to squads; skipping gear check')
        return
    end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    local bars, bars_ok = sensors.get_metal_bars_stock()
    local metal = "INORGANIC:IRON" -- default fallback
    if bars_ok then
        if bars.steel > 0 then
            metal = "INORGANIC:STEEL"
        elseif bars.iron > 0 then
            metal = "INORGANIC:IRON"
        elseif bars.bronze > 0 then
            metal = "INORGANIC:BRONZE"
        elseif bars.copper > 0 then
            metal = "INORGANIC:COPPER"
        end
    end

    local function check_and_queue(name, count, queued, job_type)
        local total = count + queued
        local deficit = soldiers - total
        if deficit > 0 then
            log.warn(string.format('military gear deficit: %d soldiers active, but %s supply (stock=%d, queued=%d) is short by %d',
                soldiers, name, count, queued, deficit))
            actuators.run_script('workorder', string.format('[{"job":"%s","amount_total":%d,"material":"%s"}]', job_type, deficit, metal))
            return true
        end
        return false
    end

    local queued_any = false
    queued_any = check_and_queue('helmets',      status.helms,        status.queued_helms,        'MakeHelm') or queued_any
    queued_any = check_and_queue('breastplates', status.breastplates, status.queued_breastplates, 'MakeArmor') or queued_any
    queued_any = check_and_queue('greaves',      status.greaves,      status.queued_greaves,      'MakePants') or queued_any
    queued_any = check_and_queue('shields',      status.shields,      status.queued_shields,      'MakeShield') or queued_any
    queued_any = check_and_queue('weapons',      status.weapons,      status.queued_weapons,      'MakeWeapon') or queued_any

    if queued_any then
        last_action = now
    else
        log.debug(string.format('military gear sufficient for %d soldiers (helms=%d, armor=%d, pants=%d, shields=%d, weapons=%d)',
            soldiers, status.helms, status.breastplates, status.greaves, status.shields, status.weapons))
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
