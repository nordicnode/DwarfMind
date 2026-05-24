-- DwarfMind reflex: monitor food/drink levels and auto-queue work orders.
-- Periodically checks food/drink counts, comparing them against safety buffers.
-- If levels are low, queues manager orders via the workorder script.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_production')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_production')

-- Production thresholds.
local MIN_DRINK = 50
local MIN_FOOD  = 30

-- Cooldown to prevent duplicate queueing of orders.
-- 6000 ticks is approx. 50 dwarf days.
local ACTION_COOLDOWN = 6000
local last_action = { drink = -math.huge, food = -math.huge }

function run()
    if not sensors.is_fort_loaded() then return end

    local stock, ok = sensors.check_stockpile_levels()
    if not ok then
        log.warn('check_stockpile_levels failed')
        return
    end

    local now = sensors.current_tick()

    -- 1. Check drink levels
    local drink_count = stock.drink or 0
    if drink_count < MIN_DRINK then
        log.warn(string.format('drink level low: %d (threshold %d)', drink_count, MIN_DRINK))
        if (now - last_action.drink) >= ACTION_COOLDOWN then
            log.info('queueing workorder to brew drinks')
            actuators.run_script('workorder', string.format('[{"job":"BrewDrink","amount_total":15}]'))
            last_action.drink = now
        end
    else
        log.debug(string.format('drink level healthy: %d', drink_count))
    end

    -- 2. Check food levels
    local food_count = stock.food or 0
    if food_count < MIN_FOOD then
        log.warn(string.format('food level low: %d (threshold %d)', food_count, MIN_FOOD))
        if (now - last_action.food) >= ACTION_COOLDOWN then
            log.info('queueing workorder to prepare meals')
            actuators.run_script('workorder', string.format('[{"job":"PrepareMeal","amount_total":10}]'))
            last_action.food = now
        end
    else
        log.debug(string.format('food level healthy: %d', food_count))
    end
end

function reset()
    last_action = { drink = -math.huge, food = -math.huge }
end

return _ENV
