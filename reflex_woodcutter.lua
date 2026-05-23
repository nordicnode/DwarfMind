-- DwarfMind reflex: wood supply manager.
-- Periodically checks wood log stock levels.
-- Enables the DFHack 'autochop' plugin when logs are low (<15),
-- and disables it when logs are healthy (>40) to prevent deforesting.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_woodcutter')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_woodcutter')

-- Thresholds
local MIN_LOGS = 15
local MAX_LOGS = 40

-- Cooldown to avoid spamming the plugin command.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge
local current_status = nil -- true = enabled, false = disabled

function run()
    if not sensors.is_fort_loaded() then return end

    local stock, ok = sensors.check_stockpile_levels()
    if not ok then
        log.warn('check_stockpile_levels failed')
        return
    end

    local logs_count = stock.wood or 0
    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end

    if (now - last_action) < ACTION_COOLDOWN then return end

    -- Logs are low: enable autochop
    if logs_count < MIN_LOGS then
        if current_status ~= true then
            log.warn(string.format('wood logs low: %d (threshold %d) -> enabling autochop plugin',
                logs_count, MIN_LOGS))
            actuators.run_script('enable', 'autochop')
            actuators.run_script('autochop', 'target', tostring(MAX_LOGS), tostring(MIN_LOGS))
            current_status = true
            last_action = now
        end
    -- Logs are healthy: disable autochop
    elseif logs_count > MAX_LOGS then
        if current_status ~= false then
            log.info(string.format('wood logs healthy: %d (threshold %d) -> disabling autochop plugin',
                logs_count, MAX_LOGS))
            actuators.run_script('disable', 'autochop')
            current_status = false
            last_action = now
        end
    else
        log.debug(string.format('wood supply steady: %d', logs_count))
    end
end

function reset()
    last_action = -math.huge
    current_status = nil
end

return _ENV
