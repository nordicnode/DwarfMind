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
                if u.job and u.job.current_job ~= nil then return false end
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
        -- C++ vectors are 0-indexed; use numeric loop to capture element 0.
        local hostiles, livestock, grazers = {}, {}, {}
        for i = 0, #all_units - 1 do
            local u = all_units[i]
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
                    local u_refs = u.general_refs
                    for r = 0, #u_refs - 1 do
                        local ref = u_refs[r]
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
                local is_bleeding = false
                if u.body and u.body.blood_max and u.body.blood_max > 0 then
                    is_bleeding = u.body.blood_count < u.body.blood_max
                end
                if is_bleeding then
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
            for i = 0, #vec - 1 do
                local it = vec[i]
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
            for i = 0, #vec - 1 do
                local it = vec[i]
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
            if not u.job or not u.job.current_job then return end
            local job = u.job.current_job

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
                    local job_items = job.items
                    for j = 0, #job_items - 1 do
                        local ji_ref = job_items[j]
                        satisfied[ji_ref.job_item_idx] = true
                    end

                    local missing_cats = {}
                    local job_job_items = job.job_items
                    for idx = 0, #job_job_items - 1 do
                        local ji = job_job_items[idx]
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
        local traps = df.global.world.buildings.other.TRAP
        for i = 0, #traps - 1 do
            local b = traps[i]
            if b.trap_type == df.trap_type.Lever then
                local name = b.name or ""
                local has_pull = false
                local b_jobs = b.jobs
                for j = 0, #b_jobs - 1 do
                    if b_jobs[j].job_type == df.job_type.PullLever then
                        has_pull = true
                        break
                    end
                end

                -- Determine state of linked building(s)
                local state = nil
                local links = b.linked_mechanisms
                if links and #links > 0 then
                    for m_idx = 0, #links - 1 do
                        local m = links[m_idx]
                        local tref = dfhack.items.getGeneralRef(m, df.general_ref_type.BUILDING_HOLDER)
                        if tref then
                            local tg = tref:getBuilding()
                            if tg then
                                local btype = tg:getType()
                                if btype == df.building_type.Bridge then
                                    if tg.gate_flags.raised then
                                        state = "closed"
                                    elseif tg.gate_flags.raising then
                                        state = "closing"
                                    elseif tg.gate_flags.lowering then
                                        state = "opening"
                                    else
                                        state = "open"
                                    end
                                elseif btype == df.building_type.Weapon then
                                    if tg.gate_flags.retracted then
                                        state = "closed"
                                    else
                                        state = "open"
                                    end
                                else
                                    local ok, closed = pcall(function() return tg.gate_flags.closed end)
                                    if ok then
                                        if closed then
                                            state = "closed"
                                        elseif tg.gate_flags.closing then
                                            state = "closing"
                                        elseif tg.gate_flags.opening then
                                            state = "opening"
                                        else
                                            state = "open"
                                        end
                                    end
                                end
                                if state then break end
                            end
                        end
                    end
                end

                table.insert(levers, { building = b, name = name, has_pull_job = has_pull, state = state })
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
        local all_bld = df.global.world.buildings.all
        for i = 0, #all_bld - 1 do
            local bld = all_bld[i]
            if bld:getType() == df.building_type.Bed then
                local owner_id = bld.owner_id
                if owner_id == -1 and bld.owner then
                    owner_id = bld.owner.id
                end
                if owner_id and owner_id ~= -1 then
                    owned_beds[owner_id] = true
                end
            end
        end

        local homeless = 0
        for _, u in ipairs(citizens) do
            if not owned_beds[u.id] then
                homeless = homeless + 1
            end
        end

        local unowned_bedrooms = 0
        local all_bld = df.global.world.buildings.all
        for i = 0, #all_bld - 1 do
            local building = all_bld[i]
            if building:getType() == df.building_type.Bed then
                if building.room and building.room.extents ~= nil and building.room.width > 0 and building.owner_id == -1 then
                    unowned_bedrooms = unowned_bedrooms + 1
                end
            end
        end

        local unbuilt_beds = 0
        for i = 0, #all_bld - 1 do
            local bld = all_bld[i]
            if bld:getType() == df.building_type.Bed then
                -- Only count if the building is actually constructed (flags.exists)
                -- and not assigned to any owner, and NOT already in a designated room
                -- (those are counted in unowned_bedrooms to avoid double-counting).
                if bld.flags.exists then
                    local owner_id = bld.owner_id
                    if owner_id == -1 and bld.owner then
                        owner_id = bld.owner.id
                    end
                    local in_room = (bld.room and bld.room.extents ~= nil and bld.room.width > 0)
                    if owner_id == -1 and not in_room and not bld.flags.forbid and not bld.flags.dump then
                        unbuilt_beds = unbuilt_beds + 1
                    end
                end
            end
        end

        local queued_beds = 0
        local mgr_orders = df.global.world.manager_orders
        for i = 0, #mgr_orders - 1 do
            local order = mgr_orders[i]
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
        local all_bld = df.global.world.buildings.all
        for i = 0, #all_bld - 1 do
            local bld = all_bld[i]
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
        local caravans = df.global.plotinfo.caravans
        for i = 0, #caravans - 1 do
            table.insert(result, caravans[i])
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
        local all_bld = df.global.world.buildings.all
        for i = 0, #all_bld - 1 do
            local door = all_bld[i]
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
                for p = 0, #noble_positions - 1 do
                    local pos = noble_positions[p]
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
            for i = 0, #other.SPLINT - 1 do
                local it = other.SPLINT[i]
                if is_valid(it) then splints = splints + 1 end
            end
        end

        if other.CRUTCH then
            for i = 0, #other.CRUTCH - 1 do
                local it = other.CRUTCH[i]
                if is_valid(it) then crutches = crutches + 1 end
            end
        end

        if other.BUCKET then
            for i = 0, #other.BUCKET - 1 do
                local it = other.BUCKET[i]
                if is_valid(it) then buckets = buckets + 1 end
            end
        end

        if other.BAR then
            for b = 0, #other.BAR - 1 do
                local it = other.BAR[b]
                if is_valid(it) then
                    local mat = dfhack.matinfo.decode(it:getMaterial(), it:getMaterialIndex())
                    if mat and mat.material and mat.material.flags.SOAP then
                        soap = soap + (it.stack_size > 0 and it.stack_size or 1)
                    end
                end
            end
        end

        if other.POWDER_MISC then
            for i = 0, #other.POWDER_MISC - 1 do
                local it = other.POWDER_MISC[i]
                if is_valid(it) then
                    local mat = dfhack.matinfo.decode(it:getMaterial(), it:getMaterialIndex())
                    if mat and mat.inorganic then
                        local mid = mat.inorganic.id
                        if mid == "GYPSUM" or mid == "ALABASTER" or mid == "SELENITE" or mid == "SATINSPAR" then
                            plaster = plaster + (it.stack_size > 0 and it.stack_size or 1)
                        end
                    elseif mat and mat.material then
                        -- Fallback: check material token directly with exact match
                        local token = mat:getToken() or ""
                        if token == "GYPSUM" or token == "ALABASTER" or token == "SELENITE" or token == "SATINSPAR" then
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

        local mgr_orders = df.global.world.manager_orders
        for o = 0, #mgr_orders - 1 do
            local order = mgr_orders[o]
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
        local U = dfhack.units
        local dead_citizens = 0
        local unburied_citizens = 0

        -- Track assigned tombs/graves
        local owned_graves = {}
        local all_buildings = df.global.world.buildings.all
        for i = 0, #all_buildings - 1 do
            local b = all_buildings[i]
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
        local all_units_vec = df.global.world.units.all
        for i = 0, #all_units_vec - 1 do
            local u = all_units_vec[i]
            if U.isCitizen(u) and U.isDead(u) then
                dead_citizens = dead_citizens + 1
                if not owned_graves[u.id] then
                    unburied_citizens = unburied_citizens + 1
                end
            end
        end

        local unplaced_coffins = 0
        if df.global.world.items.other.COFFIN then
            local coffin_vec = df.global.world.items.other.COFFIN
            for i = 0, #coffin_vec - 1 do
                local coffin = coffin_vec[i]
                if not coffin.flags.in_building and not coffin.flags.forbid and not coffin.flags.dump and not coffin.flags.removed then
                    unplaced_coffins = unplaced_coffins + 1
                end
            end
        end

        local queued_coffins = 0
        local mgr_orders2 = df.global.world.manager_orders
        for i = 0, #mgr_orders2 - 1 do
            local order = mgr_orders2[i]
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
            for z = 0, #zones - 1 do
                local bld = zones[z]
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
        local burrows = df.global.plotinfo.burrows.list
        for b = 0, #burrows - 1 do
            local burrow = burrows[b]
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
            local squads = df.global.plotinfo.equipment.squads
            for s = 0, #squads - 1 do
                local positions = squads[s].positions
                for p = 0, #positions - 1 do
                    if positions[p].occupant > -1 then
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
            for h = 0, #other.HELM - 1 do
                if is_valid_metal_gear(other.HELM[h]) then helms = helms + 1 end
            end
        end

        if other.ARMOR then
            for a = 0, #other.ARMOR - 1 do
                if is_valid_metal_gear(other.ARMOR[a]) then breastplates = breastplates + 1 end
            end
        end

        if other.PANTS then
            for p = 0, #other.PANTS - 1 do
                if is_valid_metal_gear(other.PANTS[p]) then greaves = greaves + 1 end
            end
        end

        if other.SHIELD then
            for sh = 0, #other.SHIELD - 1 do
                local it = other.SHIELD[sh]
                local f = it.flags
                if not f.forbid and not f.dump and not f.garbage_collect and not f.removed and not f.in_building then
                    shields = shields + 1
                end
            end
        end

        if other.WEAPON then
            for w = 0, #other.WEAPON - 1 do
                if is_valid_metal_gear(other.WEAPON[w]) then weapons = weapons + 1 end
            end
        end

        local queued_helms = 0
        local queued_breastplates = 0
        local queued_greaves = 0
        local queued_shields = 0
        local queued_weapons = 0

        local mgr_orders = df.global.world.manager_orders
        for o = 0, #mgr_orders - 1 do
            local jt = mgr_orders[o].job_type
            if jt == df.job_type.MakeArmor then
                queued_breastplates = queued_breastplates + mgr_orders[o].amount_left
            elseif jt == df.job_type.MakeHelm then
                queued_helms = queued_helms + mgr_orders[o].amount_left
            elseif jt == df.job_type.MakePants then
                queued_greaves = queued_greaves + mgr_orders[o].amount_left
            elseif jt == df.job_type.MakeShield then
                queued_shields = queued_shields + mgr_orders[o].amount_left
            elseif jt == df.job_type.MakeWeapon then
                queued_weapons = queued_weapons + mgr_orders[o].amount_left
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
            for w = 0, #workshops - 1 do
                local bld = workshops[w]
                if bld.flags.exists then
                    local clutter_items = {}
                    local contained = bld.contained_items
                    for c = 0, #contained - 1 do
                        local bi = contained[c]
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
        local all_bld = df.global.world.buildings.all
        for i = 0, #all_bld - 1 do
            local b = all_bld[i]
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
                for p = 0, #noble_positions - 1 do
                    local np = noble_positions[p]
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
            local mandates = df.global.world.mandates.all
            for m = 0, #mandates - 1 do
                table.insert(result, mandates[m])
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
            local burrows = df.global.plotinfo.burrows.list
            for b = 0, #burrows - 1 do
                if burrows[b].id == spa_id then
                    spa_burrow = burrows[b]
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
            local inv = u.inventory
            for iv = 0, #inv - 1 do
                local item = inv[iv].item
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
            for p = 0, #other.PANTS - 1 do
                if is_valid_civilian_clothing(other.PANTS[p]) then stock.pants = stock.pants + 1 end
            end
        end
        -- Note: Torso civilian clothes (shirts, dresses, etc.) live in the ARMOR vector
        if other.ARMOR then
            for a = 0, #other.ARMOR - 1 do
                if is_valid_civilian_clothing(other.ARMOR[a]) then stock.shirts = stock.shirts + 1 end
            end
        end
        if other.SHOES then
            for s = 0, #other.SHOES - 1 do
                if is_valid_civilian_clothing(other.SHOES[s]) then stock.shoes = stock.shoes + 1 end
            end
        end
        
        return stock
    end)
