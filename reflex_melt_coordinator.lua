-- DwarfMind reflex: Automated Metal Recycling coordinator.
-- Items flagged for melting (flags.melt == true) sit idle unless a
-- MeltMetalObject manager order is explicitly queued at a Smelter.
-- This reflex counts melt candidates and bridges the gap automatically.
--
-- Scan strategy: world.items.all is expensive to walk in full; we use a
-- round-robin window (SCAN_WINDOW items per slow-tick call) and accumulate
-- a running total across windows.  The action step fires only once the
-- offset wraps back to 0, meaning a complete pass over the item vector has
-- finished.  This prevents the partial-window vs. global-queue mismatch
-- where a single-window count was compared against the entire manager queue
-- and silently skipped items in unscanned windows.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_melt_coordinator')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_melt_coordinator')

local json = require('json')

local ACTION_COOLDOWN = 6000
local last_action     = -math.huge

local SCAN_WINDOW           = 2000   -- items scanned per slow-tick call
local scan_offset           = 0      -- round-robin cursor across world.items.all
local accumulated_candidates = 0     -- running total across windows within one sweep

-- Scan the next SCAN_WINDOW items from world.items.all, count melt-flagged
-- items, and advance the round-robin offset.
-- Returns the window count AND a boolean indicating whether this call
-- completed a full revolution (scan_offset wrapped to 0).
local function count_melt_flagged()
    local all   = df.global.world.items.all
    local total = #all
    if total == 0 then
        scan_offset = 0
        return 0, true  -- empty vector counts as a completed sweep
    end

    -- Clamp offset after a fortress reload or item vector shrink.
    if scan_offset >= total then scan_offset = 0 end

    local count = 0
    local limit = math.min(scan_offset + SCAN_WINDOW, total)
    for i = scan_offset, limit - 1 do
        local item = all[i]
        if item and item.flags and item.flags.melt then
            count = count + 1
        end
    end

    local wrapped
    if limit >= total then
        scan_offset = 0
        wrapped     = true
    else
        scan_offset = limit
        wrapped     = false
    end
    return count, wrapped
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

    -- Advance the scan window and accumulate this window's count.
    local window_count, sweep_complete = count_melt_flagged()
    accumulated_candidates = accumulated_candidates + window_count

    -- Only evaluate the action step when a full sweep across world.items.all
    -- has completed.  Comparing a partial window count against the global
    -- manager queue would cause the reflex to falsely conclude all items are
    -- already covered and silently skip the unscanned remainder.
    if not sweep_complete then
        log.debug(string.format(
            'melt scan window: +%d this pass, %d accumulated, sweep not yet complete',
            window_count, accumulated_candidates
        ))
        return
    end

    local total_candidates   = accumulated_candidates
    accumulated_candidates   = 0   -- reset for the next full sweep

    if total_candidates == 0 then
        log.debug('melt sweep complete: no items flagged for melting')
        return
    end

    local queued = count_queued_melt_orders()
    log.info(string.format(
        'melt sweep complete: flagged=%d, queued_orders=%d',
        total_candidates, queued
    ))

    if queued >= total_candidates then
        log.debug('melt orders already cover all flagged items')
        return
    end

    local deficit = total_candidates - queued
    log.warn(string.format(
        'melt deficit: %d items flagged, %d orders queued -> queueing %d MeltMetalObject',
        total_candidates, queued, deficit
    ))

    actuators.run_script('workorder', json.encode({{
        job          = 'MeltMetalObject',
        amount_total = deficit,
    }}))

    last_action = now
end

function reset()
    last_action           = -math.huge
    scan_offset           = 0
    accumulated_candidates = 0   -- clear mid-sweep state on fortress reload
end

return _ENV
