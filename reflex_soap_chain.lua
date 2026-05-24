-- DwarfMind reflex: soap industry chain coordinator.
-- Monitors hospital and general inventory soap stocks (target = 10).
-- If soap is low, crawls and triggers the production pipeline:
--   Wood logs -> Burn Wood (MakeAsh) -> Make Lye (MakeLye) -> Make Soap (MakeSoap)
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_soap_chain')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_soap_chain')

-- Cooldown to avoid duplicate work orders.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

-- Buffer targets
local SOAP_TARGET = 10

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    -- 1. Get current soap and queued soap
    local hospital, hosp_ok = sensors.check_hospital_supplies()
    if not hosp_ok then
        log.warn('check_hospital_supplies failed')
        return
    end

    local current_soap = hospital.soap or 0
    local queued_soap = hospital.queued_soap or 0
    local soap_supply = current_soap + queued_soap

    log.info(string.format('soap status: stock = %d, queued = %d, total = %d',
        current_soap, queued_soap, soap_supply))

    if soap_supply >= SOAP_TARGET then
        log.debug('soap stock is healthy')
        return
    end

    local soap_deficit = SOAP_TARGET - soap_supply
    log.warn(string.format('soap stock low: %d (target %d) -> starting chain audit for %d soap(s)',
        soap_supply, SOAP_TARGET, soap_deficit))

    -- 2. Audit Lye and Ash
    local current_lye, lye_ok = sensors.get_lye_count()
    local current_ash, ash_ok = sensors.get_ash_count()
    local current_tallow, tallow_ok = sensors.get_tallow_oil_count()
    if not lye_ok or not ash_ok or not tallow_ok then
        log.warn('failed to check lye/ash/tallow counts')
        return
    end

    -- Count queued lye and ash orders
    local queued_lye = 0
    local queued_ash = 0
    local mgr_orders = df.global.world.manager_orders
    for o = 0, #mgr_orders - 1 do
        local order = mgr_orders[o]
        local jt = order.job_type
        if jt == df.job_type.MakeLye then
            queued_lye = queued_lye + order.amount_left
        elseif jt == df.job_type.MakeAsh then
            queued_ash = queued_ash + order.amount_left
        end
    end

    local lye_supply = current_lye + queued_lye
    local ash_supply = current_ash + queued_ash

    log.info(string.format('chain inventory: lye=%d (queued=%d), ash=%d (queued=%d), tallow/oil=%d',
        current_lye, queued_lye, current_ash, queued_ash, current_tallow))

    -- Check if we have enough tallow/oil to make the soap deficit
    if current_tallow == 0 then
        log.warn('CRITICAL: cannot make soap because tallow/oil stock is 0! (slaughtering livestock or pressing seeds needed)')
        return
    end

    local make_soap_amount = math.min(soap_deficit, current_tallow)
    
    -- Check if we have enough lye
    if lye_supply >= make_soap_amount then
        -- We have the lye and tallow/oil! Queue the MakeSoap job.
        log.warn(string.format('lye (%d) and tallow (%d) available -> queueing %d MakeSoap orders',
            lye_supply, current_tallow, make_soap_amount))
        actuators.run_script('workorder', 'MakeSoap', tostring(make_soap_amount))
        last_action = now
    else
        -- We need more lye!
        local lye_needed = make_soap_amount - lye_supply
        log.warn(string.format('lye supply low (%d/%d) -> checking ash to queue MakeLye', lye_supply, make_soap_amount))

        if ash_supply >= lye_needed then
            -- We have ash! Queue MakeLye at Ashery.
            log.warn(string.format('ash supply sufficient (%d) -> queueing %d MakeLye orders', ash_supply, lye_needed))
            actuators.run_script('workorder', 'MakeLye', tostring(lye_needed))
            last_action = now
        else
            -- We need more ash!
            local ash_needed = lye_needed - ash_supply
            log.warn(string.format('ash supply low (%d/%d) -> checking wood to queue MakeAsh', ash_supply, lye_needed))

            local stocks, stock_ok = sensors.check_stockpile_levels()
            local wood = stock_ok and (stocks.wood or 0) or 0

            if wood > 0 then
                local burn_amount = math.min(ash_needed, wood)
                log.warn(string.format('wood logs available (%d) -> queueing %d MakeAsh orders', wood, burn_amount))
                actuators.run_script('workorder', 'MakeAsh', tostring(burn_amount))
                last_action = now
            else
                log.warn('CRITICAL: ash/lye/soap chain stalled because wood log stock is 0!')
            end
        end
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
