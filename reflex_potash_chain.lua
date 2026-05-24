-- DwarfMind reflex: Agricultural Yield Enhancer / Potash chain coordinator.
-- Extends reflex_farming and reflex_soap_chain industrial pipelines.
-- Ensures farm plots are fertilizable by maintaining Potash stocks.
-- Dependency chain:  Wood logs -> MakeAsh -> MakePotash (at Ashery).
-- Coordinates with reflex_soap_chain for shared Ash and Wood resources.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_potash_chain')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_potash_chain')

local json = require('json')

local ACTION_COOLDOWN = 6000
local last_action     = -math.huge

local POTASH_TARGET = 5   -- Enough potash to fertilize a growing season.
local ASH_FLOOR     = 3   -- Reserve ash so soap chain is not fully starved.

-- Count actual potash items using material-token validation.
-- FIX: the previous implementation used count_items_other('POWDER_MISC') which
-- counted *all* powder items (sand, lye, ash, gypsum plaster, flour, sugar,
-- dye powders, etc.) as potash, inflating the supply reading and causing the
-- reflex to silently skip MakePotash orders.  We now decode each item's
-- material info and match only INORGANIC:POTASH.
local function count_actual_potash()
    local list = df.global.world.items.other.POWDER_MISC
    if not list then return 0 end
    local count = 0
    for i = 0, #list - 1 do
        local item = list[i]
        if item and item.flags
            and not item.flags.forbid
            and not item.flags.dump
            and not item.flags.in_inventory
        then
            -- dfhack.matinfo.decode returns a table with a 'token' field of the
            -- form 'CATEGORY:NAME' (e.g. 'INORGANIC:POTASH').
            local mat_info = dfhack.matinfo.decode(item)
            if mat_info and mat_info.token == 'INORGANIC:POTASH' then
                count = count + 1
            end
        end
    end
    return count
end

-- Count items by token in world.items.other sub-vector (used for ash).
local function count_items_other(token)
    local list = df.global.world.items.other[token]
    if not list then return 0 end
    local count = 0
    for i = 0, #list - 1 do
        local item = list[i]
        if item and item.flags then
            local f = item.flags
            if not f.forbid and not f.dump and not f.in_inventory then
                count = count + 1
            end
        end
    end
    return count
end

-- Check whether any underground FarmPlot building exists (fertilizable).
-- We query df.global.world.buildings.other.FARMPLOT and look for subterranean
-- plots (z below the sky layer is inferable from building flags / map data;
-- for simplicity we count any active farm plot as a fertilization candidate).
local function has_active_farm_plots()
    local plots = df.global.world.buildings.other.FARMPLOT
    if not plots then return false end
    for i = 0, #plots - 1 do
        local b = plots[i]
        if b then return true end
    end
    return false
end

-- Count queued manager orders of a given job_type token string.
local function count_queued_orders(job_type_token)
    local queued     = 0
    local jt_enum    = df.job_type[job_type_token]
    local mgr_orders = df.global.world.manager_orders
    for o = 0, #mgr_orders - 1 do
        local order = mgr_orders[o]
        if order and order.job_type == jt_enum then
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

    -- Only act if there are actual farm plots to fertilize.
    if not has_active_farm_plots() then
        log.debug('no active farm plots found; skipping potash chain')
        return
    end

    -- 1. Count potash stock using exact material-token matching.
    local current_potash = count_actual_potash()
    local queued_potash  = count_queued_orders('MakePotash')
    local potash_supply  = current_potash + queued_potash

    log.info(string.format(
        'potash: stock=%d, queued=%d, supply=%d (target=%d)',
        current_potash, queued_potash, potash_supply, POTASH_TARGET
    ))

    if potash_supply >= POTASH_TARGET then
        log.debug('potash supply is healthy')
        return
    end

    local potash_deficit = POTASH_TARGET - potash_supply
    log.warn(string.format(
        'potash low: supply=%d (target=%d) -> need %d more',
        potash_supply, POTASH_TARGET, potash_deficit
    ))

    -- 2. Audit Ash supply.
    local current_ash, ash_ok = sensors.get_ash_count()
    if not ash_ok then
        log.warn('get_ash_count() failed; aborting potash chain')
        return
    end
    local queued_ash = count_queued_orders('MakeAsh')
    local ash_supply = current_ash + queued_ash

    log.info(string.format(
        'ash: stock=%d, queued=%d, supply=%d',
        current_ash, queued_ash, ash_supply
    ))

    -- Leave ASH_FLOOR units of ash so soap chain can still make lye.
    local ash_available_for_potash = math.max(0, ash_supply - ASH_FLOOR)

    if ash_available_for_potash >= potash_deficit then
        -- Ash is sufficient; queue MakePotash at Ashery.
        log.warn(string.format(
            'ash available (%d spare) -> queueing %d MakePotash',
            ash_available_for_potash, potash_deficit
        ))
        actuators.run_script('workorder', json.encode({{
            job          = 'MakePotash',
            amount_total = potash_deficit,
        }}))
        last_action = now
    else
        -- Need more ash; coordinate with soap chain by burning wood.
        local ash_needed = potash_deficit - ash_available_for_potash
        log.warn(string.format(
            'ash too low for potash (spare=%d, needed=%d) -> checking wood stock',
            ash_available_for_potash, ash_needed
        ))

        local stocks, stock_ok = sensors.check_stockpile_levels()
        local wood = stock_ok and (stocks.wood or 0) or 0

        if wood > 0 then
            -- Burn only what is needed; soap chain will use its own MakeAsh pass.
            local burn_amount = math.min(ash_needed, wood)
            log.warn(string.format(
                'wood available (%d) -> queueing %d MakeAsh for potash pipeline',
                wood, burn_amount
            ))
            actuators.run_script('workorder', json.encode({{
                job          = 'MakeAsh',
                amount_total = burn_amount,
            }}))
            last_action = now
        else
            log.warn('CRITICAL: potash chain stalled — ash supply low and wood stock is 0!')
        end
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