end

-- ─── Ammunition & Siege Ammo ───────────────────────────────────────────
-- Returns ammo stock status:
-- { ammo=N, siege_ammo=N, queued_ammo=N, queued_siege=N, soldiers=N }
-- Second return value is the ok flag.
function check_ammo_status()
    return safe('check_ammo_status', {
        ammo = 0, siege_ammo = 0, queued_ammo = 0, queued_siege = 0, soldiers = 0
    }, function()
        local ammo_count = 0
        local siege_count = 0

        local function is_valid(it)
            local f = it.flags
            return not f.forbid and not f.dump and not f.garbage_collect and not f.removed and not f.in_building
        end

        local other = df.global.world.items.other
        if other.AMMO then
            for a = 0, #other.AMMO - 1 do
                if is_valid(other.AMMO[a]) then
                    ammo_count = ammo_count + 1
                end
            end
        end

        if other.SIEGEAMMO then
            for s = 0, #other.SIEGEAMMO - 1 do
                if is_valid(other.SIEGEAMMO[s]) then
                    siege_count = siege_count + 1
                end
            end
        end

        local queued_ammo = 0
        local queued_siege = 0
        local mgr_orders = df.global.world.manager_orders
        for o = 0, #mgr_orders - 1 do
            local jt = mgr_orders[o].job_type
            if jt == df.job_type.MakeAmmo then
                queued_ammo = queued_ammo + mgr_orders[o].amount_left
            elseif jt == df.job_type.AssembleSiegeAmmo then
                queued_siege = queued_siege + mgr_orders[o].amount_left
            end
        end

        local soldiers = 0
        if df.global.plotinfo and df.global.plotinfo.equipment and df.global.plotinfo.equipment.squads then
            local squads = df.global.plotinfo.equipment.squads
            for s = 0, #squads - 1 do
                local positions = squads[s].positions
                for p = 0, #positions - 1 do
                    if positions[p].occupant > -1 then
                        soldiers = soldiers + 1
                    end
                end
            end
        end

        return {
            ammo = ammo_count,
            siege_ammo = siege_count,
            queued_ammo = queued_ammo,
            queued_siege = queued_siege,
            soldiers = soldiers,
        }
    end)
