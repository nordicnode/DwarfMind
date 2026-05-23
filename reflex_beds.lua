-- DwarfMind reflex: monitor citizen bedroom needs and auto-queue ConstructBed work orders.
-- Audits homeless counts against unowned bedrooms, unbuilt beds, and queued orders.
-- Queues ConstructBed orders via the workorder script if there is a deficit.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_beds')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_beds')

-- Cooldown to avoid duplicate queueing of orders.
-- 6000 ticks is approx. 50 dwarf days.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end

    local status, ok = sensors.check_bedroom_status()
    if not ok then
        log.warn('check_bedroom_status failed')
        return
    end

    local homeless   = status.homeless or 0
    local unowned    = status.unowned_bedrooms or 0
    local unbuilt    = status.unbuilt_beds or 0
    local queued     = status.queued_beds or 0

    local supply = unowned + unbuilt + queued
    local deficit = homeless - supply

    if deficit > 0 then
        log.warn(string.format('bedroom deficit detected: %d citizens are homeless but bed supply (unowned rooms=%d, unbuilt=%d, queued=%d) is short by %d bed(s)',
            homeless, unowned, unbuilt, queued, deficit))
        
        local now = sensors.current_tick()
        if (now - last_action) >= ACTION_COOLDOWN then
            log.info(string.format('queueing workorder to construct %d bed(s)', deficit))
            actuators.run_script('workorder', string.format('[{"job":"ConstructBed","amount_total":%d,"material_category":["wood"]}]', deficit))
            last_action = now
        end
    else
        log.debug(string.format('bed supply sufficient: homeless=%d, supply=%d', homeless, supply))
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
