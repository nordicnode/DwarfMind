-- DwarfMind reflex: auto-geld population control.
-- Prevents animal population explosions by auditing livestock counts.
-- If a species is at or nearing its adult limit, flags younger domestic adult
-- males of that species for gelding. Ensures at least one adult male is kept
-- ungelded for breeding.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_geld')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_geld')

-- Configuration
local THRESHOLDS = {
    PIG                = 5,
    SHEEP              = 5,
    GOAT               = 5,
    COW                = 3,
    HORSE              = 3,
    YAK                = 3,
    WATER_BUFFALO      = 3,
    LLAMA              = 3,
    ALPACA             = 3,
    CAT                = 2,
    DOG                = 2,
}

local DEFAULT_THRESHOLD = 5

-- Cooldown to avoid spamming markings
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

-- ─── Helpers ─────────────────────────────────────────────────────────────
local function is_unit_geldable(unit)
    if not unit or not unit.body or not unit.body.body_plan then
        return false
    end
    for _, part in ipairs(unit.body.body_plan.body_parts) do
        if part.flags.GELDABLE then
            return true
        end
    end
    return false
end

-- ─── Reflex cycle ────────────────────────────────────────────────────────
function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end

    if (now - last_action) < ACTION_COOLDOWN then return end

    local livestock, ok = sensors.get_livestock()
    if not ok then
        log.warn('get_livestock failed')
        return
    end

    -- Group livestock by species (creature_id)
    local races = {} -- [creature_id] = { adults = {}, males = {}, display = string }
    for _, u in ipairs(livestock) do
        local ok2, craw = pcall(function() return df.creature_raw.find(u.race) end)
        if not ok2 or not craw then goto next_unit end
        
        local cid = craw.creature_id
        if not races[cid] then
            races[cid] = { adults = {}, males = {}, display = craw.name[0] or cid }
        end

        local adult_ok, is_adult = pcall(dfhack.units.isAdult, u)
        if adult_ok and is_adult then
            table.insert(races[cid].adults, u)
            if u.sex == 1 and not u.flags3.gelded and is_unit_geldable(u) then
                table.insert(races[cid].males, u)
            end
        end
        ::next_unit::
    end

    local action_taken = false

    for cid, data in pairs(races) do
        local threshold = THRESHOLDS[cid] or DEFAULT_THRESHOLD
        local total_adults = #data.adults
        local males = data.males

        -- Sort males by age descending (oldest first, i.e., birth_year ascending)
        table.sort(males, function(a, b)
            if a.birth_year ~= b.birth_year then
                return a.birth_year < b.birth_year
            end
            return a.birth_time < b.birth_time
        end)

        if total_adults >= threshold then
            if #males > 0 then
                -- 1. Ensure the oldest male is NOT marked for gelding (breeding male)
                if males[1].flags3.marked_for_gelding then
                    log.warn(string.format('population control: keeping oldest male %s (%s) for breeding -> unmarking for gelding',
                        data.display, dfhack.units.getReadableName(males[1])))
                    actuators.mark_unit_for_gelding(males[1], false)
                    action_taken = true
                end

                -- 2. Mark all younger males for gelding
                for i = 2, #males do
                    local u = males[i]
                    if not u.flags3.marked_for_gelding then
                        log.warn(string.format('population control: %s count %d (threshold %d) -> marking younger male %s for gelding',
                            data.display, total_adults, threshold, dfhack.units.getReadableName(u)))
                        actuators.mark_unit_for_gelding(u, true)
                        action_taken = true
                    end
                end
            end
        else
            -- Below threshold: unmark all males for gelding to allow population growth
            for _, u in ipairs(males) do
                if u.flags3.marked_for_gelding then
                    log.warn(string.format('population control: %s count %d below threshold %d -> unmarking male %s for gelding to allow breeding',
                        data.display, total_adults, threshold, dfhack.units.getReadableName(u)))
                    actuators.mark_unit_for_gelding(u, false)
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