end

-- ─── Pets ────────────────────────────────────────────────────────────────
-- Returns tame pet units matching the given creature raw ID (e.g. "CAT").
-- Each result is a raw df.unit object. Second return value is the ok flag.
function get_pets_by_race(creature_id)
    return safe('get_pets_by_race', {}, function()
        local result = {}
        local all_units = df.global.world.units.active
        local U = dfhack.units
        for i = 0, #all_units - 1 do
            local u = all_units[i]
            if U.isActive(u) and U.isAlive(u) and U.isTame(u) and U.isPet(u)
               and not U.isBaby(u) and not U.isChild(u)
               and not u.flags1.caged and not u.flags1.chained then
                local ok_race, craw = pcall(function() return df.creature_raw.find(u.race) end)
                if ok_race and craw and craw.creature_id == creature_id then
                    table.insert(result, u)
                end
            end
        end
        return result
    end)
end

-- ─── Justice & Law Enforcement ───────────────────────────────────────────
-- Returns justice system status:
-- { has_sheriff=bool, jailed_count=N, jailed_distressed=N,
--   chain_count=N, cage_count=N, queued_chains=N, queued_cages=N }
-- Second return value is the ok flag.
function check_justice_status()
    return safe('check_justice_status', {
        has_sheriff = false, jailed_count = 0, jailed_distressed = 0,
        chain_count = 0, cage_count = 0, queued_chains = 0, queued_cages = 0
    }, function()
        -- 1. Check for Sheriff or Captain of the Guard
        local has_sheriff = false
        local citizens = get_citizens()
        for _, u in ipairs(citizens) do
            local noble_positions = dfhack.units.getNoblePositions(u)
            if noble_positions then
                for p = 0, #noble_positions - 1 do
                    local code = noble_positions[p].position.code
                    if code == 'SHERIFF' or code == 'CAPTAIN_OF_THE_GUARD' then
                        has_sheriff = true
                        break
                    end
                end
            end
            if has_sheriff then break end
        end

        -- 2. Check jailed prisoners and their wellness
        local jailed_count = 0
        local jailed_distressed = 0
        local punishments = df.global.plotinfo.punishments
        for i = 0, #punishments - 1 do
            local p = punishments[i]
            if p.prison_counter > 0 then
                jailed_count = jailed_count + 1
                local u = df.unit.find(p.criminal)
                if u then
                    local thirst = u.counters2 and u.counters2.thirst_timer or 0
                    local hunger = u.counters2 and u.counters2.hunger_timer or 0
                    if thirst > 20000 or hunger > 30000 then
                        jailed_distressed = jailed_distressed + 1
                    end
                end
            end
        end

        -- 3. Count available restraints
        local function count_restraint(vec)
            if not vec then return 0 end
            local n = 0
            for v = 0, #vec - 1 do
                local it = vec[v]
                local f = it.flags
                if not f.in_building and not f.forbid and not f.dump and not f.removed then
                    n = n + 1
                end
            end
            return n
        end

        local other = df.global.world.items.other
        local chain_count = count_restraint(other.CHAIN)
        local cage_count = count_restraint(other.CAGE)

        local queued_chains = 0
        local queued_cages = 0
        -- Resolve job type enums safely; if an enum is missing the count stays 0.
        local make_chain_ok, make_chain_jt = pcall(function() return df.job_type.MakeChain end)
        local make_cage_ok, make_cage_jt = pcall(function() return df.job_type.MakeCage end)
        local mgr_orders = df.global.world.manager_orders
        for o = 0, #mgr_orders - 1 do
            local jt = mgr_orders[o].job_type
            if make_chain_ok and jt == make_chain_jt then
                queued_chains = queued_chains + mgr_orders[o].amount_left
            elseif make_cage_ok and jt == make_cage_jt then
                queued_cages = queued_cages + mgr_orders[o].amount_left
            end
        end

        return {
            has_sheriff = has_sheriff,
            jailed_count = jailed_count,
            jailed_distressed = jailed_distressed,
            chain_count = chain_count,
            cage_count = cage_count,
            queued_chains = queued_chains,
            queued_cages = queued_cages,
        }
    end)
