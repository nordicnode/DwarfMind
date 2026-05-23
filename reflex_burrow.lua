-- DwarfMind reflex: civilian burrow alert (panic button).
-- Periodically checks for hostiles on the map. If hostiles are detected,
-- triggers civilian alert restricting citizens to the "Safety" or "Panic" burrow.
-- Automatically deactivates the alert once hostiles have been gone for 600 ticks.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_burrow')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_burrow')

-- Cooldown to prevent immediate deactivation when hostiles go out of sight.
local ALERT_DEACTIVATION_DELAY = 600
local last_hostile_seen = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end

    local hostiles, host_ok = sensors.get_hostiles()
    if not host_ok then
        log.warn('get_hostiles failed')
        return
    end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end

    local alert_active, alert_ok = sensors.is_civilian_alert_active()
    if not alert_ok then return end

    if #hostiles > 0 then
        last_hostile_seen = now
        
        if not alert_active then
            -- Find safe burrow
            local burrow_id = sensors.find_burrow_id_by_name("Safety")
            if not burrow_id then
                burrow_id = sensors.find_burrow_id_by_name("Panic")
            end

            if burrow_id then
                log.warn(string.format('CIVILIAN DANGER: %d hostile(s) detected! Activating civilian alert (burrow ID %d)',
                    #hostiles, burrow_id))
                actuators.set_civilian_alert(true, burrow_id)
            else
                log.warn(string.format('CIVILIAN DANGER: %d hostile(s) detected! BUT no "Safety" or "Panic" burrow exists! Please define one.',
                    #hostiles))
            end
        end
    else
        -- No hostiles present. Check if we should clear the alert
        if alert_active then
            local time_since_danger = now - last_hostile_seen
            if time_since_danger >= ALERT_DEACTIVATION_DELAY then
                log.warn('CIVILIAN SAFETY: map clear of hostiles for sustained period; deactivating civilian alert')
                actuators.set_civilian_alert(false)
            else
                log.debug(string.format('no hostiles, but holding alert for deactivation delay (%d/%d ticks remaining)',
                    ALERT_DEACTIVATION_DELAY - time_since_danger, ALERT_DEACTIVATION_DELAY))
            end
        end
    end
end

function reset()
    last_hostile_seen = -math.huge
end

return _ENV
