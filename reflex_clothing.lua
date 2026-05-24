-- DwarfMind reflex: clothing replacement / hygiene logistics.
-- Ensures that the C++ 'tailor' plugin is enabled and active.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_clothing')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_clothing')

-- Cooldown to avoid spamming the console/plugin commands.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge
local tailor_active = nil -- true/false/nil

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    -- Enable tailor plugin to automatically strip rags and order replacements
    if tailor_active ~= true then
        log.info('clothing audit: ensuring DFHack tailor plugin is enabled')
        actuators.run_command('enable', 'tailor')
        tailor_active = true
        last_action = now
    end
end

function reset()
    last_action = -math.huge
    tailor_active = nil
end

return _ENV