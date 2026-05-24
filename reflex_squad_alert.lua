-- DwarfMind reflex: activate fort-defense squads when hostiles are detected.
-- Complements reflex_defense (which pulls levers) by actually calling squads
-- to arms via dfhack.military.activateSquad(). Runs in tick_fast for the
-- same sub-second response time as reflex_defense.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_squad_alert')

local sensors   = reqscript('dwarfmind/sensors')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_squad_alert')

-- Keywords matched against squad names (lowercase) to identify fort-defense
-- squads. Matched with Lua frontier patterns (%f[%a]/%f[%A]) for strict whole-
-- word boundaries — digits are not treated as word separators under this scheme,
-- which is the correct behaviour (a squad named '3defend4' should NOT match).
local ALERT_KEYWORDS = {
    'defend', 'defense', 'guard', 'militia', 'ranger', 'patrol', 'watch',
}

-- How many ticks must pass before we re-evaluate activation after the last
-- trigger. Prevents re-firing every fast-tick while hostiles persist.
local ACTIVATE_COOLDOWN = 1200

-- Internal state
local last_activate   = -math.huge  -- tick of last activation pass
local activated_squads = {}          -- set of squad ids we have activated
local was_hostile     = false        -- was the map hostile last tick?

-- Returns true when `name` contains any ALERT_KEYWORDS as a whole word.
-- Uses Lua frontier patterns (%f[%a] / %f[%A]) so that a keyword embedded
-- inside another word (e.g. 'watchman', '3defend4') does not match.
local function is_defense_squad(name)
    if not name or name == '' then return false end
    local lower = name:lower():gsub('[_%-]', ' ')
    for _, kw in ipairs(ALERT_KEYWORDS) do
        if lower:find('%f[%a]' .. kw .. '%f[%A]') then
            return true
        end
    end
    return false
end

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end

    local hostiles, ok = sensors.get_hostiles()
    if not ok then
        log.warn('get_hostiles failed; skipping squad alert evaluation')
        return
    end

    local hostile_present = (#hostiles > 0)

    -- ── Deactivate when threat clears ────────────────────────────────────────────
    if was_hostile and not hostile_present then
        log.info('hostiles cleared; standing down activated defense squads')
        for squad_id, _ in pairs(activated_squads) do
            local ok_deact, err_deact = dfhack.pcall(function()
                dfhack.military.deactivateSquad(squad_id)
            end)
            if ok_deact then
                log.info(string.format('squad #%d stood down', squad_id))
            else
                log.warn(string.format(
                    'failed to deactivate squad #%d: %s',
                    squad_id, tostring(err_deact)))
            end
        end
        activated_squads = {}
        last_activate    = -math.huge
    end

    was_hostile = hostile_present

    if not hostile_present then
        log.debug('no hostiles; squad alert inactive')
        return
    end

    -- ── Cooldown gate ─────────────────────────────────────────────────────────
    if (now - last_activate) < ACTIVATE_COOLDOWN then
        log.debug('squad alert on cooldown; skipping')
        return
    end

    -- ── Activate matching squads ───────────────────────────────────────────────
    local squads = df.global.world.squads.all
    local activated_count = 0

    for i = 0, #squads - 1 do
        local squad = squads[i]
        if squad and is_defense_squad(squad.name) then
            local sid = squad.id
            if not activated_squads[sid] then
                local ok_act, err_act = dfhack.pcall(function()
                    dfhack.military.activateSquad(sid)
                end)
                if ok_act then
                    activated_squads[sid] = true
                    activated_count = activated_count + 1
                    log.warn(string.format(
                        'ALERT: activated squad #%d "%s" due to %d hostile(s) on map',
                        sid, squad.name, #hostiles))
                else
                    log.warn(string.format(
                        'failed to activate squad #%d "%s": %s',
                        sid, squad.name, tostring(err_act)))
                end
            end
        end
    end

    if activated_count == 0 and next(activated_squads) == nil then
        log.warn(string.format(
            'hostiles present (%d) but no matching defense squads found! ' ..
            'Name a squad with a keyword from: %s',
            #hostiles, table.concat(ALERT_KEYWORDS, ', ')))
    end

    last_activate = now
end

function reset()
    last_activate    = -math.huge
    activated_squads = {}
    was_hostile      = false
end

return _ENV