end

-- ─── Seed Watch / Kitchen Safety ─────────────────────────────────────────
-- Second return value is the ok flag.
function get_plump_helmet_seed_count()
    return safe('get_plump_helmet_seed_count', 0, function()
        local count = 0
        local other = df.global.world.items.other
        if other.SEEDS then
            for s = 0, #other.SEEDS - 1 do
                local seed = other.SEEDS[s]
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
        
        local kitchen = df.global.plotinfo.kitchen
        if not kitchen then return false end
        for i = 0, #kitchen.excl_item_type - 1 do
            if kitchen.excl_item_type[i] == df.item_type.PLANT 
               and kitchen.excl_mat_type[i] == matinfo.type 
               and kitchen.excl_mat_index[i] == matinfo.index
               and kitchen.excl_type[i] == 0 then -- 0 is Cook
                return true
            end
        end
        return false
    end)
end

-- Returns a table of metal bar counts in stock: { steel = N, iron = N, bronze = N, copper = N }
-- Second return value is the ok flag.
function get_metal_bars_stock()
    return safe('get_metal_bars_stock', { steel = 0, iron = 0, bronze = 0, copper = 0 }, function()
        local stock = { steel = 0, iron = 0, bronze = 0, copper = 0 }
        local other = df.global.world.items.other
        if other.BAR then
            for b = 0, #other.BAR - 1 do
                local it = other.BAR[b]
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

-- Returns counts of ash bars in stock.
-- Second return value is the ok flag.
function get_ash_count()
    return safe('get_ash_count', 0, function()
        local count = 0
        local other = df.global.world.items.other
        if other.BAR then
            for b = 0, #other.BAR - 1 do
                local it = other.BAR[b]
                local f = it.flags
                if not f.forbid and not f.dump and not f.garbage_collect and not f.removed and not f.in_building then
                    if it:getMaterial() == df.builtin_mats.ASH then
                        count = count + (it.stack_size > 0 and it.stack_size or 1)
                    end
                end
            end
        end
        return count
    end)
end

-- Returns counts of lye in stock (typically in buckets).
-- Second return value is the ok flag.
function get_lye_count()
    return safe('get_lye_count', 0, function()
        local count = 0
        local other = df.global.world.items.other
        if other.LIQUID_MISC then
            for i = 0, #other.LIQUID_MISC - 1 do
                local it = other.LIQUID_MISC[i]
                local f = it.flags
                if not f.forbid and not f.dump and not f.garbage_collect and not f.removed and not f.in_building then
                    if it:getMaterial() == df.builtin_mats.LYE then
                        count = count + (it.stack_size > 0 and it.stack_size or 1)
                    end
                end
            end
        end
        return count
    end)
end

-- Returns counts of tallow (animal fats) and oil (vegetable oils) in stock.
-- Second return value is the ok flag.
function get_tallow_oil_count()
    return safe('get_tallow_oil_count', 0, function()
        local count = 0
        local other = df.global.world.items.other
        
        -- Count globs (tallow is a glob)
        if other.GLOB then
            for i = 0, #other.GLOB - 1 do
                local it = other.GLOB[i]
                local f = it.flags
                if not f.forbid and not f.dump and not f.garbage_collect and not f.removed and not f.in_building then
                    local mat = dfhack.matinfo.decode(it:getMaterial(), it:getMaterialIndex())
                    if mat and mat.material then
                        local token = mat:getToken() or ""
                        if token:find('TALLOW') or token:find('FAT') then
                            count = count + (it.stack_size > 0 and it.stack_size or 1)
                        end
                    end
                end
            end
        end
        
        -- Count LIQUID_MISC for oil (oils are liquids)
        if other.LIQUID_MISC then
            for i = 0, #other.LIQUID_MISC - 1 do
                local it = other.LIQUID_MISC[i]
                local f = it.flags
                if not f.forbid and not f.dump and not f.garbage_collect and not f.removed and not f.in_building then
                    local mat = dfhack.matinfo.decode(it:getMaterial(), it:getMaterialIndex())
                    if mat and mat.material then
                        local token = mat:getToken() or ""
                        if token:find('OIL') then
                            count = count + (it.stack_size > 0 and it.stack_size or 1)
                        end
                    end
                end
            end
        end
        
        return count
    end)
end

return _ENV
