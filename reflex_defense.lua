-- DwarfMind reflex: auto-pull defense levers when hostiles are detected.
-- Monitors hostiles on the map. If hostiles are present, looks for levers
-- named "gate", "bridge", "panic", "entrance", or "defense" and triggers them.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_defense')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_defense')

-- Keywords to look for in the lever nickname (lowercase).
local DEFENSE_KEYWORDS = {
    gate = true,
    bridge = true,
    panic = true,
    entrance = true,
    defense = true,
}

-- Cooldown to avoid spamming / duplicate queueing.
local ACTION_COOLDOWN = 1000
local last_action = {} -- [lever_id] = tick

local function is_defense_lever(name)
    if not name or name == '' then return false end
    local n = name:lower()
    for kw in pairs(DEFENSE_KEYWORDS) do
        if n:find(kw, 1, true) then
            return true
        end
    end
    return false
end

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if tick_ok and now >= 0 then
        -- Prune expired entries to prevent memory leaks from deconstructed/destroyed levers.
        for id, last in pairs(last_action) do
            if (now - last) >= ACTION_COOLDOWN then
                last_action[id] = nil
            end
        end
    else
        now = 0
    end

    local hostiles, ok = sensors.get_hostiles()
    if not ok then
        log.warn('get_hostiles failed')
        return
    end

    if #hostiles == 0 then
        log.debug('no hostiles on map')
        return
    end

    -- Hostiles present! Log status.
    log.warn(string.format('hostiles detected: %d active invader(s) on the map!', #hostiles))

    -- Check levers
    local levers, levers_ok = sensors.get_levers()
    if not levers_ok then
        log.warn('get_levers failed')
        return
    end



    for _, l in ipairs(levers) do
        if is_defense_lever(l.name) then
            if l.has_pull_job then
                log.info(string.format('defense lever #%d (%s) already has a pending pull job',
                    l.building.id, l.name))
            else
                local last = last_action[l.building.id] or -math.huge
                if (now - last) >= ACTION_COOLDOWN then
                    log.warn(string.format('CRITICAL: pulling defense lever #%d (%s) @ (%d,%d,%d) due to hostiles!',
                        l.building.id, l.name, l.building.centerx, l.building.centery, l.building.z))
                    
                    -- Actuate pull with high priority.
                    actuators.run_script('lever', 'pull', '--id', tostring(l.building.id), '--priority')
                    last_action[l.building.id] = now
                end
            end
        end
    end
end

function reset()
    last_action = {}
end

return _ENV
