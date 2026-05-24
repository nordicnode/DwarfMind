-- DwarfMind reflex: access security and pathing gatekeeper.
-- Monitors hostiles and merchant caravans.
-- Automatically manages gates and drawbridges:
--   - Threat (Invaders present): Seals the fort by pulling all defense levers.
--   - Peace (Caravans arriving/present): Opens the gates to allow merchant pathing.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_access_security')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_access_security')

-- Keywords to identify security/defense levers (lowercase)
local SECURITY_KEYWORDS = {
    gate = true,
    bridge = true,
    entrance = true,
    panic = true,
    defense = true,
    security = true,
}

-- Cooldown to avoid duplicate pulling of levers (1000 ticks = ~20 seconds)
local ACTION_COOLDOWN = 1000
local last_action = {} -- [lever_id] = tick

local function is_security_lever(name)
    if not name or name == '' then return false end
    local n = name:lower()
    for kw in pairs(SECURITY_KEYWORDS) do
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
        -- Prune expired cooldowns
        for id, last in pairs(last_action) do
            if (now - last) >= ACTION_COOLDOWN then
                last_action[id] = nil
            end
        end
    else
        now = 0
    end

    local hostiles, hostiles_ok = sensors.get_hostiles()
    local caravans, caravans_ok = sensors.get_active_caravans()
    local levers, levers_ok = sensors.get_levers()

    if not hostiles_ok or not caravans_ok or not levers_ok then
        log.warn('failed to retrieve hostile/caravan/lever sensors')
        return
    end

    local threat_active = (#hostiles > 0)
    local caravan_active = (#caravans > 0)

    -- If no hostiles and no caravans, we don't need to change any gate states
    if not threat_active and not caravan_active then
        return
    end

    for _, l in ipairs(levers) do
        if is_security_lever(l.name) then
            local current_state = l.state -- 'open', 'closed', 'opening', 'closing', or nil

            if threat_active then
                -- Threat active: SEAL THE FORT (close all security doors/bridges)
                if current_state == 'open' or current_state == 'opening' then
                    if l.has_pull_job then
                        log.info(string.format('THREAT ACTIVE: lever #%d (%s) already has pull order to close', l.building.id, l.name))
                    else
                        local last = last_action[l.building.id] or -math.huge
                        if (now - last) >= ACTION_COOLDOWN then
                            log.warn(string.format('THREAT SECTOR SEALS: pulling security lever #%d (%s) to CLOSE gates/bridges!',
                                l.building.id, l.name))
                            actuators.run_script('lever', 'pull', '--id', tostring(l.building.id), '--priority')
                            last_action[l.building.id] = now
                        end
                    end
                end
            elseif caravan_active then
                -- Peace state with active caravan: OPEN THE FORT (allow pathing to depot)
                if current_state == 'closed' or current_state == 'closing' then
                    if l.has_pull_job then
                        log.info(string.format('PEACE CARAVAN: lever #%d (%s) already has pull order to open', l.building.id, l.name))
                    else
                        local last = last_action[l.building.id] or -math.huge
                        if (now - last) >= ACTION_COOLDOWN then
                            log.warn(string.format('PEACE CARAVAN PATHING: pulling security lever #%d (%s) to OPEN gates/bridges for merchant caravan!',
                                l.building.id, l.name))
                            actuators.run_script('lever', 'pull', '--id', tostring(l.building.id))
                            last_action[l.building.id] = now
                        end
                    end
                end
            end
        end
    end
end

function reset()
    last_action = {}
end

return _ENV
