-- Read-only world sensors for DwarfMind.
-- Every public function is wrapped in pcall and returns a *safe* default
-- (empty list, 0, or nil) and an ok boolean flag indicating success.
--@ module = true

local _ENV = mkmodule('dwarfmind/sensors')

local logger = reqscript('dwarfmind/logger')
local log    = logger.for_module('sensors')

-- ─── Tick-Cache ────────────────────────────────────────────────────────────────────────
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

-- ─── Internal: safe protected wrap ────────────────────────────────────────────
local function safe(name, default, fn, ...)
    local ok, result = dfhack.pcall(fn, ...)
    if not ok then
        log.warn(string.format('%s failed: %s', name, tostring(result)))
        return default, false
    end
    return result, true
end

-- ─── World availability ────────────────────────────────────────────────────────────
function is_fort_loaded()
    if not dfhack.isMapLoaded() then return false end
    local ok, gm = pcall(function() return df.global.gamemode end)
    if not ok then return false end
    return gm == df.game_mode.DWARF
end

-- ─── Time ────────────────────────────────────────────────────────────────────────────────
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

-- ─── Citizens ─────────────────────────────────────────────────────────────────────────
function get_citizens()
    return safe('get_citizens', {}, function()
        local cache = ensure_cache()
        return cache.citizens
    end)
end

function get_idle_dwarves()
    return safe('get_idle_dwarves', {}, function()
        local cache = ensure_cache()
        return cache.idle_dwarves
    end)
end

-- ─── Distress ─────────────────────────────────────────────────────────────────────────
-- Returns a list of distress entries. Each entry is a table:
-- {
--   unit = <unit object>,
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
        -- Single-pass over buildings.all: collect owned_beds and unowned_bedrooms
        -- simultaneously to avoid iterating the full building list twice.
        local owned_beds = {}
        local unowned_bedrooms = 0
        for _, bld in ipairs(df.global.world.buildings.all) do
            if bld:getType() == df.building_type.Bed then
                local owner_id = bld.owner_id
                if owner_id == -1 and bld.owner then
                    owner_id = bld.owner.id
                end
                if owner_id and owner_id ~= -1 then
                    owned_beds[owner_id] = true
                elseif bld.room and bld.room.extents ~= nil and bld.room.width > 0 then
                    -- Unowned bedroom with a defined room layout
                    unowned_bedrooms = unowned_bedrooms + 1
                end
            end
        end

        local homeless = 0
        for _, u in ipairs(citizens) do
            if not owned_beds[u.id] then
                homeless = homeless + 1
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
        for _, bld in ipairs(df.global.world.buildings.all) do
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
        for _, door in ipairs(df.global.world.buildings.all) do
            if door:getType() == df.building_type.Door and door.flags.exists then
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
                for _, np in ipairs(noble_positions) do
                    if np.position and np.position.code == role_code then
                        return u
                    end
                end
            end
        end
        return nil
    end)
end

-- Returns count of unburied dead citizens and total dead.
-- Second return value is ok flag.
-- Uses tick-cache for performance.
function check_cemetery_status()
    return safe('check_cemetery_status', { dead=0, unburied=0 }, function()
        local cache = ensure_cache()
        return { dead = cache.dead_citizens or 0, unburied = cache.unburied_citizens or 0 }
    end)
end

-- Returns citizens needing memorial slabs (no tomb assignment, confirmed dead).
-- This is distinct from unburied - a dwarf may have a coffin but still need a slab
-- if their body was lost/destroyed.
-- Second return value is ok flag.
function check_slab_needs()
    return safe('check_slab_needs', { needs_slab = 0, already_slabbed = 0 }, function()
        local U = dfhack.units
        local needs = 0
        local slabbed = 0

        -- Build set of unit IDs with memorial slabs
        local has_slab = {}
        for _, it in ipairs(df.global.world.items.other.SLAB) do
            if it.subtype and it.subtype.slab_type == df.slab_engraving_type.Memorial then
                if it.maker_race ~= -1 or it.maker ~= -1 then
                    -- Look for the unit reference
                    for _, ref in ipairs(it.general_refs) do
                        local t = ref:getType()
                        if t == df.general_ref_type.UNIT_ACTOR or
                           t == df.general_ref_type.UNIT_WORKER or
                           t == df.general_ref_type.UNIT_SLAUGHTERER then
                            has_slab[ref.unit_id] = true
                        end
                    end
                end
            end
        end

        -- Count dead citizens without slabs
        for _, u in ipairs(df.global.world.units.all) do
            if U.isCitizen(u) and U.isDead(u) then
                if has_slab[u.id] then
                    slabbed = slabbed + 1
                else
                    needs = needs + 1
                end
            end
        end

        return { needs_slab = needs, already_slabbed = slabbed }
    end)
