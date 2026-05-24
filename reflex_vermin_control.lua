-- DwarfMind reflex: vermin control and pet population management.
-- Monitors tame cat populations (excluded from livestock by isPet).
-- If adult cat count exceeds a threshold, marks excess for slaughter while
-- preserving at least one breeding pair. Warns if zero cats are present.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_vermin_control')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_vermin_control')

-- Configuration
local MAX_CATS = 5
local CAT_CREATURE_ID = 'CAT'

-- Cooldown to avoid spamming slaughter marks
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    local cats, ok = sensors.get_pets_by_race(CAT_CREATURE_ID)
    if not ok then
        log.warn('get_pets_by_race failed for cats')
        return
    end

    local adult_cats = {}
    for _, u in ipairs(cats) do
        local adult_ok, is_adult = pcall(dfhack.units.isAdult, u)
        if adult_ok and is_adult then
            table.insert(adult_cats, u)
        end
    end

    local total_adult_cats = #adult_cats

    if total_adult_cats == 0 then
        log.warn('VERMIN RISK: no adult cats detected in the fortress! Vermin may proliferate unchecked.')
        return
    end

    log.info(string.format('vermin control: %d adult cat(s) detected (threshold: %d)', total_adult_cats, MAX_CATS))

    if total_adult_cats <= MAX_CATS then
        log.debug('cat population within acceptable limits')
        return
    end

    local excess = total_adult_cats - MAX_CATS
    log.warn(string.format('cat population excess: %d adult cats, threshold %d -> excess %d',
        total_adult_cats, MAX_CATS, excess))

    -- Separate males and females to preserve a breeding pair
    local males = {}
    local females = {}
    for _, u in ipairs(adult_cats) do
        if u.sex == 1 then
            table.insert(males, u)
        elseif u.sex == 0 then
            table.insert(females, u)
        end
    end

    local to_slaughter = {}

    -- Cull males first, preserving the oldest male for breeding
    if #males > 1 then
        table.sort(males, function(a, b)
            if a.birth_year ~= b.birth_year then
                return a.birth_year < b.birth_year
            end
            return a.birth_time < b.birth_time
        end)

        local male_excess = math.min(excess, #males - 1)
        for i = 2, male_excess + 1 do
            if males[i] then
                table.insert(to_slaughter, males[i])
            end
        end
    end

    -- If still excess, cull females, preserving the oldest female
    local remaining_excess = excess - #to_slaughter
    if remaining_excess > 0 and #females > 1 then
        table.sort(females, function(a, b)
            if a.birth_year ~= b.birth_year then
                return a.birth_year < b.birth_year
            end
            return a.birth_time < b.birth_time
        end)

        local female_excess = math.min(remaining_excess, #females - 1)
        for i = 2, female_excess + 1 do
            if females[i] then
                table.insert(to_slaughter, females[i])
            end
        end
    end

    if #to_slaughter > 0 then
        log.warn(string.format('marking %d excess cat(s) for slaughter to control population', #to_slaughter))
        for _, u in ipairs(to_slaughter) do
            actuators.mark_unit_for_slaughter(u, true)
        end
        last_action = now
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
