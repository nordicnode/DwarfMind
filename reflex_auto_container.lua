-- DwarfMind reflex: auto-container manager.
-- Monitors stocks of empty barrels and rock pots.
-- If the empty container count falls below 10, queues wooden barrels (if logs are available)
-- or rock pots (if wood is low but stone is available) to keep the brewing industry running.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_auto_container')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_auto_container')

-- Cooldown to avoid spamming the manager queue.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

-- Target empty container buffer
local BUFFER_TARGET = 10

local function count_empty_containers()
    local barrels = 0
    local pots = 0
    local other = df.global.world.items.other

    -- Count empty barrels
    if other.BARREL then
        for b = 0, #other.BARREL - 1 do
            local it = other.BARREL[b]
            local f = it.flags
            if not f.forbid and not f.dump and not f.garbage_collect and not f.removed and not f.in_building then
                local contents = dfhack.items.getContainedItems(it)
                if contents and #contents == 0 then
                    barrels = barrels + 1
                end
            end
        end
    end

    -- Count empty rock pots (TOOL subtype ITEM_TOOL_LARGE_POT)
    if other.TOOL then
        for t = 0, #other.TOOL - 1 do
            local it = other.TOOL[t]
            local f = it.flags
            if not f.forbid and not f.dump and not f.garbage_collect and not f.removed and not f.in_building then
                local is_pot = false
                -- Use the vmethod it:getSubtype() -> int16 raws index.
                -- it.subtype is not a plain field on the base df.item type.
                local sub_idx = it:getSubtype()
                if sub_idx and sub_idx >= 0 then
                    pcall(function()
                        local tool_def = df.global.world.raws.itemdefs.tools[sub_idx]
                        if tool_def and tool_def.id == 'ITEM_TOOL_LARGE_POT' then
                            is_pot = true
                        end
                    end)
                end
                if is_pot then
                    local contents = dfhack.items.getContainedItems(it)
                    if contents and #contents == 0 then
                        pots = pots + 1
                    end
                end
            end
        end
    end

    return barrels, pots
end

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    -- 1. Count current empty containers in stockpiles
    local empty_barrels, empty_pots = count_empty_containers()
    local total_empty = empty_barrels + empty_pots

    -- 2. Count current queued container orders
    local queued_barrels = 0
    local queued_pots = 0
    local mgr_orders = df.global.world.manager_orders

    for o = 0, #mgr_orders - 1 do
        local order = mgr_orders[o]
        local jt = order.job_type
        if jt == df.job_type.MakeBarrel then
            queued_barrels = queued_barrels + order.amount_left
        elseif jt == df.job_type.MakeTool then
            local is_pot = false
            if order.item_subtype >= 0 then
                pcall(function()
                    local tool_def = df.global.world.raws.itemdefs.tools[order.item_subtype]
                    if tool_def and tool_def.id == 'ITEM_TOOL_LARGE_POT' then
                        is_pot = true
                    end
                end)
            end
            if is_pot then
                queued_pots = queued_pots + order.amount_left
            end
        end
    end

    local total_queued = queued_barrels + queued_pots
    local supply = total_empty + total_queued
    local deficit = BUFFER_TARGET - supply

    log.info(string.format('container status: empty barrels=%d, empty pots=%d (total empty=%d), queued barrels=%d, queued pots=%d. supply=%d, target=%d',
        empty_barrels, empty_pots, total_empty, queued_barrels, queued_pots, supply, BUFFER_TARGET))

    if deficit > 0 then
        log.warn(string.format('container deficit detected: supply %d is below target of %d; ordering %d containers',
            supply, BUFFER_TARGET, deficit))

        -- Check resources
        local stocks, stock_ok = sensors.check_stockpile_levels()
        local wood = stock_ok and (stocks.wood or 0) or 0

        -- Decide what to order: wooden barrels if wood is plentiful, otherwise rock pots
        if wood >= 15 then
            log.info(string.format('wood supply healthy (%d logs) -> queueing %d wooden barrel(s)', wood, deficit))
            actuators.run_script('workorder', string.format('[{"job":"MakeBarrel","amount_total":%d,"material_category":["wood"]}]', deficit))
        else
            log.info(string.format('wood supply low (%d logs) -> queueing %d stone large pot(s)', wood, deficit))
            actuators.run_script('workorder', string.format('[{"job":"MakeTool","item_subtype":"ITEM_TOOL_LARGE_POT","amount_total":%d,"material_category":["stone"]}]', deficit))
        end
        last_action = now
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
