-- DwarfMind reflex: auto-mark finished goods and gems for trade when merchants arrive.
-- Detects caravans AtDepot, locates the active Trade Depot, and selects cut gems
-- and finished goods (crafts) to porter to the depot.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_trade')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_trade')

-- Cooldown to avoid continuous portering designations.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

-- Item types we consider finished goods/gems for trade.
local TRADE_GOOD_VECTORS = {
    'FIGURINE',
    'AMULET',
    'BRACELET',
    'RING',
    'EARRING',
    'CROWN',
    'SCEPTER',
    'GOBLET',
    'SMALLGEM',
    'TOY',
    'INSTRUMENT',
}

function run()
    if not sensors.is_fort_loaded() then return end

    local caravans, car_ok = sensors.get_active_caravans()
    if not car_ok or #caravans == 0 then return end

    local merchant_ready = false
    for _, car in ipairs(caravans) do
        if car.trade_state == df.caravan_state.T_trade_state.AtDepot then
            merchant_ready = true
            break
        end
    end

    if not merchant_ready then
        log.debug('caravan present but not yet at depot/ready to trade')
        return
    end

    local depot, depot_ok = sensors.get_active_depot()
    if not depot_ok or not depot then
        log.warn('active caravan detected but no active Trade Depot found!')
        return
    end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    log.warn('merchants are ready to trade; starting auto-porter check for trade goods')

    -- Scan for candidates to mark for trade.
    local other = df.global.world.items.other
    local marked_count = 0

    for _, vec_name in ipairs(TRADE_GOOD_VECTORS) do
        local vec = other[vec_name]
        if vec then
            for v = 0, #vec - 1 do
                local it = vec[v]
                local f = it.flags
                -- Must be free, on the ground, not forbidden/dumped, and not already at the depot.
                if f.on_ground 
                   and not f.forbid 
                   and not f.dump 
                   and not f.in_job 
                   and not f.in_building 
                   and dfhack.items.getHolderBuilding(it) ~= depot then
                    
                    local success = actuators.mark_item_for_trade(it, depot)
                    if success then
                        marked_count = marked_count + 1
                    end
                end
            end
        end
    end

    if marked_count > 0 then
        log.info(string.format('auto-porter: marked %d item(s) for trade at depot #%d', marked_count, depot.id))
        last_action = now
    else
        log.debug('no trade goods candidates found to port')
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
