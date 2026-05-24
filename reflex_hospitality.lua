-- DwarfMind reflex: Tavern Mug & Goblet Buffer.
-- Ensures free goblet/mug inventory stays above a safety threshold (10 items).
-- Dwarves suffer negative thoughts if forced to drink directly from barrels without a cup.
-- Prioritizes stone/wood mugs to avoid competing with reflex_military_gear for metal stocks.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_hospitality')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_hospitality')

local json = require('json')

local ACTION_COOLDOWN = 6000
local last_action     = -math.huge

local GOBLET_TARGET  = 10
-- Maximum number of mugs to order per cycle to stay within tick order budget.
local MAX_ORDER_BATCH = 5

-- Count free (on-ground, not forbidden/dumped/in-inventory) goblets and mugs.
local function count_free_goblets()
    local ok, err = pcall(function()
        -- sensors.is_fort_loaded() guard is checked by caller.
    end)
    local count = 0
    local goblets = df.global.world.items.other.GOBLET
    for i = 0, #goblets - 1 do
        local item = goblets[i]
        -- Nil-guard every pointer step (Rule C).
        if item and item.flags then
            local f = item.flags
            if f.on_ground
                and not f.forbid
                and not f.dump
                and not f.in_inventory
                and not f.owned
            then
                count = count + 1
            end
        end
    end
    return count
end

-- Count queued MakeGoblet / MakeTool (stone mug) manager orders.
local function count_queued_goblet_orders()
    local queued = 0
    local mgr_orders = df.global.world.manager_orders
    for o = 0, #mgr_orders - 1 do
        local order = mgr_orders[o]
        if order then
            local jt = order.job_type
            if jt == df.job_type.MakeGoblet or jt == df.job_type.MakeTool then
                queued = queued + (order.amount_left or 0)
            end
        end
    end
    return queued
end

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    local free_goblets = count_free_goblets()
    local queued       = count_queued_goblet_orders()
    local effective    = free_goblets + queued

    log.info(string.format(
        'goblet status: free=%d, queued=%d, effective=%d (target=%d)',
        free_goblets, queued, effective, GOBLET_TARGET
    ))

    if effective >= GOBLET_TARGET then
        log.debug('goblet/mug stock is healthy')
        return
    end

    local deficit = GOBLET_TARGET - effective
    local order_amount = math.min(deficit, MAX_ORDER_BATCH)

    log.warn(string.format(
        'goblet stock low: effective=%d (target=%d) -> queuing %d MakeGoblet (stone/wood)',
        effective, GOBLET_TARGET, order_amount
    ))

    -- Prefer stone mugs (MakeGoblet maps to the stone/wood goblet reaction).
    -- material_category restricts to non-metal to avoid competing with military gear.
    actuators.run_script('workorder', json.encode({{
        job              = 'MakeGoblet',
        amount_total     = order_amount,
        material_category = { stone = true, wood = true },
    }}))

    last_action = now
end

function reset()
    last_action = -math.huge
end

return _ENV
