-- DwarfMind reflex: detect excess livestock and suggest butchering.
-- Groups tame fort-owned animals by species, compares adult counts against
-- thresholds, and logs suggestions.  When dry_run is off, calls exterminate
-- with -m BUTCHER to mark the excess for slaughter.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_butcher')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_butcher')

-- ─── Configuration ───────────────────────────────────────────────────────
-- Maximum adults allowed per species before we flag excess.  Unlisted
-- species fall back to DEFAULT_THRESHOLD.  Birds reproduce fast, so they
-- get higher ceilings; large grazers (cows, horses, etc.) are kept low.
local THRESHOLDS = {
    BIRD_CHICKEN       = 10,
    BIRD_TURKEY        = 10,
    BIRD_DUCK          = 10,
    BIRD_GOOSE         = 10,
    BIRD_PEAFOWL_BLUE  = 10,
    BIRD_GUINEAFOWL    = 10,
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

-- Don't re-queue the same species for butchering more than once per
-- ACTION_COOLDOWN ticks (≈ 2.5 dwarf days at default cadence).
local ACTION_COOLDOWN = 6000
local last_action = {}  -- [creature_id] = tick

-- ─── Helpers ─────────────────────────────────────────────────────────────
local function table_size(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- ─── Reflex cycle ────────────────────────────────────────────────────────
function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if tick_ok and now >= 0 then
        -- Prune expired entries to prevent memory leaks from modded/inactive species.
        for id, last in pairs(last_action) do
            if (now - last) >= ACTION_COOLDOWN then
                last_action[id] = nil
            end
        end
    else
        now = 0
    end

    local livestock, ok = sensors.get_livestock()
    if not ok then
        log.warn('get_livestock failed')
        return
    end

    -- Group by species, separating adult males and females
    local races = {}  -- [creature_id] = {adult_males = {}, adult_females = {}, display = str}
    for _, u in ipairs(livestock) do
        local ok2, craw = pcall(function() return df.creature_raw.find(u.race) end)
        if not ok2 or not craw then goto next_unit end
        local cid = craw.creature_id
        if not races[cid] then
            races[cid] = {adult_males = {}, adult_females = {}, display = craw.name[0] or cid}
        end
        
        local adult_ok, is_adult = pcall(dfhack.units.isAdult, u)
        if adult_ok and is_adult then
            if u.sex == 1 then
                table.insert(races[cid].adult_males, u)
            elseif u.sex == 0 then
                table.insert(races[cid].adult_females, u)
            end
        end
        ::next_unit::
    end

    if next(races) == nil then
        log.debug('no livestock detected')
        return
    end

    local total_livestock = #livestock
    local excess_groups_count = 0

    for cid, data in pairs(races) do
        local threshold = THRESHOLDS[cid] or DEFAULT_THRESHOLD
        local adult_males = data.adult_males
        local adult_females = data.adult_females
        local total_adults = #adult_males + #adult_females
        local excess = total_adults - threshold
        
        if excess > 0 then
            excess_groups_count = excess_groups_count + 1
            log.info(string.format('  %s: %d adults (%d M, %d F, threshold %d) → excess %d',
                data.display, total_adults, #adult_males, #adult_females, threshold, excess))

            local last = last_action[cid] or -math.huge
            if (now - last) >= ACTION_COOLDOWN then
                local to_slaughter = {}
                -- Keep at least 1 adult male for breeding, kill other males first
                local males_to_kill = math.min(excess, math.max(0, #adult_males - 1))
                for i = 1, males_to_kill do
                    table.insert(to_slaughter, adult_males[i])
                end

                -- If we still have excess, kill females, keeping at least 1 adult female
                local remaining_excess = excess - #to_slaughter
                if remaining_excess > 0 then
                    local females_to_kill = math.min(remaining_excess, math.max(0, #adult_females - 1))
                    for i = 1, females_to_kill do
                        table.insert(to_slaughter, adult_females[i])
                    end
                end

                if #to_slaughter > 0 then
                    log.warn(string.format('marking %d excess %s for slaughter (males=%d, females=%d)',
                        #to_slaughter, data.display, males_to_kill, #to_slaughter - males_to_kill))
                    
                    for _, u in ipairs(to_slaughter) do
                        actuators.mark_unit_for_slaughter(u, true)
                    end
                    last_action[cid] = now
                end
            end
        end
    end

    log.info(string.format('livestock check: %d species, %d animals, %d excess groups',
        table_size(races), total_livestock, excess_groups_count))
end

-- For tests / hot reloading: clear cooldown table.
function reset()
    last_action = {}
end

return _ENV
