-- DwarfMind reflex: cistern and reservoir water level safety.
-- Monitors liquid depth at a configured sensor tile and operates
-- inlet/outlet levers to maintain safe water levels.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_hydrology')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_hydrology')

-- Default sensor coordinates - player should configure these for their cistern.
-- Format: { x = N, y = N, z = N }
-- Set to nil to disable; configure via the module's exported configure() function.
local CONFIG = {
    sensor_x = nil,
    sensor_y = nil,
    sensor_z = nil,
    dry_threshold = 2,    -- open inlet if water <= 2
    flood_threshold = 6,  -- close inlet if water >= 6
}

-- Keywords to look for in lever name for cistern gates.
local CISTERN_LEVER_KEYWORDS = {
    cistern = true,
    water_inlet = true,
    floodgate = true,
    inlet = true,
    reservoir = true,
}

-- Cooldown between lever actions.
local ACTION_COOLDOWN = 1200

-- Track last action time per lever
local last_action = {}  -- [lever_id] = tick

local function is_cistern_lever(name)
    if not name or name == '' then return false end
    local n = name:lower()
    for kw in pairs(CISTERN_LEVER_KEYWORDS) do
        if n:find(kw, 1, true) then
            return true
        end
    end
    return false
end

local function is_cistern_gate_open(l)
    -- In DF, lever state 1 indicates triggered/activated (open inlet flow target)
    return l.building.state == 1
end

function run()
    if not sensors.is_fort_loaded() then return end

    -- Skip if no sensor configured
    if not CONFIG.sensor_x or not CONFIG.sensor_y or not CONFIG.sensor_z then
        log.debug('hydrology sensor not configured; skipping')
        return
    end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end

    -- Prune stale lever entries
    for id, last in pairs(last_action) do
        if (now - last) >= ACTION_COOLDOWN then
            last_action[id] = nil
        end
    end

    -- Check water level at sensor tile
    local depth, ok = sensors.get_liquid_depth(CONFIG.sensor_x, CONFIG.sensor_y, CONFIG.sensor_z)
    if not ok or depth < 0 then
        log.warn(string.format('failed to read liquid depth at (%d,%d,%d)',
            CONFIG.sensor_x, CONFIG.sensor_y, CONFIG.sensor_z))
        return
    end

    log.debug(string.format('cistern water level at (%d,%d,%d): %d',
        CONFIG.sensor_x, CONFIG.sensor_y, CONFIG.sensor_z, depth))

    -- Find cistern levers
    local levers, levers_ok = sensors.get_levers()
    if not levers_ok then
        log.warn('get_levers failed')
        return
    end

    for _, l in ipairs(levers) do
        if is_cistern_lever(l.name) then
            -- Check current lever state by examining if it has a pull job pending
            -- If water is low (<= dry_threshold), we want the lever OPEN (water flowing in)
            -- If water is high (>= flood_threshold), we want the lever CLOSED (water stopped)

            local is_open = is_cistern_gate_open(l)
            local last = last_action[l.building.id] or -math.huge

            if (now - last) < ACTION_COOLDOWN then
                log.debug(string.format('lever #%d (%s) on cooldown; skipping', l.building.id, l.name))
            elseif depth <= CONFIG.dry_threshold then
                -- Water too low - need to OPEN the inlet
                -- Only pull if currently closed
                if not is_open then
                    if l.has_pull_job then
                        log.debug(string.format('lever #%d (%s) already has pull job; waiting',
                            l.building.id, l.name))
                    else
                        log.warn(string.format('CISTERN LOW WATER: pulling lever #%d (%s) @ (%d,%d,%d) to OPEN inlet (depth=%d)',
                            l.building.id, l.name, l.building.centerx, l.building.centery, l.building.z, depth))
                        actuators.run_script('lever', 'pull', '--id', tostring(l.building.id), '--priority')
                        last_action[l.building.id] = now
                    end
                else
                    log.debug(string.format('lever #%d (%s) already open; water still low but waiting', l.building.id, l.name))
                end
            elseif depth >= CONFIG.flood_threshold then
                -- Water too high - need to CLOSE the inlet
                -- Only pull if currently open
                if is_open then
                    if l.has_pull_job then
                        log.debug(string.format('lever #%d (%s) already has pull job; waiting',
                            l.building.id, l.name))
                    else
                        log.warn(string.format('CISTERN HIGH WATER: pulling lever #%d (%s) @ (%d,%d,%d) to CLOSE inlet (depth=%d)',
                            l.building.id, l.name, l.building.centerx, l.building.centery, l.building.z, depth))
                        actuators.run_script('lever', 'pull', '--id', tostring(l.building.id), '--priority')
                        last_action[l.building.id] = now
                    end
                else
                    log.debug(string.format('lever #%d (%s) already closed; water still high but waiting', l.building.id, l.name))
                end
            end
        end
    end
end

-- Configure the sensor coordinates.
-- Call this from a script or the DFHack Lua console to set your cistern tile:
--   reflexHydrology.configure(x, y, z)
function configure(x, y, z)
    CONFIG.sensor_x = x
    CONFIG.sensor_y = y
    CONFIG.sensor_z = z
    log.info(string.format('hydrology sensor configured to (%d,%d,%d)', x, y, z))
end

-- Get current configuration.
function get_config()
    return CONFIG
end

function reset()
    last_action = {}
end

return _ENV