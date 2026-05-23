-- DwarfMind reflex: hospital/medical supplies & noble monitoring.
-- Monitors hospital supply stock buffers and Chief Medical Dwarf office.
-- Queues ConstructSplint, ConstructCrutch, MakeSoap, PrepareGypsumPlaster, and ConstructBucket
-- work orders via actuators when levels drop below thresholds.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_medical')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_medical')

-- Minimum target buffers for each supply.
local BUFFER_TARGET = 5

-- Cooldown to prevent spamming work order creation.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end

    -- 1. Check Chief Medical Dwarf noble office
    local cmd, cmd_ok = sensors.get_noble_unit('CHIEF_MEDICAL_DWARF')
    if cmd_ok and not cmd then
        log.warn('CRITICAL: Chief Medical Dwarf position is vacant! Hospital diagnostic reports and health screening disabled.')
    elseif cmd_ok and cmd then
        log.debug(string.format('Chief Medical Dwarf is assigned: %s', dfhack.units.getReadableName(cmd)))
    end

    -- 2. Audit hospital supplies
    local stock, ok = sensors.check_hospital_supplies()
    if not ok then
        log.warn('check_hospital_supplies failed')
        return
    end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    local function check_and_queue(name, count, queued, job_type)
        local total = count + queued
        local deficit = BUFFER_TARGET - total
        if deficit > 0 then
            log.warn(string.format('hospital supplies: %s low (stock=%d, queued=%d) -> queueing %d more',
                name, count, queued, deficit))
            if job_type == 'ConstructSplint' or job_type == 'ConstructCrutch' or job_type == 'ConstructBucket' then
                actuators.run_script('workorder', string.format('[{"job":"%s","amount_total":%d,"material_category":["wood"]}]', job_type, deficit))
            else
                actuators.run_script('workorder', job_type, tostring(deficit))
            end
            return true
        end
        return false
    end

    local res1 = check_and_queue('splints', stock.splints, stock.queued_splints, 'ConstructSplint')
    local res2 = check_and_queue('crutches', stock.crutches, stock.queued_crutches, 'ConstructCrutch')
    local res3 = check_and_queue('buckets', stock.buckets, stock.queued_buckets, 'ConstructBucket')
    local res4 = check_and_queue('soap', stock.soap, stock.queued_soap, 'MakeSoap')
    local res5 = check_and_queue('plaster', stock.plaster, stock.queued_plaster, 'PrepareGypsumPlaster')

    if res1 or res2 or res3 or res4 or res5 then
        last_action = now
    else
        log.debug(string.format('hospital supplies healthy (splints=%d, crutches=%d, soap=%d, plaster=%d, buckets=%d)',
            stock.splints, stock.crutches, stock.soap, stock.plaster, stock.buckets))
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
