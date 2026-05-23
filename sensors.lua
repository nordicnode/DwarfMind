-- Read-only world sensors for DwarfMind.
-- Every public function is wrapped in pcall and returns a *safe* default
-- (empty list, 0, or nil) and an ok boolean flag indicating success.
--@ module = true

local _ENV = mkmodule('dwarfmind/sensors')

local logger = reqscript('dwarfmind/logger')
local log    = logger.for_module('sensors')

-- ─── Tick-Cache ───────────────────────────────────────────────────────────
-- Performance optimization: scan world data once per tick and cache
-- pre-filtered results. Multiple reflexes can query the cache without
-- re-iterating the same vectors.
--
-- Cache structure:
-- {
--   tick = N,                    -- frame_counter at time of cache build
--   citizens = {},               -- all living sane citizens
--   idle_dwarves = {},           -- citizens with no current job
--   distressed_citizens = {},    -- citizens with wellness issues
--   werebeast_citizens = {},     -- lycanthropy-infected citizens
--   hostiles = {},               -- active invader units
--   livestock = {},              -- tame fort-controlled animals
--   unpastured_grazers = {},     -- grazers not in any pasture zone
--   rotting_refuse = {},         -- forbidden rotting corpses inside
-- }
local tick_cache = { tick = -1 }

-- Invalidate cache when world state changes significantly.
-- Called by ai_core when cadences are re-armed on new fortress load.
function invalidate_cache()
    tick_cache = { tick = -1 }
    log.debug('sensor cache invalidated')
end

-- Build or refresh the tick cache. Returns the cache table.
local function ensure_cache()
    local now = -1
    local ok, current_tick = dfhack.pcall(function() return df.global.world.frame_counter end)
    if ok then now = current_tick end

    if tick_cache.tick ~= now then
        tick_cache.tick = now

        -- Single pass: gather all unit data
        local all_units = df.global.world.units.active
        local U = dfhack.units

        local citizens_data = U.getCitizens(false, false) or {}
        tick_cache.citizens = citizens_data

        -- Single-pass citizen filter: idle + werebeast in one loop over citizens_data
        local idle, werebeasts = {}, {}
        for _, u in ipairs(citizens_data) do
            local u_ok, is_idle = pcall(function()
                if not U.isAlive(u) then return false end
                if not U.isSane(u) then return false end
                if u.job.current_job ~= nil then return false end
                return U.isJobAvailable(u, false)
            end)
            if u_ok and is_idle then
                table.insert(idle, u)
            end
            if u.enemy and u.enemy.were_race > -1 then
                table.insert(werebeasts, u)
            end
        end
        tick_cache.idle_dwarves = idle
        tick_cache.werebeast_citizens = werebeasts

        -- Single-pass all-units filter: hostile / livestock / grazer in one loop.
        -- Uses if/else tree so each unit is classified exactly once.
        local hostiles, livestock, grazers = {}, {}, {}
        for _, u in ipairs(all_units) do
            if not U.isActive(u) or not U.isAlive(u) then
                -- skip dead/inactive
            elseif U.isInvader(u) and not u.flags1.caged and not u.flags1.chained then
                table.insert(hostiles, u)
            elseif U.isAnimal(u) and U.isFortControlled(u) and U.isTame(u)
               and not U.isPet(u) and not U.isMarkedForSlaughter(u)
               and not u.flags1.caged and not u.flags1.chained then
                table.insert(livestock, u)
                -- Nested grazer check
                local raw = df.creature_raw.find(u.race)
                if raw and raw.caste and raw.caste[u.caste]
                   and raw.caste[u.caste].flags.STANDARD_GRAZER then
                    local assigned = false
                    for _, ref in ipairs(u.general_refs) do
                        if ref:getType() == df.general_ref_type.BUILDING_CIVZONE_ASSIGNED then
                            assigned = true
                            break
                        end
                    end
                    if not assigned then
                        table.insert(grazers, u)
                    end
                end
            end
        end
        tick_cache.hostiles = hostiles
        tick_cache.livestock = livestock
        tick_cache.unpastured_grazers = grazers

        -- Pre-count deceased citizens for cemetery sensor.
        local dead_citizens = 0
        local unburied_citizens = 0

        -- Track assigned tombs/graves
        local owned_graves = {}
        for _, b in ipairs(df.global.world.buildings.all) do
            local t = b:getType()
            if t == df.building_type.Coffin or (t == df.building_type.Civzone and b.type == df.civzone_type.Tomb) then
                local owner_id = b.owner_id
                if owner_id == -1 and b.owner then
                    owner_id = b.owner.id
                end
                if owner_id and owner_id ~= -1 then
                    owned_graves[owner_id] = true
                end
            end
        end

        -- Iterate over all loaded units to catch deceased citizens
        for _, u in ipairs(df.global.world.units.all) do
            if U.isCitizen(u) and U.isDead(u) then
                dead_citizens = dead_citizens + 1
                if not owned_graves[u.id] then
                    unburied_citizens = unburied_citizens + 1
                end
            end
        end

        tick_cache.dead_citizens = dead_citizens
        tick_cache.unburied_citizens = unburied_citizens

        -- Pre-filter distressed citizens (basic wellness flags)
        local distressed = {}
        for _, u in ipairs(citizens_data) do
            local entry = nil
            local ok_distress, distress_data = pcall(function()
                local hunger = u.counters2.hunger_timer
                local thirst = u.counters2.thirst_timer
                local sleepiness = u.counters2.sleepiness_timer
                local pain = u.counters.pain
                local unconscious = u.counters.unconscious

                if thirst > 20000 or hunger > 30000 or sleepiness > 50000 or pain > 0 or unconscious > 0 then
                    entry = { unit = u }
                    if thirst > 20000 then entry.thirst = thirst end
                    if hunger > 30000 then entry.hunger = hunger end
                    if sleepiness > 50000 then entry.sleepiness = sleepiness end
                    if pain > 0 then entry.pain = pain end
                    if unconscious > 0 then entry.unconscious = unconscious end
                end

                -- Check bleeding
                local bl_ok, is_bleeding = pcall(U.isBleeding, u)
                if bl_ok and is_bleeding then
                    if not entry then entry = { unit = u } end
                    entry.bleeding = true
                end

                -- Check healthcare need
                if u.health and u.health.flags.needs_healthcare then
                    if not entry then entry = { unit = u } end
                    entry.needs_hospital = true
                end

                return entry
            end)
            if ok_distress and distress_data then
                table.insert(distressed, distress_data)
            end
        end
        tick_cache.distressed_citizens = distressed

        -- Pre-filter rotting refuse (corpses inside fort)
        local rotting = {}
        local function check_and_add(vec)
            for _, it in ipairs(vec) do
                if it.flags.on_ground and it.flags.forbid and not it.flags.dump and not it.flags.garbage_collect then
                    local pos = it.pos
                    local block = dfhack.maps.getTileBlock(pos.x, pos.y, pos.z)
                    if block then
                        local d = block.designation[pos.x % 16][pos.y % 16]
                        if not d.outside and d.subterranean then
                            table.insert(rotting, it)
                        end
                    end
                end
            end
        end
        local other = df.global.world.items.other
        if other.CORPSE then check_and_add(other.CORPSE) end
        if other.CORPSEPIECE then check_and_add(other.CORPSEPIECE) end
        tick_cache.rotting_refuse = rotting
    end

    return tick_cache
