-- DwarfMind reflex: strange mood assistant.
-- Intervenes to automatically fulfill missing strange mood demands:
-- Wood -> enable autochop and queue logs.
-- Bone/Body Part/Leather -> mark oldest excess domestic livestock for slaughter.
-- Metal -> queue SmeltOre orders.
-- Silk/Wool/Plant Cloth -> queue weaving if thread is available.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_mood_helper')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_mood_helper')

-- Cooldown to avoid spamming orders / slaughter marks
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

-- ─── Helpers ─────────────────────────────────────────────────────────────
local function get_usable_thread_counts()
    local silk_count, wool_count, plant_count = 0, 0, 0
    if df.global.world.items.other.THREAD then
        for _, it in ipairs(df.global.world.items.other.THREAD) do
            local f = it.flags
            if not f.forbid and not f.dump and not f.garbage_collect and not f.removed and not f.in_building then
                local mat = dfhack.matinfo.decode(it:getMaterial(), it:getMaterialIndex())
                if mat then
                    local token = mat:getToken() or ""
                    if token:find(":SILK") then
                        silk_count = silk_count + 1
                    elseif token:find(":WOOL") or token:find(":HAIR") or token:find(":YARN") then
                        wool_count = wool_count + 1
                    elseif token:find("^PLANT:") then
                        plant_count = plant_count + 1
                    end
                end
            end
        end
    end
    return silk_count, wool_count, plant_count
end

local function slaughter_excess_livestock()
    local livestock, ok = sensors.get_livestock()
    if not ok then return false end
    
    -- Group by race
    local race_units = {}
    for _, u in ipairs(livestock) do
        if not race_units[u.race] then
            race_units[u.race] = {}
        end
        table.insert(race_units[u.race], u)
    end
    
    -- Find races with >= 3 units (keep breeding pair)
    local candidates = {}
    for race, units in pairs(race_units) do
        if #units >= 3 then
            for _, u in ipairs(units) do
                table.insert(candidates, u)
            end
        end
    end
    
    if #candidates == 0 then
        log.warn("Need slaughterable livestock for bones/leather, but no species has >= 3 units to protect breeding pairs.")
        return false
    end
    
    -- Sort candidates by age descending (birth_year ascending)
    table.sort(candidates, function(a, b)
        if a.birth_year ~= b.birth_year then
            return a.birth_year < b.birth_year
        end
        return a.birth_seconds < b.birth_seconds
    end)
    
    local target = candidates[1]
    log.warn(string.format("Marking unit #%d (%s, race %d) for slaughter to resolve strange mood need.",
        target.id, dfhack.units.getReadableName(target), target.race))
    return actuators.mark_unit_for_slaughter(target, true)
end

-- ─── Reflex cycle ────────────────────────────────────────────────────────
function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end

    if (now - last_action) < ACTION_COOLDOWN then return end

    local distressed, ok = sensors.get_distressed_citizens()
    if not ok then
        log.warn('get_distressed_citizens failed')
        return
    end

    local action_taken = false

    for _, entry in ipairs(distressed) do
        local u = entry.unit
        -- Check if this citizen is stuck in a strange mood
        if u.flags1.has_mood and entry.mood_missing_categories then
            local mc = entry.mood_missing_categories
            local name = dfhack.units.getReadableName(u)
            
            -- 1. Wood Log
            if mc.wood then
                log.warn(string.format('Citizen %s is stuck in strange mood (needs wood) -> enabling autochop', name))
                actuators.run_script('enable', 'autochop')
                actuators.run_script('autochop', 'target', '40', '15')
                action_taken = true
            end

            -- 2. Bone, Body Part, Leather
            if mc.bone or mc.body_part or mc.leather then
                log.warn(string.format('Citizen %s is stuck in strange mood (needs bone/body part/leather) -> slaughtering excess livestock', name))
                if slaughter_excess_livestock() then
                    action_taken = true
                end
            end

            -- 3. Metal
            if mc.metal then
                log.warn(string.format('Citizen %s is stuck in strange mood (needs metal) -> queueing SmeltOre work orders', name))
                actuators.run_script('workorder', 'SmeltOre', '5')
                action_taken = true
            end

            -- 4. Silk, Wool, Plant Cloth
            if mc.silk or mc.wool or mc.plant_cloth then
                local silk_thread, wool_thread, plant_thread = get_usable_thread_counts()
                
                if mc.silk and silk_thread > 0 then
                    log.warn(string.format('Citizen %s is stuck in strange mood (needs silk cloth) and we have silk thread -> queueing WeaveSilk work orders', name))
                    actuators.run_script('workorder', 'WeaveSilk', '5')
                    action_taken = true
                end
                if mc.wool and wool_thread > 0 then
                    log.warn(string.format('Citizen %s is stuck in strange mood (needs wool cloth) and we have wool thread -> queueing WeaveWool work orders', name))
                    actuators.run_script('workorder', 'WeaveWool', '5')
                    action_taken = true
                end
                if mc.plant_cloth and plant_thread > 0 then
                    log.warn(string.format('Citizen %s is stuck in strange mood (needs plant cloth) and we have plant thread -> queueing WeaveCloth work orders', name))
                    actuators.run_script('workorder', 'WeaveCloth', '5')
                    action_taken = true
                end
            end
        end
    end

    if action_taken then
        last_action = now
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