end

-- Returns tame fort livestock (non-pet, non-slaughter-queued, uncaged).
-- Second return value is ok flag.
-- Uses tick-cache for performance.
function get_livestock()
    return safe('get_livestock', {}, function()
        local cache = ensure_cache()
        return cache.livestock
    end)
end

-- Returns tame fort grazers not assigned to any pasture zone.
-- Second return value is ok flag.
-- Uses tick-cache for performance.
function get_unpastured_grazers()
    return safe('get_unpastured_grazers', {}, function()
        local cache = ensure_cache()
        return cache.unpastured_grazers
    end)
end

-- Returns all Pen/Pasture civzones.
-- Second return value is ok flag.
function get_pasture_zones()
    return safe('get_pasture_zones', {}, function()
        local result = {}
        for _, b in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
            if b.type == df.civzone_type.Pen then
                table.insert(result, b)
            end
        end
        return result
    end)
end

-- Returns the current season as a string: 'spring', 'summer', 'autumn', 'winter'.
-- Second return value is ok flag.
function get_season()
    return safe('get_season', 'unknown', function()
        local month = (df.global.cur_year_tick // (1200 * 28)) % 12
        if month < 3 then return 'spring'
        elseif month < 6 then return 'summer'
        elseif month < 9 then return 'autumn'
        else return 'winter'
        end
    end)
end

-- Returns all Farming Plot zones and their current crop assignments.
-- Result: list of { zone=b, plant_id=N, season=string } tables.
-- Second return value is ok flag.
function get_farm_plots()
    return safe('get_farm_plots', {}, function()
        local result = {}
        local season_names = {'spring', 'summer', 'autumn', 'winter'}
        for _, b in ipairs(df.global.world.buildings.all) do
            if b:getType() == df.building_type.FarmPlot then
                for si, sname in ipairs(season_names) do
                    local plant_id = b.plant_id[si - 1]
                    table.insert(result, { zone = b, plant_id = plant_id, season = sname, season_idx = si - 1 })
                end
            end
        end
        return result
    end)
end

-- Returns the current stock level snapshot for key resources.
-- Result: { food=N, drink=N, seeds=N, wood=N, stone=N } table.
-- Second return value is ok flag.
function check_stockpile_levels()
    return safe('check_stockpile_levels', { food=0, drink=0, seeds=0, wood=0, stone=0 }, function()
        local food, drink, seeds, wood, stone = 0, 0, 0, 0, 0

        local other = df.global.world.items.other

        -- Food items (prepared + raw plant/meat/fish)
        local food_cats = { 'MEAT', 'FISH', 'FISH_RAW', 'EGG', 'PLANT', 'PLANT_GROWTH', 'CHEESE', 'FOOD' }
        for _, cat in ipairs(food_cats) do
            if other[cat] then
                for _, it in ipairs(other[cat]) do
                    if not it.flags.forbid and not it.flags.dump and not it.flags.in_job then
                        food = food + 1
                    end
                end
            end
        end

        -- Drink items
        if other.DRINK then
            for _, it in ipairs(other.DRINK) do
                if not it.flags.forbid and not it.flags.dump and not it.flags.in_job then
                    drink = drink + (it.stack_size or 1)
                end
            end
        end

        -- Seeds
        if other.SEEDS then
            for _, it in ipairs(other.SEEDS) do
                if not it.flags.forbid and not it.flags.dump then
                    seeds = seeds + (it.stack_size or 1)
                end
            end
        end

        -- Wood logs
        if other.WOOD then
            for _, it in ipairs(other.WOOD) do
                if not it.flags.forbid and not it.flags.dump and not it.flags.in_job then
                    wood = wood + 1
                end
            end
        end

        -- Stone/rock
        local stone_cats = { 'BOULDER', 'ROUGH' }
        for _, cat in ipairs(stone_cats) do
            if other[cat] then
                for _, it in ipairs(other[cat]) do
                    if not it.flags.forbid and not it.flags.dump and not it.flags.in_job then
                        stone = stone + 1
                    end
                end
            end
        end

        return { food=food, drink=drink, seeds=seeds, wood=wood, stone=stone }
    end)
end

-- Returns list of active manager work orders and an ok flag.
function get_work_orders()
    return safe('get_work_orders', {}, function()
        local result = {}
        for _, order in ipairs(df.global.world.manager_orders) do
            table.insert(result, order)
        end
        return result
    end)
end

-- Returns the count of a specific work order by job_type currently in the queue.
-- Second return value is ok flag.
function count_work_orders(job_type_val)
    return safe('count_work_orders', 0, function()
        local count = 0
        for _, order in ipairs(df.global.world.manager_orders) do
            if order.job_type == job_type_val then
                count = count + order.amount_left
            end
        end
        return count
    end)
end

-- Returns a table with hydrology info for cistern-adjacent zones.
-- Each entry: { zone=b, water_level=N, capacity=N }
-- Second return value is ok flag.
function get_cistern_status()
    return safe('get_cistern_status', {}, function()
        local result = {}
        for _, b in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
            if b.type == df.civzone_type.WaterSource then
                -- Estimate fill level from tile water depth sum
                local total_depth = 0
                local tile_count = 0
                if b.room and b.room.extents then
                    for ex = 0, (b.room.width or 0) - 1 do
                        for ey = 0, (b.room.height or 0) - 1 do
                            local tx = b.room.x + ex
                            local ty = b.room.y + ey
                            local block = dfhack.maps.getTileBlock(tx, ty, b.z)
                            if block then
                                local liq = block.designation[tx % 16][ty % 16].flow_size
                                total_depth = total_depth + liq
                                tile_count = tile_count + 1
                            end
                        end
                    end
                end
                table.insert(result, {
                    zone = b,
                    water_level = total_depth,
                    capacity = tile_count * 7,  -- max depth is 7 per tile
                })
            end
        end
        return result
    end)
end

-- Returns all workshop buildings of a given type.
-- Second return value is ok flag.
function get_workshops(workshop_type)
    return safe('get_workshops', {}, function()
        local result = {}
        for _, b in ipairs(df.global.world.buildings.all) do
            if b:getType() == df.building_type.Workshop and b.type == workshop_type then
                table.insert(result, b)
            end
        end
        return result
    end)
end

-- Returns the noble assignment table mapping noble position codes to unit IDs.
-- Second return value is ok flag.
function get_noble_assignments()
    return safe('get_noble_assignments', {}, function()
        local assignments = {}
        local citizens, ok = get_citizens()
        if not ok then return assignments end
        for _, u in ipairs(citizens) do
            local noble_positions = dfhack.units.getNoblePositions(u)
            if noble_positions then
                for _, np in ipairs(noble_positions) do
                    if np.position and np.position.code then
                        assignments[np.position.code] = u.id
                    end
                end
            end
        end
        return assignments
    end)
end

-- Returns all active mandates for the current entity.
-- Each entry: { unit=u, item_type=N, item_subtype=N, amount=N, mandate_type=string }
-- Second return value is ok flag.
function get_active_mandates()
    return safe('get_active_mandates', {}, function()
        local result = {}
        local entity = df.historical_entity.find(df.global.plotinfo.civ_id)
        if not entity then return result end
        for _, mandate in ipairs(entity.mandates) do
            local u = df.unit.find(mandate.unit_id)
            table.insert(result, {
                unit = u,
                item_type = mandate.item_type,
                item_subtype = mandate.item_subtype,
                amount = mandate.amount_with_penalty,
                mandate_type = tostring(mandate.mode),
            })
        end
        return result
    end)
end

-- Returns the stress level of a citizen as a number. Higher = more stressed.
-- Thresholds: < -1000000 = legendary contentment, > 500000 = melancholy risk.
-- Second return value is ok flag.
function get_stress_level(u)
    return safe('get_stress_level', 0, function()
        return u.status.current_soul and u.status.current_soul.personality.stress or 0
    end)
end

-- Returns a list of citizens sorted by stress level descending.
-- Each entry: { unit=u, stress=N }
-- Second return value is ok flag.
function get_stressed_citizens(threshold)
    threshold = threshold or 200000  -- default: worry threshold
    return safe('get_stressed_citizens', {}, function()
        local citizens, ok = get_citizens()
        if not ok then return {} end
        local result = {}
        for _, u in ipairs(citizens) do
            local stress = u.status.current_soul and u.status.current_soul.personality.stress or 0
            if stress >= threshold then
                table.insert(result, { unit = u, stress = stress })
            end
        end
        table.sort(result, function(a, b) return a.stress > b.stress end)
        return result
    end)
end

-- Returns true if any military squad is currently on alert/active patrol.
-- Second return value is ok flag.
function is_military_active()
    return safe('is_military_active', false, function()
        for _, squad in ipairs(df.global.world.squads.all) do
            if squad.cur_alert_idx > 0 then return true end
        end
        return false
    end)
end

-- Returns a list of food/drink production buildings (kitchen, still, etc.).
-- Second return value is ok flag.
function get_production_buildings()
    return safe('get_production_buildings', {}, function()
        local result = {}
        local types = {
            df.workshop_type.Kitchen,
            df.workshop_type.Still,
            df.workshop_type.Butchers,
            df.workshop_type.Fishery,
            df.workshop_type.Quern,
            df.workshop_type.Millstone,
        }
        local type_set = {}
        for _, t in ipairs(types) do type_set[t] = true end
        for _, b in ipairs(df.global.world.buildings.all) do
            if b:getType() == df.building_type.Workshop and type_set[b.type] then
                table.insert(result, b)
            end
        end
        return result
    end)
end

-- Returns a list of seeds by plant type with counts.
-- Result: { [plant_id] = { name=string, count=N } }
-- Second return value is ok flag.
function get_seed_inventory()
    return safe('get_seed_inventory', {}, function()
        local inventory = {}
        local other = df.global.world.items.other
        if not other.SEEDS then return inventory end
        for _, it in ipairs(other.SEEDS) do
            if not it.flags.forbid and not it.flags.dump then
                local plant_id = it.mat_index
                if not inventory[plant_id] then
                    local raw = df.plant_raw.find(plant_id)
                    inventory[plant_id] = {
                        name = raw and raw.id or tostring(plant_id),
                        count = 0
                    }
                end
                inventory[plant_id].count = inventory[plant_id].count + (it.stack_size or 1)
            end
        end
        return inventory
    end)
end

-- Returns a list of kitchen exclusion rules.
-- Second return value is ok flag.
function get_kitchen_exclusions()
    return safe('get_kitchen_exclusions', {}, function()
        local result = {}
        local entity = df.historical_entity.find(df.global.plotinfo.civ_id)
        if not entity then return result end
        for _, ex in ipairs(entity.kitchen.exc_mat) do
            table.insert(result, { item_type = ex.item_type, item_subtype = ex.item_subtype, mat_type = ex.mat_type, mat_index = ex.mat_index })
        end
        return result
    end)
end

-- Returns the number of animals of a given race/caste that are tame and fort-controlled.
-- Second return value is ok flag.
function count_livestock_by_race(race_id, caste_id)
    return safe('count_livestock_by_race', 0, function()
        local count = 0
        local cache = ensure_cache()
        for _, u in ipairs(cache.livestock) do
            if u.race == race_id and (caste_id == nil or u.caste == caste_id) then
                count = count + 1
            end
        end
        return count
    end)
end

-- Returns a population breakdown of all tame livestock by race.
-- Result: { [race_id] = { name=string, count=N, male=N, female=N, gelded=N } }
-- Second return value is ok flag.
function get_livestock_census()
    return safe('get_livestock_census', {}, function()
        local census = {}
        local cache = ensure_cache()
        local U = dfhack.units
        for _, u in ipairs(cache.livestock) do
            local race = u.race
            if not census[race] then
                local raw = df.creature_raw.find(race)
                census[race] = {
                    name = raw and raw.name[0] or tostring(race),
                    count = 0, male = 0, female = 0, gelded = 0
                }
            end
            local entry = census[race]
            entry.count = entry.count + 1
            -- Caste 0 = male, caste 1 = female in most DF creature raws
            if u.caste == 0 then entry.male = entry.male + 1
            elseif u.caste == 1 then entry.female = entry.female + 1 end
            if u.flags2.gelded then entry.gelded = entry.gelded + 1 end
        end
        return census
    end)
end

-- Returns unit name as a formatted string.
-- Second return value is ok flag.
function get_unit_name(u)
    return safe('get_unit_name', 'unknown', function()
        return dfhack.TranslateName(u.name, true)
    end)
end

-- Returns a list of noble room requirements for the current nobles.
-- Each entry: { unit=u, role=string, needs={ bedroom=N, office=N, dining=N } }
-- where the N values are minimum room quality levels (0 = any, higher = better)
-- Second return value is ok flag.
function get_noble_room_requirements()
    return safe('get_noble_room_requirements', {}, function()
        local result = {}
        local citizens, ok = get_citizens()
        if not ok then return result end

        for _, u in ipairs(citizens) do
            local positions = dfhack.units.getNoblePositions(u)
            if positions then
                for _, np in ipairs(positions) do
                    if np.position then
                        local needs = {
                            bedroom = np.position.required_bedroom,
                            office = np.position.required_office,
                            dining = np.position.required_dining,
                        }
                        if needs.bedroom > 0 or needs.office > 0 or needs.dining > 0 then
                            table.insert(result, {
                                unit = u,
                                role = np.position.code,
                                needs = needs
                            })
                        end
                    end
                end
            end
        end
        return result
    end)
end

-- Returns which nobles have their room requirements satisfied.
-- Each entry: { unit=u, role=string, bedroom=bool, office=bool, dining=bool }
-- Second return value is ok flag.
function check_noble_room_satisfaction()
    return safe('check_noble_room_satisfaction', {}, function()
        local result = {}
        local citizens, ok = get_citizens()
        if not ok then return result end

        -- Build map of unit -> assigned rooms
        local owned_rooms = {}
        for _, b in ipairs(df.global.world.buildings.all) do
            local t = b:getType()
            if b.room and b.room.extents ~= nil and b.room.width > 0 then
                local owner_id = b.owner_id
                if owner_id == -1 and b.owner then
                    owner_id = b.owner.id
                end
                if owner_id and owner_id ~= -1 then
                    if not owned_rooms[owner_id] then
                        owned_rooms[owner_id] = { bedroom = false, office = false, dining = false }
                    end
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
        end

        for _, u in ipairs(citizens) do
            local positions = dfhack.units.getNoblePositions(u)
            if positions then
                for _, np in ipairs(positions) do
                    if np.position then
                        local needs = {
                            bedroom = np.position.required_bedroom,
                            office = np.position.required_office,
                            dining = np.position.required_dining,
                        }
                        if needs.bedroom > 0 or needs.office > 0 or needs.dining > 0 then
                            local rooms = owned_rooms[u.id] or {}
                            table.insert(result, {
                                unit = u,
                                role = np.position.code,
                                bedroom = rooms.bedroom or false,
                                office = rooms.office or false,
                                dining = rooms.dining or false,
                            })
                        end
                    end
                end
            end
        end
        return result
    end)
end

-- Internal helper: describe a job item requirement as a human-readable string.
local function describe_job_item(ji)
    local parts = {}
    if ji.item_type ~= -1 then
        local ok, name = pcall(function() return df.item_type[ji.item_type] end)
        if ok and name then table.insert(parts, tostring(name)) end
    end
    if ji.mat_type ~= -1 then
        local ok2, mname = pcall(function()
            return dfhack.matinfo.find(ji.mat_type, ji.mat_index) and
                   dfhack.matinfo.find(ji.mat_type, ji.mat_index):toString() or nil
        end)
        if ok2 and mname then table.insert(parts, mname) end
    end
    if ji.flags.silk then table.insert(parts, 'silk') end
    if ji.flags.wool then table.insert(parts, 'wool') end
    if ji.flags.plant_cloth then table.insert(parts, 'plant cloth') end
    if ji.flags.leather or ji.flags.skin_tanned then table.insert(parts, 'leather') end
    if ji.flags.bone then table.insert(parts, 'bone') end
    if ji.flags.shell then table.insert(parts, 'shell') end
    if ji.flags.wood then table.insert(parts, 'wood') end
    if ji.flags.metal then table.insert(parts, 'metal') end
    if ji.flags.stone then table.insert(parts, 'stone') end
    if ji.flags.glass then table.insert(parts, 'glass') end
    if ji.flags.clay then table.insert(parts, 'clay') end
    if ji.flags.body_part then table.insert(parts, 'body part') end
    if ji.flags.raw then table.insert(parts, 'rough gem') end
    if #parts == 0 then return 'unknown item' end
    return table.concat(parts, ' ')
end

return _ENV