-- DwarfMind reflex: Automated Metal Recycling coordinator.
-- Items flagged for melting (flags.melt == true) sit idle unless a
-- MeltMetalObject manager order is explicitly queued at a Smelter.
-- This reflex counts melt candidates and bridges the gap automatically.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_melt_coordinator')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_melt_coordinator')

local json = require('json')

local ACTION_COOLDOWN = 6000
local last_action     = -math.huge

-- Walk all world items checking flags.melt.
-- Scanning world.items.all is expensive; we cap at a reasonable scan window
-- and use a persistent offset to spread cost across ticks (round-robin).
local SCAN_WINDOW = 2000
local scan_offset = 0

local function count_melt_flagged()
    local all   = df.global.world.items.all
    local total = #all
    if total == 0 then return 0 end

    -- Clamp offset to valid range after any fortress reload / item count change.
    if scan_offset >= total then scan_offset = 0 end

    local count = 0
    local limit = math.min(scan_offset + SCAN_WINDOW, total)
    for i = scan_offset, limit - 1 do
        local item = all[i]
        if item and item.flags and item.flags.melt then
            count = count + 1
        end
    end

    -- Advance offset for next call (wraps on next run()).
    scan_offset = (limit >= total) and 0 or limit
    return count
end

-- Count active MeltMetalObject manager orders.
local function count_queued_melt_orders()
    local queued = 0
    local mgr_orders = df.global.world.manager_orders
    for o = 0, #mgr_orders - 1 do
        local order = mgr_orders[o]
        if order and order.job_type == df.job_type.MeltMetalObject then
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

    local melt_candidates = count_melt_flagged()
    if melt_candidates == 0 then
        log.debug('no items flagged for melting')
        return
    end

    local queued = count_queued_melt_orders()
    log.info(string.format(
        'melt status: flagged=%d, queued_orders=%d',
        melt_candidates, queued
    ))

    if queued >= melt_candidates then
        log.debug('melt orders already cover all flagged items')
        return
    end

    local deficit = melt_candidates - queued
    log.warn(string.format(
        'melt deficit: %d items flagged but only %d orders queued -> queueing %d MeltMetalObject',
        melt_candidates, queued, deficit
    ))

    actuators.run_script('workorder', json.encode({{
        job          = 'MeltMetalObject',
        amount_total = deficit,
    }}))

    last_action = now
end

function reset()
    last_action  = -math.huge
    scan_offset  = 0
end

return _ENV