end

-- ─── Internal: safe protected wrap ───────────────────────────────────────
-- Returns (result, ok). On error, logs a warning and returns (default, false).
local function safe(name, default, fn, ...)
    local ok, result = dfhack.pcall(fn, ...)
    if not ok then
        log.warn(string.format('%s failed: %s', name, tostring(result)))
        return default, false
    end
    return result, true
end

-- ─── World availability ──────────────────────────────────────────────────
-- True only when it is safe to read fortress state.
function is_fort_loaded()
    if not dfhack.isMapLoaded() then return false end
    local ok, gm = pcall(function() return df.global.gamemode end)
    if not ok then return false end
    return gm == df.game_mode.DWARF
end

-- ─── Time ────────────────────────────────────────────────────────────────
-- Returns the monotonic in-game frame counter, or -1 if unavailable.
function current_tick()
    return safe('current_tick', -1, function()
        return df.global.world.frame_counter
    end)
end

-- Returns the calendar day of the month (1-28) governed by cur_year_tick.
-- Ticks per day: 1200. Days per month: 28.
function calendar_day()
    return safe('calendar_day', 1, function()
        return (df.global.cur_year_tick // 1200) % 28 + 1
    end)
end

-- ─── Citizens ────────────────────────────────────────────────────────────
-- All living, sane citizens of the player's civ. Always returns a list.
-- Second return value is true on success, false if the sensor failed.
--
-- Uses tick-cache when available to avoid redundant iteration.
-- Returns a COPY of the cached list to prevent cache corruption if
-- callers mutate the returned table.
function get_citizens()
    return safe('get_citizens', {}, function()
        local cache = ensure_cache()
        -- dfhack.units.getCitizens() returns a native Lua table (1-indexed),
        -- NOT a 0-indexed C++ vector. Iterate with ipairs to capture all citizens.
        -- The previous 0-based loop (i=0 to #-1) skipped index 0 (nil) and missed
        -- the last element since #cache.citizens - 1 on a 1-indexed table goes
        -- from 1 to #table-1, leaving out index #table.
        local copy = {}
        for i = 1, #cache.citizens do
            table.insert(copy, cache.citizens[i])
        end
        return copy
    end)
end



-- Returns a list of idle citizen unit objects.
-- Second return value is true on success, false if the sensor failed.
-- Uses tick-cache for performance.
function get_idle_dwarves()
    return safe('get_idle_dwarves', {}, function()
        local cache = ensure_cache()
        return cache.idle_dwarves
    end)
end

-- ─── Describing a unit (printable, console-safe) ─────────────────────────
-- DFHack names contain CP437; we route through df2console so the
-- terminal sees correct bytes.
function describe_unit(u)
    local out = safe('describe_unit', '<unknown unit>', function()
        local readable = dfhack.units.getReadableName(u) or '<unnamed>'
        local prof = dfhack.units.getProfessionName(u) or '<unknown profession>'
        local pos = dfhack.units.getPosition(u)
        local where = pos and string.format('(%d,%d,%d)', pos.x, pos.y, pos.z)
                          or  '(off-map)'
        return string.format('%s the %s @ %s',
            dfhack.df2console(readable),
            dfhack.df2console(prof),
            where)
    end)
    return out
end

-- ─── Livestock ───────────────────────────────────────────────────────────
-- Returns all tame, fort-controlled animals that aren't pets and aren't
-- already marked for slaughter.  Excludes caged, dead, and inactive units.
-- Each result is a raw df.unit object.  Second return value is the ok flag.
-- Uses tick-cache for performance.
function get_livestock()
    return safe('get_livestock', {}, function()
        local cache = ensure_cache()
        return cache.livestock
    end)
end

-- ─── Stockpile / food snapshot ───────────────────────────────────────────
-- Returns a table { food=N, drink=N, seeds=N, wood=N, stone=N } and
-- a boolean ok flag (false if the sensor failed). Each count is the
-- number of valid items from items.other categorized vectors. Forbidden,
-- rotten, dumped, garbage-collected, and removed items are excluded.
function check_stockpile_levels()
    return safe('check_stockpile_levels', {}, function()
        local function count(vec)
            local n = 0
            for _, it in ipairs(vec) do
                local f = it.flags
                if not f.forbid
                   and not f.rotten
                   and not f.dump
                   and not f.garbage_collect
                   and not f.removed then
                    n = n + 1
                end
            end
            return n
        end
        local other = df.global.world.items.other
        return {
            food  = count(other.FOOD) + count(other.MEAT) + count(other.PLANT)
                  + count(other.CHEESE) + count(other.EGG) + count(other.FISH),
            drink = count(other.DRINK),
            seeds = count(other.SEEDS),
            wood  = count(other.WOOD),
            stone = count(other.BOULDER),
        }
    end)
end

-- Helper to describe a required job item in a strange mood
local function describe_job_item(ji)
    local desc = {}
    
    -- Check flags first for specific material types
    local mat_category = nil
    if ji.flags.silk then mat_category = "silk cloth"
    elseif ji.flags.wool then mat_category = "wool cloth"
    elseif ji.flags.plant_cloth then mat_category = "plant cloth"
    elseif ji.flags.leather then mat_category = "leather"
    elseif ji.flags.bone then mat_category = "bone"
    elseif ji.flags.shell then mat_category = "shell"
    elseif ji.flags.wood then mat_category = "wood log"
    elseif ji.flags.metal then mat_category = "metal bar"
    elseif ji.flags.stone then mat_category = "stone"
    elseif ji.flags.glass then mat_category = "glass"
    elseif ji.flags.clay then mat_category = "clay"
    elseif ji.flags.body_part then mat_category = "body part / bone"
    elseif ji.flags.skin_tanned then mat_category = "leather"
    elseif ji.flags.raw then mat_category = "rough gem"
    end

    if mat_category then
        table.insert(desc, mat_category)
    end

    if ji.item_type > -1 then
        local type_name = df.item_type[ji.item_type]
        if type_name then
            if type_name == "CLOTH" then
                if not mat_category then table.insert(desc, "cloth") end
            elseif type_name == "SKIN_TANNED" then
                if not mat_category then table.insert(desc, "leather") end
            elseif type_name == "ROUGH" then
                if not mat_category then table.insert(desc, "rough gem") end
            elseif type_name == "BOULDER" then
                if not mat_category then table.insert(desc, "stone boulder") end
            elseif type_name == "BAR" then
                if not mat_category then table.insert(desc, "metal bar") end
            elseif type_name == "WOOD" then
                if not mat_category then table.insert(desc, "wood log") end
            else
                table.insert(desc, type_name:lower())
            end
        end
    end

    if ji.mat_type > -1 then
        local mat = dfhack.matinfo.decode(ji.mat_type, ji.mat_index)
        if mat then
            table.insert(desc, "(" .. mat:toString() .. ")")
        end
    end

    if #desc == 0 then
        return "unknown item"
    end
    return table.concat(desc, " ")
end

-- Returns a list of distressed citizens. Each entry is a table:
-- {
--   unit = u,
--   thirst = number,       -- timer value if > 20000
--   hunger = number,       -- timer value if > 30000
--   sleepiness = number,   -- timer value if > 50000
--   bleeding = boolean,
--   needs_hospital = boolean,
--   pain = number,
--   unconscious = number,
--   mood_stuck_workshop = boolean,
--   mood_stuck_item = boolean,
--   mood_missing_items = list of strings,
-- }
-- Second return value is true on success, false if the sensor failed.
-- Uses tick-cache for the basic wellness scan; strange mood checks are
-- done per-unit since they require job inspection.
function get_distressed_citizens()
    local citizens, ok = get_citizens()
    if not ok then return {}, false end

    -- Start with cached basic wellness flags
    local cache = ensure_cache()
    local distressed = {}

    -- Copy cached distress entries that have basic flags
    for _, entry in ipairs(cache.distressed_citizens) do
        table.insert(distressed, entry)
    end

    -- Add strange mood detection (requires per-unit job inspection)
    for _, u in ipairs(citizens) do
        local ok2, err = dfhack.pcall(function()
            if not u.flags1.has_mood then return end
            local job = u.job.current_job
            if not job then return end

            local is_strange_mood = false
            local ok_mood, err_mood = pcall(function()
                return df.job_type_class[df.job_type.attrs[job.job_type].type] == 'StrangeMood'
            end)
            if ok_mood then
                is_strange_mood = err_mood
            else
                log.warn(string.format('Failed to resolve StrangeMood job type class for job type %d: %s', job.job_type, tostring(err_mood)))
            end

            if is_strange_mood then
                local bld = dfhack.job.getHolder(job)
                local mood_entry = nil

                -- Find existing entry for this unit or create new one
                for _, e in ipairs(distressed) do
                    if e.unit == u then mood_entry = e; break end
                end
                if not mood_entry then
                    mood_entry = { unit = u }
                    table.insert(distressed, mood_entry)
                end

                if not bld then
                    if not dfhack.buildings.findAtTile(u.path.dest) then
                        mood_entry.mood_stuck_workshop = true
                    end
                elseif not (job.flags.fetching or job.flags.bringing or u.path.goal ~= df.unit_path_goal.None or job.flags.working) then
                    mood_entry.mood_stuck_item = true

                    -- Extract missing items
                    local missing = {}
                    local satisfied = {}
                    for _, ji_ref in ipairs(job.items) do
                        satisfied[ji_ref.job_item_idx] = true
                    end

                    local missing_cats = {}
                    for idx, ji in ipairs(job.job_items) do
                        if not satisfied[idx] then
                            table.insert(missing, describe_job_item(ji))
                            if ji.flags.silk then missing_cats.silk = true
                            elseif ji.flags.wool then missing_cats.wool = true
                            elseif ji.flags.plant_cloth then missing_cats.plant_cloth = true
                            elseif ji.flags.leather or ji.flags.skin_tanned then missing_cats.leather = true
                            elseif ji.flags.bone then missing_cats.bone = true
                            elseif ji.flags.shell then missing_cats.shell = true
                            elseif ji.flags.wood then missing_cats.wood = true
                            elseif ji.flags.metal then missing_cats.metal = true
                            elseif ji.flags.stone then missing_cats.stone = true
                            elseif ji.flags.glass then missing_cats.glass = true
                            elseif ji.flags.clay then missing_cats.clay = true
                            elseif ji.flags.body_part then missing_cats.body_part = true
                            elseif ji.flags.raw then missing_cats.rough_gem = true
                            end
                        end
                    end

                    if #missing > 0 then
                        mood_entry.mood_missing_items = missing
                        mood_entry.mood_missing_categories = missing_cats
                    end
                end
            end
        end)
        if not ok2 then
            log.warn('error checking unit ' .. tostring(u.id) .. ' for mood: ' .. tostring(err))
        end
    end

    return distressed, true
end

-- Returns a list of active, living, uncaged, unchained invader unit objects.
-- Second return value is the ok flag.
-- Uses tick-cache for performance.
function get_hostiles()
    return safe('get_hostiles', {}, function()
        local cache = ensure_cache()
        return cache.hostiles
    end)
end

-- Returns all levers. Each entry: { building = b, name = string, has_pull_job = boolean }
-- Second return value is the ok flag.
function get_levers()
    return safe('get_levers', {}, function()
        local levers = {}
        for _, b in ipairs(df.global.world.buildings.other.TRAP) do
            if b.trap_type == df.trap_type.Lever then
                local name = b.name or ""
                local has_pull = false
                for _, j in ipairs(b.jobs) do
                    if j.job_type == df.job_type.PullLever then
                        has_pull = true
                        break
                    end
                end
                table.insert(levers, { building = b, name = name, has_pull_job = has_pull })
            end
        end
        return levers
    end)
end

-- Returns all rotten forbidden corpses/pieces inside subterranean, inside tiles.
-- Second return value is the ok flag.
-- Uses tick-cache for performance.
function get_rotting_refuse()
    return safe('get_rotting_refuse', {}, function()
        local cache = ensure_cache()
        return cache.rotting_refuse
    end)
end

-- Returns { homeless=N, unowned_bedrooms=N, unbuilt_beds=N, queued_beds=N }
-- Second return value is the ok flag.
function check_bedroom_status()
    return safe('check_bedroom_status', { homeless=0, unowned_bedrooms=0, unbuilt_beds=0, queued_beds=0 }, function()
        local citizens = dfhack.units.getCitizens(true) or {}
        local owned_beds = {}
        for _, bld in ipairs(df.global.world.buildings.other.BED) do
            local owner_id = bld.owner_id
            if owner_id == -1 and bld.owner then
                owner_id = bld.owner.id
            end
            if owner_id and owner_id ~= -1 then
                owned_beds[owner_id] = true
            end
        end

        local homeless = 0
        for _, u in ipairs(citizens) do
            if not owned_beds[u.id] then
                homeless = homeless + 1
            end
        end

        local unowned_bedrooms = 0
        for _, building in ipairs(df.global.world.buildings.other.BED) do
            if building.is_room and not building.owner then
                unowned_bedrooms = unowned_bedrooms + 1
            end
        end

        local unbuilt_beds = 0
        for _, bed in ipairs(df.global.world.items.other.BED) do
            if not bed.flags.in_building and not bed.flags.forbid and not bed.flags.dump then
                unbuilt_beds = unbuilt_beds + 1
            end
        end

        local queued_beds = 0
        for _, order in ipairs(df.global.world.manager_orders) do
            if order.job_type == df.job_type.ConstructBed then
                queued_beds = queued_beds + order.amount_left
            end
        end

        return {
            homeless = homeless,
            unowned_bedrooms = unowned_bedrooms,
            unbuilt_beds = unbuilt_beds,
            queued_beds = queued_beds,
        }
    end)
end

-- Returns the first active TradeDepot building and an ok flag.
function get_active_depot()
    return safe('get_active_depot', nil, function()
        for _, bld in ipairs(df.global.world.buildings.other.TRADE_DEPOT) do
            if bld:getType() == df.building_type.TradeDepot and bld.flags.exists then
                return bld
            end
        end
        return nil
    end)
end

-- Returns a list of active caravans and an ok flag.
function get_active_caravans()
    return safe('get_active_caravans', {}, function()
        local result = {}
        for _, car in ipairs(df.global.plotinfo.caravans) do
            table.insert(result, car)
        end
        return result
    end)
end

-- Returns a list of citizens carrying were-infections and an ok flag.
-- Uses tick-cache for performance.
function get_werebeast_citizens()
    return safe('get_werebeast_citizens', {}, function()
        local cache = ensure_cache()
        return cache.werebeast_citizens
    end)
end

-- Returns all door buildings and an ok flag.
function get_doors()
    return safe('get_doors', {}, function()
        local result = {}
        for _, door in ipairs(df.global.world.buildings.other.DOOR) do
            if door.flags.exists then
                table.insert(result, door)
            end
        end
        return result
    end)
end

-- Returns the citizen unit assigned to the specific noble position code (e.g. "CHIEF_MEDICAL_DWARF").
-- Second return value is the ok flag.
function get_noble_unit(role_code)
    return safe('get_noble_unit', nil, function()
        local citizens, ok = get_citizens()
        if not ok then return nil end
        for _, u in ipairs(citizens) do
            local noble_positions = dfhack.units.getNoblePositions(u)
            if noble_positions then
                for _, pos in ipairs(noble_positions) do
                    if pos.position.code == role_code then
                        return u
                    end
                end
            end
        end
        return nil
    end)
end

-- Returns stockpiled and queued counts of hospital supplies:
-- { splints = N, crutches = N, soap = N, plaster = N, buckets = N,
--   queued_splints = N, queued_crutches = N, queued_soap = N, queued_plaster = N, queued_buckets = N }
-- Second return value is the ok flag.
function check_hospital_supplies()
    return safe('check_hospital_supplies', {
        splints = 0, crutches = 0, soap = 0, plaster = 0, buckets = 0,
        queued_splints = 0, queued_crutches = 0, queued_soap = 0, queued_plaster = 0, queued_buckets = 0
    }, function()
        local splints = 0
        local crutches = 0
        local soap = 0
        local plaster = 0
        local buckets = 0

        local function is_valid(it)
            local f = it.flags
            return not f.forbid and not f.dump and not f.garbage_collect and not f.removed
        end

        local other = df.global.world.items.other

        if other.SPLINT then
            for _, it in ipairs(other.SPLINT) do
                if is_valid(it) then splints = splints + 1 end
            end
        end

        if other.CRUTCH then
            for _, it in ipairs(other.CRUTCH) do
                if is_valid(it) then crutches = crutches + 1 end
            end
        end

        if other.BUCKET then
            for _, it in ipairs(other.BUCKET) do
                if is_valid(it) then buckets = buckets + 1 end
            end
        end

        if other.BAR then
            for _, it in ipairs(other.BAR) do
                if is_valid(it) then
                    local mat = dfhack.matinfo.decode(it:getMaterial(), it:getMaterialIndex())
                    if mat and mat.material and mat.material.flags.SOAP then
                        soap = soap + (it.stack_size > 0 and it.stack_size or 1)
                    end
                end
            end
        end

        if other.POWDER_MISC then
            for _, it in ipairs(other.POWDER_MISC) do
                if is_valid(it) then
                    local mat = dfhack.matinfo.decode(it:getMaterial(), it:getMaterialIndex())
                    if mat then
                        local mid = mat.id
                        if mid == "GYPSUM" or mid == "ALABASTER" or mid == "SELENITE" or mid == "SATINSPAR" then
                            plaster = plaster + (it.stack_size > 0 and it.stack_size or 1)
                        end
                    end
                end
            end
        end

        local queued_splints = 0
        local queued_crutches = 0
        local queued_soap = 0
        local queued_plaster = 0
        local queued_buckets = 0

        for _, order in ipairs(df.global.world.manager_orders) do
            local jt = order.job_type
            if jt == df.job_type.ConstructSplint then
                queued_splints = queued_splints + order.amount_left
            elseif jt == df.job_type.ConstructCrutch then
                queued_crutches = queued_crutches + order.amount_left
            elseif jt == df.job_type.MakeSoap then
                queued_soap = queued_soap + order.amount_left
            elseif jt == df.job_type.ConstructBucket then
                queued_buckets = queued_buckets + order.amount_left
            elseif jt == df.job_type.PrepareGypsumPlaster then
                queued_plaster = queued_plaster + order.amount_left
            end
        end

        return {
            splints = splints,
            crutches = crutches,
            soap = soap,
            plaster = plaster,
            buckets = buckets,
            queued_splints = queued_splints,
            queued_crutches = queued_crutches,
            queued_soap = queued_soap,
            queued_plaster = queued_plaster,
            queued_buckets = queued_buckets,
        }
    end)
end

-- Returns status of cemetery and dead citizens:
-- { dead_citizens = N, unburied_citizens = N, unplaced_coffins = N, queued_coffins = N }
-- Second return value is the ok flag.
function check_cemetery_status()
    return safe('check_cemetery_status', {
        dead_citizens = 0, unburied_citizens = 0, unplaced_coffins = 0, queued_coffins = 0
    }, function()
        local cache = ensure_cache()
        local dead_citizens = cache.dead_citizens or 0
        local unburied_citizens = cache.unburied_citizens or 0

        local unplaced_coffins = 0
        if df.global.world.items.other.COFFIN then
            for _, coffin in ipairs(df.global.world.items.other.COFFIN) do
                if not coffin.flags.in_building and not coffin.flags.forbid and not coffin.flags.dump and not coffin.flags.removed then
                    unplaced_coffins = unplaced_coffins + 1
                end
            end
        end

        local queued_coffins = 0
        for _, order in ipairs(df.global.world.manager_orders) do
            if order.job_type == df.job_type.ConstructCoffin then
                queued_coffins = queued_coffins + order.amount_left
            end
        end

        return {
            dead_citizens = dead_citizens,
            unburied_citizens = unburied_citizens,
            unplaced_coffins = unplaced_coffins,
            queued_coffins = queued_coffins,
        }
    end)
end

-- Returns tame owned grazers that are not assigned to any pasture zone.
-- Second return value is the ok flag.
-- Uses tick-cache for performance.
function get_unpastured_grazers()
    return safe('get_unpastured_grazers', {}, function()
        local cache = ensure_cache()
        return cache.unpastured_grazers
    end)
end

-- Returns all Pen/Pasture zones and an ok flag.
function get_pasture_zones()
    return safe('get_pasture_zones', {}, function()
        local result = {}
        local zones = df.global.world.buildings.other.ACTIVITY_ZONE
        if zones then
            for _, bld in ipairs(zones) do
                if bld.type == df.civzone_type.Pen then
                    table.insert(result, bld)
                end
            end
        end
        return result
    end)
end

-- Returns civilian alert status (boolean: active/inactive) and an ok flag.
function is_civilian_alert_active()
    -- When alert is active, actuators sets civ_alert_idx to alert_idx (0).
    -- When cleared, actuators sets it to -1.
    -- Check against -1: active→false (0 != -1), cleared→true (-1 != -1).
    return safe('is_civilian_alert_active', false, function()
        return df.global.plotinfo.alerts.civ_alert_idx ~= -1
    end)
end

-- Finds a burrow ID by its name (case-insensitive). Returns the ID or nil.
-- Second return value is the ok flag.
function find_burrow_id_by_name(name)
    return safe('find_burrow_id_by_name', nil, function()
        local target = name:lower()
        for _, burrow in ipairs(df.global.plotinfo.burrows.list) do
            if burrow.name:lower() == target then
                return burrow.id
            end
        end
        return nil
    end)
end

-- Returns status of military equipment and shortages.
-- Second return value is the ok flag.
function check_military_gear_status()
    return safe('check_military_gear_status', {
        soldiers = 0, helms = 0, breastplates = 0, greaves = 0, shields = 0, weapons = 0,
        queued_helms = 0, queued_breastplates = 0, queued_greaves = 0, queued_shields = 0, queued_weapons = 0
    }, function()
        local soldiers = 0
        if df.global.plotinfo and df.global.plotinfo.equipment and df.global.plotinfo.equipment.squads then
            for _, squad in ipairs(df.global.plotinfo.equipment.squads) do
                for _, pos in ipairs(squad.positions) do
                    if pos.occupant > -1 then
                        soldiers = soldiers + 1
                    end
                end
            end
        end

        local helms = 0
        local breastplates = 0
        local greaves = 0
        local shields = 0
        local weapons = 0

        local function is_valid_metal_gear(it)
            local f = it.flags
            if f.forbid or f.dump or f.garbage_collect or f.removed or f.in_building then
                return false
            end
            local mat = dfhack.matinfo.decode(it:getMaterial(), it:getMaterialIndex())
            if mat and mat.material and mat.material.flags.IS_METAL then
                return true
            end
            return false
        end

        local other = df.global.world.items.other

        if other.HELM then
            for _, it in ipairs(other.HELM) do
                if is_valid_metal_gear(it) then helms = helms + 1 end
            end
        end

        if other.ARMOR then
            for _, it in ipairs(other.ARMOR) do
                if is_valid_metal_gear(it) then breastplates = breastplates + 1 end
            end
        end

        if other.PANTS then
            for _, it in ipairs(other.PANTS) do
                if is_valid_metal_gear(it) then greaves = greaves + 1 end
            end
        end

        if other.SHIELD then
            for _, it in ipairs(other.SHIELD) do
                local f = it.flags
                if not f.forbid and not f.dump and not f.garbage_collect and not f.removed and not f.in_building then
                    shields = shields + 1
                end
            end
        end

        if other.WEAPON then
            for _, it in ipairs(other.WEAPON) do
                if is_valid_metal_gear(it) then weapons = weapons + 1 end
            end
        end

        local queued_helms = 0
        local queued_breastplates = 0
        local queued_greaves = 0
        local queued_shields = 0
        local queued_weapons = 0

        for _, order in ipairs(df.global.world.manager_orders) do
            local jt = order.job_type
            if jt == df.job_type.MakeArmor then
                queued_breastplates = queued_breastplates + order.amount_left
            elseif jt == df.job_type.MakeHelm then
                queued_helms = queued_helms + order.amount_left
            elseif jt == df.job_type.MakePants then
                queued_greaves = queued_greaves + order.amount_left
            elseif jt == df.job_type.MakeShield then
                queued_shields = queued_shields + order.amount_left
            elseif jt == df.job_type.MakeWeapon then
                queued_weapons = queued_weapons + order.amount_left
            end
        end

        return {
            soldiers = soldiers,
            helms = helms,
            breastplates = breastplates,
            greaves = greaves,
            shields = shields,
            weapons = weapons,
            queued_helms = queued_helms,
            queued_breastplates = queued_breastplates,
            queued_greaves = queued_greaves,
            queued_shields = queued_shields,
            queued_weapons = queued_weapons,
        }
    end)
end

-- Returns a list of cluttered workshops and their contained finished items.
-- Second return value is the ok flag.
function get_cluttered_workshops()
    return safe('get_cluttered_workshops', {}, function()
        local result = {}
        local workshops = df.global.world.buildings.other.WORKSHOP_ANY
        if workshops then
            for _, bld in ipairs(workshops) do
                if bld.flags.exists then
                    local clutter_items = {}
                    for _, bi in ipairs(bld.contained_items) do
                        if bi.use == 2 and bi.item then
                            local it = bi.item
                            local f = it.flags
                            if not f.dump and not f.forbid and not f.removed then
                                table.insert(clutter_items, it)
                            end
                        end
                    end
                    if #clutter_items > 8 then
                        table.insert(result, { building = bld, items = clutter_items })
                    end
                end
            end
        end
        return result
    end)
end

-- Returns a list of appointed nobles missing required offices, dining rooms, or bedrooms.
-- Each entry: { unit = u, position = pos_table, missing_bedroom = bool, missing_office = bool, missing_dining = bool }
-- Second return value is the ok flag.
function get_noble_room_deficits()
    return safe('get_noble_room_deficits', {}, function()
        local result = {}
        local citizens, ok = get_citizens()
        if not ok then return {} end

        local owned_rooms = {}
        for _, b in ipairs(df.global.world.buildings.all) do
            local owner_id = b.owner_id
            if owner_id == -1 and b.owner then
                owner_id = b.owner.id
            end
            if owner_id and owner_id ~= -1 then
                if not owned_rooms[owner_id] then
                    owned_rooms[owner_id] = { bedroom = false, office = false, dining = false }
                end
                local t = b:getType()
                if t == df.building_type.Bed then
                    owned_rooms[owner_id].bedroom = true
                elseif t == df.building_type.Chair then
                    owned_rooms[owner_id].office = true
                elseif t == df.building_type.Table then
                    owned_rooms[owner_id].dining = true
                elseif t == df.building_type.Civzone then
                    if b.type == df.civzone_type.Bedroom then
                        owned_rooms[owner_id].bedroom = true
                    elseif b.type == df.civzone_type.Office then
                        owned_rooms[owner_id].office = true
                    elseif b.type == df.civzone_type.DiningHall then
                        owned_rooms[owner_id].dining = true
                    end
                end
            end
        end

        for _, u in ipairs(citizens) do
            local noble_positions = dfhack.units.getNoblePositions(u)
            if noble_positions then
                for _, np in ipairs(noble_positions) do
                    local pos = np.position
                    local req_bedroom = pos.required_bedroom > 0
                    local req_office = pos.required_office > 0
                    local req_dining = pos.required_dining > 0

                    if req_bedroom or req_office or req_dining then
                        local rooms = owned_rooms[u.id] or { bedroom = false, office = false, dining = false }
                        local has_bedroom = rooms.bedroom
                        local has_office = rooms.office
                        local has_dining = rooms.dining

                        local missing_bedroom = req_bedroom and not has_bedroom
                        local missing_office = req_office and not has_office
                        local missing_dining = req_dining and not has_dining

                        if missing_bedroom or missing_office or missing_dining then
                            table.insert(result, {
                                unit = u,
                                position = pos,
                                missing_bedroom = missing_bedroom,
                                missing_office = missing_office,
                                missing_dining = missing_dining
                            })
                        end
                    end
                end
            end
        end
        return result
    end)
end

-- Returns active mandates and an ok flag.
function check_active_mandates()
    return safe('check_active_mandates', {}, function()
        local result = {}
        if df.global.world.mandates and df.global.world.mandates.all then
            for _, mandate in ipairs(df.global.world.mandates.all) do
                table.insert(result, mandate)
            end
        end
        return result
    end)
end

-- ─── Stress / Mental Health ──────────────────────────────────────────
-- Returns a list of stressed citizens whose stress exceeds the given threshold.
-- Each entry: { unit = u, stress = N, in_spa = boolean }
-- Second return value is the ok flag.
function get_stressed_citizens(threshold)
    threshold = threshold or 5000
    return safe('get_stressed_citizens', {}, function()
        local result = {}
        local citizens = get_citizens()
        local spa_id = find_burrow_id_by_name('Respite')
        local spa_burrow = nil
        
        if spa_id then
            for _, b in ipairs(df.global.plotinfo.burrows.list) do
                if b.id == spa_id then
                    spa_burrow = b
                    break
                end
            end
        end
        
        for _, u in ipairs(citizens) do
            local ok_stress, stress = pcall(function()
                return u.status.stress end)
            if ok_stress and stress and stress > threshold then
                local in_spa = false
                if spa_burrow then
                    in_spa = dfhack.burrows.isAssignedUnit(spa_burrow, u)
                end
                table.insert(result, { unit = u, stress = stress, in_spa = in_spa })
            end
        end
        
        return result
    end)
end

-- ─── Hydrology / Cistern Monitoring ─────────────────────────────────────
-- Returns the liquid depth (0-7) at the specified coordinates.
-- Returns -1 if the tile cannot be read or is not water.
-- Uses block.designation[lx][ly].flow_size for depth (DF's actual liquid data).
function get_liquid_depth(x, y, z)
    return safe('get_liquid_depth', -1, function()
        local block = dfhack.maps.getTileBlock(x, y, z)
        if not block then return -1 end
        local lx = x % 16
        local ly = y % 16
        local des = block.designation[lx][ly]
        
        -- liquid_type is false for water, true for magma
        -- flow_size represents depth (0 to 7)
        if not des.liquid_type then
            return des.flow_size
        end
        return -1
    end)
end

-- Returns true if the tile at coordinates is a static (non-flowing) water body.
function is_static_water(x, y, z)
    return safe('is_static_water', false, function()
        local block = dfhack.maps.getTileBlock(x, y, z)
        if not block then return false end
        local lx = x % 16
        local ly = y % 16
        local des = block.designation[lx][ly]
        local occ = block.occupancy[lx][ly]
        
        -- Static depth must be greater than 0, liquid type must be Water (false),
        -- and not have active inlet flow flags in occupancy.
        return des.flow_size > 0
           and not des.liquid_type
           and not occ.edge_flow_in
    end)
end

-- ─── Clothing / Nudity ───────────────────────────────────────────────────
-- Returns citizens wearing tattered clothing (flags2.tattered or high wear).
-- Each entry: { unit = u, tattered_items = {item, ...} }
-- Second return value is the ok flag.
function get_citizens_in_tattered_clothing()
    return safe('get_citizens_in_tattered_clothing', {}, function()
        local result = {}
        local citizens = get_citizens()
        
        for _, u in ipairs(citizens) do
            local tattered = {}
            for _, inv_item in ipairs(u.inventory) do
                local item = inv_item.item
                if item and item.flags2.tattered then
                    table.insert(tattered, item)
                end
            end
            if #tattered > 0 then
                table.insert(result, { unit = u, tattered_items = tattered })
            end
        end
        
        return result
    end)
end

-- Returns counts of spare clothing items by type.
-- { pants = N, shirts = N, shoes = N }
-- Note: Torso civilian clothes (shirts, dresses, robes, coats) are stored in
-- the ARMOR vector, distinguished by armorlevel == 0 (vs military armor > 0).
function get_spare_clothing_stock()
    return safe('get_spare_clothing_stock', { pants = 0, shirts = 0, shoes = 0 }, function()
        local stock = { pants = 0, shirts = 0, shoes = 0 }
        local other = df.global.world.items.other
        
        local function is_valid_civilian_clothing(it)
            local f = it.flags
            if f.forbid or f.dump or f.garbage_collect or f.removed or f.in_building then
                return false
            end
            -- Civilian clothing has armorlevel == 0; military gear has > 0.
            local ok, armorlevel = pcall(function() return it.subtype.armorlevel end)
            if ok and armorlevel ~= nil then
                return armorlevel == 0
            end
            return true
        end
        
        if other.PANTS then
            for _, it in ipairs(other.PANTS) do
                if is_valid_civilian_clothing(it) then stock.pants = stock.pants + 1 end
            end
        end
        -- Note: Torso civilian clothes (shirts, dresses, etc.) live in the ARMOR vector
        if other.ARMOR then
            for _, it in ipairs(other.ARMOR) do
                if is_valid_civilian_clothing(it) then stock.shirts = stock.shirts + 1 end
            end
        end
        if other.SHOES then
            for _, it in ipairs(other.SHOES) do
                if is_valid_civilian_clothing(it) then stock.shoes = stock.shoes + 1 end
            end
        end
        
        return stock
    end)
end

-- ─── Seed Watch / Kitchen Safety ─────────────────────────────────────────
-- Returns count of plump helmet spawn (seeds) in the SEEDS item vector.
-- Second return value is the ok flag.
function get_plump_helmet_seed_count()
    return safe('get_plump_helmet_seed_count', 0, function()
        local count = 0
        local other = df.global.world.items.other
        if other.SEEDS then
            for _, seed in ipairs(other.SEEDS) do
                if not seed.flags.forbid and not seed.flags.dump and not seed.flags.garbage_collect and not seed.flags.removed then
                    local mat = dfhack.matinfo.decode(seed:getMaterial(), seed:getMaterialIndex())
                    -- mat.material.id is the generic material class (e.g. "SEED"), not the plant.
                    -- The actual plant token lives in mat.plant.id (e.g. "MUSHROOM_HELMET_PLUMP").
                    if mat and mat.plant then
                        local token = mat.plant.id
                        if token == 'MUSHROOM_HELMET_PLUMP' then
                            count = count + (seed.stack_size > 0 and seed.stack_size or 1)
                        end
                    end
                end
            end
        end
        return count
    end)
end

-- Checks if cooking of a specific plant raw ID is banned.
-- Uses dfhack.kitchen API to safely query exclusions at df.global.plotinfo.kitchen.
function is_plant_cooking_banned(plant_raw_id)
    return safe('is_plant_cooking_banned', false, function()
        local matinfo = dfhack.matinfo.find('PLANT_MAT:' .. plant_raw_id .. ':STRUCTURAL')
        if not matinfo then return false end
        
        local index = dfhack.kitchen.findExclusion({Cook=true}, df.item_type.PLANT, -1, matinfo.type, matinfo.index)
        return index ~= -1
    end)
end

-- Returns a table of metal bar counts in stock: { steel = N, iron = N, bronze = N, copper = N }
-- Second return value is the ok flag.
function get_metal_bars_stock()
    return safe('get_metal_bars_stock', { steel = 0, iron = 0, bronze = 0, copper = 0 }, function()
        local stock = { steel = 0, iron = 0, bronze = 0, copper = 0 }
        local other = df.global.world.items.other
        if other.BAR then
            for _, it in ipairs(other.BAR) do
                local f = it.flags
                if not f.forbid and not f.dump and not f.garbage_collect and not f.removed and not f.in_building then
                    local mat = dfhack.matinfo.decode(it:getMaterial(), it:getMaterialIndex())
                    if mat and mat.material then
                        local token = mat:getToken()
                        local size = it.stack_size > 0 and it.stack_size or 1
                        if token == "INORGANIC:STEEL" then
                            stock.steel = stock.steel + size
                        elseif token == "INORGANIC:IRON" then
                            stock.iron = stock.iron + size
                        elseif token == "INORGANIC:BRONZE" then
                            stock.bronze = stock.bronze + size
                        elseif token == "INORGANIC:COPPER" then
                            stock.copper = stock.copper + size
                        end
                    end
                end
            end
        end
        return stock
    end)
end

return _ENV
