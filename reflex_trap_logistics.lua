-- DwarfMind reflex: Engineering & Mechanism Buffer.
-- Mechanisms (TRAPPARTS) are required for levers, floodgates, traction benches,
-- and target traps. Running out stalls reflex_defense and reflex_hydrology.
-- Maintains a minimum reserve of 5 free mechanisms via ConstructMechanism orders.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_trap_logistics')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_trap_logistics')

local json = require('json')

local ACTION_COOLDOWN = 6000
local last_action     = -math.huge

local MECHANISM_FLOOR = 5
local MAX_ORDER_BATCH = 4

-- Count free (on-ground, not forbidden/dumped/in-inventory) TRAPPARTS.
local function count_free_mechanisms()
    local count = 0
    local parts = df.global.world.items.other.TRAPPARTS
    for i = 0, #parts - 1 do
        local item = parts[i]
        if item and item.flags then
            local f = item.flags
            if f.on_ground
                and not f.forbid
                and not f.dump
                and not f.in_inventory
            then
                count = count + 1
            end
        end
    end
    return count
end

-- Count queued ConstructMechanism manager orders.
local function count_queued_mechanism_orders()
    local queued = 0
    local mgr_orders = df.global.world.manager_orders
    for o = 0, #mgr_orders - 1 do
        local order = mgr_orders[o]
        if order and order.job_type == df.job_type.ConstructMechanism then
            queued = queued + (order.amount_left or 0)
        end
    end
    return queued
end

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    local free_mechs   = count_free_mechanisms()
    local queued       = count_queued_mechanism_orders()
    local effective    = free_mechs + queued

    log.info(string.format(
        'mechanism status: free=%d, queued=%d, effective=%d (floor=%d)',
        free_mechs, queued, effective, MECHANISM_FLOOR
    ))

    if effective >= MECHANISM_FLOOR then
        log.debug('mechanism stock is above reserve floor')
        return
    end

    local deficit      = MECHANISM_FLOOR - effective
    local order_amount = math.min(deficit, MAX_ORDER_BATCH)

    log.warn(string.format(
        'mechanism reserve low: effective=%d (floor=%d) -> queueing %d ConstructMechanism (stone)',
        effective, MECHANISM_FLOOR, order_amount
    ))

    actuators.run_script('workorder', json.encode({{
        job               = 'ConstructMechanism',
        amount_total      = order_amount,
        material_category = { stone = true },
    }}))

    last_action = now
end

function reset()
    last_action = -math.huge
end

return _ENV
