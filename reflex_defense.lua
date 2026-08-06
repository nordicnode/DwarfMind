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
-- BUG FIX: The previous code used n:find(kw, 1, true) (plain substring match),
-- which caused false positives for levers whose names merely contain one of
-- these strings incidentally (e.g. "entrance_to_tavern" would match "entrance"
-- and trigger a defense pull on a non-gate lever).
--
-- The new pattern anchors each keyword using a word-boundary approach:
-- the keyword must appear at the start of the name, at the end, or be
-- surrounded by non-alphanumeric characters (spaces, underscores, hyphens).
-- This ensures "gate" matches "gate", "main_gate", "gate_east" but NOT
-- "floodgate" or "delegate".
local DEFENSE_KEYWORDS = {
    'gate', 'bridge', 'panic', 'entrance', 'defense',
}

-- Returns true if `name` contains any of DEFENSE_KEYWORDS as a whole word.
-- Shared whole-word matcher lives in sensors.matches_keywords() so the
-- defense, access-security, and orchestrator reflexes stay consistent.
local function is_defense_lever(name)
    return sensors.matches_keywords(name, DEFENSE_KEYWORDS)
end

-- Cooldown to avoid spamming / duplicate queueing.
local ACTION_COOLDOWN = 1000
local last_action = {} -- [lever_id] = tick

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
            -- FIX (gate-toggle flap): pulling a lever TOGGLES its linked
            -- mechanism.  The old code pulled on every cooldown expiry without
            -- checking state, so during a siege lasting > 1000 ticks the same
            -- lever was pulled again and the gate/bridge was reopened mid-siege.
            -- Only pull when the mechanism is open/opening or its state is
            -- unknown; never re-pull a mechanism that is already sealed.
            local state = l.state
            if state == 'closed' or state == 'closing' then
                log.debug(string.format('defense lever #%d (%s) already sealed (%s); not pulling',
                    l.building.id, l.name, tostring(state)))
            elseif l.has_pull_job then
                log.info(string.format('defense lever #%d (%s) already has a pending pull job',
                    l.building.id, l.name))
            else
                local last = last_action[l.building.id] or -math.huge
                if (now - last) >= ACTION_COOLDOWN then
                    log.warn(string.format(
                        'CRITICAL: pulling defense lever #%d (%s) @ (%d,%d,%d) due to hostiles!',
                        l.building.id, l.name,
                        l.building.centerx, l.building.centery, l.building.z))

                    -- Actuate pull with high priority.
                    actuators.run_script('lever', 'pull',
                        '--id', tostring(l.building.id), '--priority')

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
