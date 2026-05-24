-- DwarfMind reflex: monitor hospital zones for critically low surgery supplies.
-- The four items most frequently missing from infirmaries — sutures (thread),
-- crutches, plaster powder, and buckets — each have their own minimum threshold.
-- When any falls below its threshold a manager work order is queued.
-- A per-supply cooldown prevents order flooding across consecutive slow ticks.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_infirmary_supply')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_infirmary_supply')

-- Minimum acceptable count of each supply type across ALL hospital zones
-- combined. If the total falls below this, queue an order.
local SUPPLY_MINIMUMS = {
    sutures = 5,   -- THREAD items stored in the hospital
    crutches = 3,  -- CRUTCH items
    plaster  = 3,  -- POWDER_MISC subtype PLASTER_POWDER
    buckets  = 2,  -- BUCKET items
}

-- Manager order job types and their item-type discriminators.
-- job_type values are strings accepted by actuators.add_manager_order.
--
-- Suture note: DF sutures are raw THREAD items used directly from the hospital
-- stockpile. The upstream production chain is:
--   ProcessPlants  (plant → plant thread)  <-- we order this
--   SpinThread     (plant thread → cloth thread) -- only needed for cloth, NOT sutures
-- We order ProcessPlants so that raw fiber is converted to usable thread.
-- If the fort has no spinnable plants, the order will queue but not complete;
-- the player must ensure a farming/gathering supply of plant material.
local SUPPLY_ORDERS = {
    sutures  = { job = 'ProcessPlants',    quantity = 5  },
    crutches = { job = 'ConstructCrutch',  quantity = 3  },
    plaster  = { job = 'MakePlaster',      quantity = 3  },
    buckets  = { job = 'ConstructBucket',  quantity = 2  },
}

-- How many ticks before we re-order the same supply type.
local ORDER_COOLDOWN = 7200  -- ~6 dwarf days between re-orders

-- Per-supply cooldown table: [supply_key] = last_order_tick
local last_order = {}

-- ─── Item counting helpers ────────────────────────────────────────────────────

-- Returns true when `item` is a thread/suture item.
local function is_suture(item)
    return item:getType() == df.item_type.THREAD
end

-- Returns true when `item` is a crutch.
local function is_crutch(item)
    return item:getType() == df.item_type.CRUTCH
end

-- Returns true when `item` is plaster powder.
local function is_plaster(item)
    if item:getType() ~= df.item_type.POWDER_MISC then return false end
    local mat = dfhack.matinfo.decode(item)
    if not mat then return false end
    return mat.material and mat.material.id == 'PLASTER_POWDER'
end

-- Returns true when `item` is a bucket.
local function is_bucket(item)
    return item:getType() == df.item_type.BUCKET
end

-- Count items of each supply type that exist anywhere in a hospital zone's
-- storage by iterating df.global.world.items.all and checking whether the
-- item's map position is inside any hospital building's bounding box.
-- This is the most portable approach and does not rely on DFHack stockpile
-- APIs that may differ between DF versions.
local function count_hospital_supplies()
    local counts = { sutures = 0, crutches = 0, plaster = 0, buckets = 0 }

    -- Collect hospital zone bounding boxes.
    local hospitals = {}
    for _, bld in ipairs(df.global.world.buildings.all) do
        if bld:getType() == df.building_type.Civzone then
            local zone = bld --[[@as df.building_civzonest]]
            if zone.zone_flags.hospital then
                hospitals[#hospitals + 1] = {
                    x1 = zone.x1, y1 = zone.y1, z = zone.z,
                    x2 = zone.x2, y2 = zone.y2,
                }
            end
        end
    end

    if #hospitals == 0 then
        log.debug('no hospital zones found; skipping infirmary supply check')
        return counts, false
    end

    -- Helper: is item position inside any hospital?
    local function in_hospital(item)
        local pos = item.pos
        if not pos then return false end
        for _, h in ipairs(hospitals) do
            if pos.z == h.z
               and pos.x >= h.x1 and pos.x <= h.x2
               and pos.y >= h.y1 and pos.y <= h.y2 then
                return true
            end
        end
        return false
    end

    -- Scan all world items. Skip items that are:
    --   in_inventory  — held by a unit (unit-carried medical supplies)
    --   in_chest      — stored inside a chest/coffer within the zone
    --   in_bin        — stored inside a bin within the zone
    -- Excluding these prevents double-counting (the container itself is already
    -- outside the hospital bounding box scan, but its contents share the
    -- container's position) and avoids counting supplies mid-surgery.
    for _, item in ipairs(df.global.world.items.all) do
        if item
           and not item.flags.garbage_collect
           and not item.flags.in_inventory
           and not item.flags.in_chest
           and not item.flags.in_bin
        then
            if in_hospital(item) then
                if     is_suture(item)  then counts.sutures  = counts.sutures  + 1
                elseif is_crutch(item)  then counts.crutches = counts.crutches + 1
                elseif is_plaster(item) then counts.plaster  = counts.plaster  + 1
                elseif is_bucket(item)  then counts.buckets  = counts.buckets  + 1
                end
            end
        end
    end

    return counts, true
end

-- ─── Main run ───────────────────────────────────────────────────────────────

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end

    -- Prune stale cooldown entries.
    for key, last in pairs(last_order) do
        if (now - last) >= ORDER_COOLDOWN then
            last_order[key] = nil
        end
    end

    local counts, ok = count_hospital_supplies()
    if not ok then return end  -- no hospitals; nothing to do

    log.debug(string.format(
        'hospital supplies: sutures=%d crutches=%d plaster=%d buckets=%d',
        counts.sutures, counts.crutches, counts.plaster, counts.buckets))

    for key, minimum in pairs(SUPPLY_MINIMUMS) do
        local have = counts[key] or 0
        if have < minimum then
            local last = last_order[key] or -math.huge
            if (now - last) >= ORDER_COOLDOWN then
                local order = SUPPLY_ORDERS[key]
                log.warn(string.format(
                    'infirmary supply LOW: %s=%d (min %d); queueing %d x %s',
                    key, have, minimum, order.quantity, order.job))

                local ok_act, err_act = dfhack.pcall(function()
                    actuators.add_manager_order(
                        order.job, order.quantity)
                end)
                if ok_act then
                    last_order[key] = now
                else
                    log.warn(string.format(
                        'add_manager_order failed for %s: %s',
                        key, tostring(err_act)))
                end
            else
                log.debug(string.format(
                    '%s supply low but order cooldown active; skipping', key))
            end
        end
    end
end

function reset()
    last_order = {}
end

return _ENV
