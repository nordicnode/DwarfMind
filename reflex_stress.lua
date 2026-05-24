-- DwarfMind reflex: stress spa / mental health intervention.
-- Monitors citizen stress levels. When stress exceeds a critical threshold,
-- assigns the citizen to the 'Respite' burrow (spa area) and disables their
-- labors so they can rest, eat, pray, and socialize until stress drops.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_stress')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_stress')

local json = require('json')

-- Stress threshold for sending to spa (in internal stress units).
-- Default 5000 is visible but not critical; higher values = more severe distress.
local STRESS_THRESHOLD = 5000

-- Stress level at which we consider a dwarf 'recovered' and restore them.
local RECOVERED_THRESHOLD = 1000

-- Cooldown to prevent re-intervening on the same dwarf too quickly.
local ACTION_COOLDOWN = 1200

local in_spa = {}  -- [unit_id] = record
local state_loaded = false

local function load_in_spa()
    state_loaded = true
    local entry = dfhack.persistent.get('dwarfmind/stress_spa')
    local loaded = {}
    if entry and entry.value and entry.value ~= '' then
        local ok, decoded = pcall(json.decode, entry.value)
        if ok and decoded then
            for k, v in pairs(decoded) do
                local unit_id = tonumber(k) or k
                local original_labors = {}
                if v.original_labors then
                    for l_k, l_v in pairs(v.original_labors) do
                        local labor_id = tonumber(l_k) or l_k
                        original_labors[labor_id] = l_v
                    end
                end
                loaded[unit_id] = {
                    tick_sent = v.tick_sent,
                    original_labors = original_labors
                }
            end
        end
    end
    in_spa = loaded
end

local function save_in_spa()
    local data = {}
    for k, v in pairs(in_spa) do
        local original_labors = {}
        for l_k, l_v in pairs(v.original_labors) do
            original_labors[tostring(l_k)] = l_v
        end
        data[tostring(k)] = {
            tick_sent = v.tick_sent,
            original_labors = original_labors
        }
    end
    local ok, encoded = pcall(json.encode, data)
    if ok and encoded then
        local entry = dfhack.persistent.get('dwarfmind/stress_spa') or dfhack.persistent.save('dwarfmind/stress_spa')
        entry.value = encoded
    end
end

-- Save which labors are currently enabled on a unit.
local function save_labor_state(unit)
    local labors = {}
    -- In DFHack's Lua bindings, pairs(df.unit_labor) returns:
    --   key = string labor name (e.g. "MINE")
    --   value = integer labor ID (e.g. 0)
    -- So we must iterate by (name, id) not (id, name).
    for labor_name, labor_id in pairs(df.unit_labor) do
        if type(labor_id) == 'number' and labor_id >= 0 then
            local ok, is_enabled = pcall(function() return unit.status.labors[labor_id] end)
            if ok and is_enabled then
                labors[labor_id] = true
            end
        end
    end
    return labors
end

-- Disable all labors on a unit.
local function disable_all_labors(unit)
    for labor_name, labor_id in pairs(df.unit_labor) do
        if type(labor_id) == 'number' and labor_id >= 0 then
            local ok, is_enabled = pcall(function() return unit.status.labors[labor_id] end)
            if ok and is_enabled then
                actuators.disable_labor(unit, labor_id)
            end
        end
    end
end

-- Restore a dwarf's original labor states after recovery.
local function restore_dwarf(unit, record)
    if not record.original_labors then return end

    -- Count how many labors we restored
    local count = 0

    -- First re-enable all original labors
    for labor_id, _ in pairs(record.original_labors) do
        actuators.enable_labor(unit, labor_id)
        count = count + 1
    end

    -- Remove from Respite burrow
    local spa_id = sensors.find_burrow_id_by_name('Respite')
    if spa_id then
        actuators.remove_unit_from_burrow(unit, spa_id)
    end

    log.info(string.format('  restored %d original labors on %s',
        count, sensors.describe_unit(unit)))
end

function run()
    if not sensors.is_fort_loaded() then return end

    -- Ensure we are loaded
    if not state_loaded then
        load_in_spa()
    end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end

    local alert_active, alert_ok = sensors.is_civilian_alert_active()
    if not alert_ok then alert_active = false end

    local spa_id = sensors.find_burrow_id_by_name('Respite')

    -- 1. Check recovery for currently quarantined units directly from the tracking list
    local pruned = false
    for unit_id, record in pairs(in_spa) do
        local u = df.unit.find(unit_id)
        if u and dfhack.units.isCitizen(u) and not dfhack.units.isDead(u) then
            local stress = u.status.stress
            if stress <= RECOVERED_THRESHOLD then
                log.info(string.format('STRESS RECOVERY: %s stress=%d (below %d); restoring labors and removing from spa',
                    sensors.describe_unit(u), stress, RECOVERED_THRESHOLD))
                restore_dwarf(u, record)
                in_spa[unit_id] = nil
                pruned = true
            else
                log.debug(string.format('STRESS MONITOR: %s still stressed (stress=%d) in spa; holding',
                    sensors.describe_unit(u), stress))
                
                -- Coordinate with civilian alerts to prevent pathfinding conflicts
                if spa_id then
                    local is_in_spa_burrow = dfhack.burrows.isAssignedUnit(spa_id, u)
                    if alert_active then
                        -- Temporarily suspend Respite burrow restriction during civilian alert
                        if is_in_spa_burrow then
                            log.warn(string.format('CIVILIAN ALERT ACTIVE: Temporarily removing stressed dwarf %s from Respite burrow to prevent pathfinding conflicts', sensors.describe_unit(u)))
                            actuators.remove_unit_from_burrow(u, spa_id)
                        end
                    else
                        -- Re-enable Respite burrow restriction when civilian alert ends
                        if not is_in_spa_burrow then
                            log.info(string.format('CIVILIAN ALERT DEACTIVATED: Restoring stressed dwarf %s to Respite burrow', sensors.describe_unit(u)))
                            actuators.assign_unit_to_burrow(u, spa_id)
                        end
                    end
                end
            end
        else
            -- Prune invalid/dead units from tracking
            in_spa[unit_id] = nil
            pruned = true
        end
    end

    -- Save persistent state once after all recovery/pruning operations
    if pruned then
        save_in_spa()
    end

    -- 2. Scan for new stressed dwarfs not yet in the spa
    local stressed, ok = sensors.get_stressed_citizens(STRESS_THRESHOLD)
    if not ok then
        log.warn('get_stressed_citizens failed')
        return
    end

    if not spa_id then
        log.debug('no Respite burrow defined; skipping stress management')
        return
    end

    local intervened = false
    for _, entry in ipairs(stressed) do
        local u = entry.unit
        if not in_spa[u.id] then
            log.warn(string.format('STRESS INTERVENTION: %s stress=%d exceeds threshold %d; sending to Respite',
                sensors.describe_unit(u), entry.stress, STRESS_THRESHOLD))
            local original_labors = save_labor_state(u)
            disable_all_labors(u)
            
            -- Only assign to Respite burrow if no civilian alert is active
            if not alert_active then
                actuators.assign_unit_to_burrow(u, spa_id)
            else
                log.warn(string.format('CIVILIAN ALERT ACTIVE: Delaying Respite burrow assignment for newly stressed dwarf %s', sensors.describe_unit(u)))
            end
            
            in_spa[u.id] = { tick_sent = now, original_labors = original_labors }
            intervened = true
        end
    end

    -- Save persistent state once after all interventions
    if intervened then
        save_in_spa()
    end
end

function reset()
    state_loaded = false
    in_spa = {}
end

return _ENV