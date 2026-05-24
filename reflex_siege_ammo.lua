-- DwarfMind reflex: ammunition and siege ammo logistics.
-- Audits squad sizes against stockpiled and queued bolts/arrows and siege ammunition.
-- Automatically queues MakeAmmo and AssembleSiegeAmmo work orders via actuators
-- when deficits exist, using the dominant metal bar type available.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_siege_ammo')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_siege_ammo')

-- Minimum ammo per soldier (e.g. 25 rounds per ranged dwarf).
local AMMO_PER_SOLDIER = 25

-- Flat minimum siege ammo to maintain regardless of soldier count.
local MIN_SIEGE_AMMO = 20

-- Cooldown to avoid duplicate work orders.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end

    local status, ok = sensors.check_ammo_status()
    if not ok then
        log.warn('check_ammo_status failed')
        return
    end

    local soldiers = status.soldiers or 0
    if soldiers == 0 then
        log.debug('no soldiers assigned to squads; skipping ammo check')
        return
    end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    -- Determine dominant metal for ammo forging
    local bars, bars_ok = sensors.get_metal_bars_stock()
    local metal = "INORGANIC:IRON"
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

    local queued_any = false

    -- 1. Standard ammo deficit
    local ammo_total = (status.ammo or 0) + (status.queued_ammo or 0)
    local ammo_target = soldiers * AMMO_PER_SOLDIER
    local ammo_deficit = ammo_target - ammo_total
    if ammo_deficit > 0 then
        log.warn(string.format('ammo deficit: %d soldiers active, ammo stock=%d, queued=%d, target=%d -> short by %d',
            soldiers, status.ammo, status.queued_ammo, ammo_target, ammo_deficit))
        actuators.run_script('workorder', string.format('[{"job":"MakeAmmo","amount_total":%d,"material":"%s"}]',
            ammo_deficit, metal))
        queued_any = true
    end

    -- 2. Siege ammo deficit
    local siege_total = (status.siege_ammo or 0) + (status.queued_siege or 0)
    local siege_deficit = MIN_SIEGE_AMMO - siege_total
    if siege_deficit > 0 then
        log.warn(string.format('siege ammo deficit: stock=%d, queued=%d, target=%d -> short by %d',
            status.siege_ammo, status.queued_siege, MIN_SIEGE_AMMO, siege_deficit))
        actuators.run_script('workorder', string.format('[{"job":"AssembleSiegeAmmo","amount_total":%d,"material":"%s"}]',
            siege_deficit, metal))
        queued_any = true
    end

    if queued_any then
        last_action = now
    else
        log.debug(string.format('ammo stock sufficient: ammo=%d/%d, siege=%d/%d (soldiers=%d)',
            ammo_total, ammo_target, siege_total, MIN_SIEGE_AMMO, soldiers))
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
