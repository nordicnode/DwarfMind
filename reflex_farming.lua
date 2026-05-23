-- DwarfMind reflex: smart seasonal crop rotation.
-- Ensures that the C++ 'autofarm' plugin is enabled and active.
-- Dynamically adjusts crop settings or threshold flags to maintain seed buffers.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_farming')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_farming')

-- Cooldown to avoid spamming console scripts.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge
local autofarm_active = nil -- true/false/nil

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    -- Enable autofarm and set default thresholds to ensure healthy food/seed buffers.
    if autofarm_active ~= true then
        log.info('farming audit: ensuring DFHack autofarm plugin is enabled')
        actuators.run_script('enable', 'autofarm')
        
        -- Set standard seed thresholds (e.g. keep at least 100 of each major underground crop)
        actuators.run_script('autofarm', 'threshold', '100', 'MUSHROOM_HELMET_PLUMP')
        actuators.run_script('autofarm', 'threshold', '100', 'GRASS_TAIL_PIG')
        actuators.run_script('autofarm', 'threshold', '100', 'GRASS_WHEAT_CAVE')
        actuators.run_script('autofarm', 'threshold', '100', 'PLANT_ROUND_SWEET')
        
        autofarm_active = true
        last_action = now
    end
end

function reset()
    last_action = -math.huge
    autofarm_active = nil
end

return _ENV
