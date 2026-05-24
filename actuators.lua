-- DwarfMind actuators: the write side of Sense → Think → Act.
-- Every game-state mutation flows through this module so all writes
-- are auditable in one place.  The dry_run flag logs intent without
-- touching game state — leave it true until you've tested for a full
-- fortress week without crashes.
--@ module = true

local _ENV = mkmodule('dwarfmind/actuators')

local logger = reqscript('dwarfmind/logger')
local log    = logger.for_module('actuators')

local dry_run = true  -- local, not exported; use set_dry_run() / is_dry_run()

function set_dry_run(val)
    if val then
        log.warn('dry_run ENABLED — no game state will be modified')
    else
        log.warn('dry_run DISABLED — game state mutations are LIVE')
    end
    dry_run = val
end

function is_dry_run()
    return dry_run
end

-- ─── Work Order Budget Coordinator ───────────────────────────────────────
-- Prevents multiple reflexes from spam-queueing manager orders in the
-- same tick, which could exceed the manager order limit.
--
-- Budget per slow tick: MAX_ORDERS_PER_TICK
-- Budget increment happens AFTER dry_run check so dry_run never consumes budget.
local MAX_ORDERS_PER_TICK = 8
local orders_this_tick = 0

-- Call at the start of each slow tick to reset the budget.
function reset_order_budget()
    orders_this_tick = 0
end

-- Returns true if we can queue more orders this tick.
function can_queue_order()
    return orders_this_tick < MAX_ORDERS_PER_TICK
end

-- Returns the number of orders remaining this tick.
function orders_remaining()
    return math.max(0, MAX_ORDERS_PER_TICK - orders_this_tick)
end

-- ─── Internal: safe action wrapper ───────────────────────────────────────
-- Like sensors.safe, but for writes. Returns (ok, result) where result is
-- the inner function's explicit return value if any, otherwise true.
local function safe_act(name, fn, ...)
    local ok, ret = dfhack.pcall(fn, ...)
    if not ok then
        log.warn(string.format('%s failed: %s', name, tostring(ret)))
        return false
    end
    -- Propagate inner return value if present
    return true, ret
end

-- ─── Unit labors ─────────────────────────────────────────────────────────
-- (disable_labor and enable_labor are defined later with proper nil guards)

-- Helper: Find a burrow pointer by its stable ID.
-- Uses 0-based indexing because burrows.list is a C++ vector.
local function find_burrow_by_id(burrow_id)
    local list = df.global.plotinfo.burrows.list
    for i = 0, #list - 1 do
        local b = list[i]
        if b.id == burrow_id then
            return b
        end
    end
    return nil
end

-- Assign a unit to a burrow by ID safely.
-- Uses dfhack.burrows.setAssignedUnit() for validated C++ API.
-- Returns true if successful (or would be, in dry_run mode).
function assign_unit_to_burrow(unit, burrow_id)
    if dry_run then
        log.info(string.format('DRY RUN: would assign %s to burrow ID %d',
            dfhack.units.getReadableName(unit), burrow_id))
        return true
    end
    return safe_act('assign_unit_to_burrow', function()
        local burrow = find_burrow_by_id(burrow_id)
        if burrow then
            dfhack.burrows.setAssignedUnit(burrow, unit, true)
            return true
        else
            log.warn('Burrow ID not found: ' .. tostring(burrow_id))
            return false
        end
    end)
end

-- Remove a unit from a burrow by ID safely.
-- Uses dfhack.burrows.setAssignedUnit() for validated C++ API.
-- Returns true if successful (or would be, in dry_run mode).
function remove_unit_from_burrow(unit, burrow_id)
    if dry_run then
        log.info(string.format('DRY RUN: would remove %s from burrow ID %d',
            dfhack.units.getReadableName(unit), burrow_id))
        return true
    end
    return safe_act('remove_unit_from_burrow', function()
        local burrow = find_burrow_by_id(burrow_id)
        if burrow then
            dfhack.burrows.setAssignedUnit(burrow, unit, false)
            return true
        else
            log.warn('Burrow ID not found: ' .. tostring(burrow_id))
            return false
        end
    end)
end

-- Ban cooking of a specific plant by raw ID (e.g. "MUSHROOM_HELMET_PLUMP").
-- Directly manipulates df.global.plotinfo.kitchen exclusion vectors.
-- Checks for existing exclusion first to avoid vector bloat from duplicate inserts.
function ban_plant_cooking(plant_raw_id)
    if dry_run then
        log.info(string.format('DRY RUN: would ban cooking of plant material %s',
            plant_raw_id))
        return true
    end
    return safe_act('ban_plant_cooking', function()
        local matinfo = dfhack.matinfo.find('PLANT_MAT:' .. plant_raw_id .. ':STRUCTURAL')
        if not matinfo then
            log.warn('could not find material info for plant ' .. plant_raw_id)
            return false
        end
        -- Directly manipulate kitchen exclusion vectors to avoid non-existent API
        local kitchen = df.global.plotinfo.kitchen
        if not kitchen then
            log.warn('kitchen data not available')
            return false
        end
        -- Check for existing exclusion to avoid duplicates
        for i = 0, #kitchen.excl_item_type - 1 do
            if kitchen.excl_item_type[i] == df.item_type.PLANT
               and kitchen.excl_mat_type[i] == matinfo.type
               and kitchen.excl_mat_index[i] == matinfo.index
               and kitchen.excl_type[i] == 0 then -- 0 = Cook
                log.debug('cooking already banned for plant material ' .. plant_raw_id)
                return true
            end
        end
        -- Add new exclusion
        kitchen.excl_item_type:insert('#', df.item_type.PLANT)
        kitchen.excl_mat_type:insert('#', matinfo.type)
        kitchen.excl_mat_index:insert('#', matinfo.index)
        kitchen.excl_type:insert('#', 0) -- Cook
        log.info('banned cooking of plant material ' .. plant_raw_id)
        return true
    end)
end

-- Unban cooking of a specific plant by raw ID (e.g. "MUSHROOM_HELMET_PLUMP").
-- Only removes Cook exclusions, not Brew (which might be independently set).
function unban_plant_cooking(plant_raw_id)
    if dry_run then
        log.info(string.format('DRY RUN: would unban cooking of plant material %s',
            plant_raw_id))
        return true
    end
    return safe_act('unban_plant_cooking', function()
        local matinfo = dfhack.matinfo.find('PLANT_MAT:' .. plant_raw_id .. ':STRUCTURAL')
        if not matinfo then
            log.warn('could not find material info for plant ' .. plant_raw_id)
            return false
        end
        -- Directly manipulate kitchen exclusion vectors to avoid non-existent API
        local kitchen = df.global.plotinfo.kitchen
        if not kitchen then
            log.warn('kitchen data not available')
            return false
        end
        -- Find and remove Cook exclusions for this plant material
        local i = 0
        while i < #kitchen.excl_item_type do
            if kitchen.excl_item_type[i] == df.item_type.PLANT
               and kitchen.excl_mat_type[i] == matinfo.type
               and kitchen.excl_mat_index[i] == matinfo.index
               and kitchen.excl_type[i] == 0 then -- 0 = Cook
                kitchen.excl_item_type:erase(i)
                kitchen.excl_mat_type:erase(i)
                kitchen.excl_mat_index:erase(i)
                kitchen.excl_type:erase(i)
                log.info('unbanned cooking of plant material ' .. plant_raw_id)
            else
                i = i + 1
            end
        end
        return true
    end)
end

-- (enable_labor and disable_labor with nil guards are defined below after mark_unit_for_slaughter)

-- ─── Script invocation ───────────────────────────────────────────────────
-- Call a DFHack script by name.  This is how the agent issues orders
-- without touching raw memory: it delegates to existing scripts whose
-- validators DF already trusts.
--
-- Work orders are budget-coordinated to avoid spam-cluttering the manager queue.
-- If order budget is exhausted, logs a warning and returns false.
--
-- Budget is NOT consumed in dry_run mode (increment happens after the check)
-- so budget stays clean during testing.
function run_script(name, ...)
    -- Check if this is a workorder script call that should be budget-controlled
    local is_workorder = (name == 'workorder')
    if is_workorder and not can_queue_order() then
        log.warn(string.format('order budget exhausted (%d/%d); skipping %s',
            orders_this_tick, MAX_ORDERS_PER_TICK, name))
        return false
    end

    if dry_run then
        -- Safely convert all args to strings for logging (handles numbers)
        local args = {...}
        for i, v in ipairs(args) do args[i] = tostring(v) end
        log.info('DRY RUN: dfhack.run_script(' .. name .. ', ' .. table.concat(args, ', ') .. ')')
        return true
    end

    -- Only consume budget on actual execution (after dry_run check)
    if is_workorder then
        orders_this_tick = orders_this_tick + 1
    end

    local ok, ret = safe_act(name, dfhack.run_script, name, ...)
    -- If the script failed and this was a workorder, refund the budget slot
    if not ok and is_workorder then
        orders_this_tick = math.max(0, orders_this_tick - 1)
    end
    return ok, ret
end

-- Call a DFHack command (plugin or built-in command) by name.
-- This is for C++ plugins like 'enable', 'autochop', 'autofarm', 'tailor'
-- which are NOT Lua scripts and cannot be invoked via run_script.
function run_command(name, ...)
    -- dfhack.run_command takes a single command string, not separate arguments.
    -- Concatenate all arguments into one space-separated command line.
    local args = {...}
    for i, v in ipairs(args) do args[i] = tostring(v) end
    local cmd = name
    if #args > 0 then
        cmd = cmd .. ' ' .. table.concat(args, ' ')
    end

    if dry_run then
        log.info('DRY RUN: dfhack.run_command(' .. cmd .. ')')
        return true
    end
    local ok, ret = safe_act(name, dfhack.run_command, cmd)
    return ok, ret
end

-- Unforbid a single item.
-- Returns true if the item was unforbidden (or would be, in dry_run mode).
function unforbid_item(item)
    if not item then
        log.warn('unforbid_item called with nil item')
        return false
    end
    if dry_run then
        log.info(string.format('DRY RUN: would unforbid item #%d (%s)',
            item.id, tostring(item)))
        return true
    end
    return safe_act('unforbid_item', function()
        item.flags.forbid = false
    end)
end

-- Mark a single item for trade at the depot.
-- Returns true if the item was marked (or would be, in dry_run mode).
function mark_item_for_trade(item, depot)
    if not item or not depot then
        log.warn('mark_item_for_trade called with nil item or depot')
        return false
    end
    if dry_run then
        log.info(string.format('DRY RUN: would mark item #%d for trade at depot #%d', item.id, depot.id))
        return true
    end
    return safe_act('mark_item_for_trade', function()
        item.flags2.for_trade = true
    end)
end

-- Set door forbidden state (lock/unlock doors).
-- Returns true if the door state was modified (or would be, in dry_run mode).
function set_door_forbidden(door, forbidden)
    if not door then
        log.warn('set_door_forbidden called with nil door')
        return false
    end
    if dry_run then
        log.info(string.format('DRY RUN: would set door #%d forbidden state to %s', door.id, tostring(forbidden)))
        return true
    end
    return safe_act('set_door_forbidden', function()
        door.door_flags.forbidden = forbidden
    end)
end

-- Sets the civilian alert state. If active is true, assigns the specified burrow_id to the alert and sounds the alarm.
-- If active is false, clears the alarm.
-- Finds or creates a 'civ-alert' alert by name rather than hardcoding index 1 (0-indexed vectors).
function set_civilian_alert(active, burrow_id)
    if dry_run then
        log.info(string.format('DRY RUN: would set civilian alert to %s (burrow ID %s)',
            tostring(active), tostring(burrow_id)))
        return true
    end
    return safe_act('set_civilian_alert', function()
        local list = df.global.plotinfo.alerts.list
        local civ_alert = nil
        local alert_idx = -1
        
        -- Find existing civ-alert entry (using 0-based vector indexing)
        for i = 0, #list - 1 do
            if list[i].name == 'civ-alert' then
                alert_idx = i
                civ_alert = list[i]
                break
            end
        end
        
        -- Create if not found
        if not civ_alert then
            civ_alert = df.alert_statest:new()
            civ_alert.id = df.global.plotinfo.alerts.next_id
            df.global.plotinfo.alerts.next_id = df.global.plotinfo.alerts.next_id + 1
            civ_alert.name = 'civ-alert'
            list:insert('#', civ_alert)
            alert_idx = #list - 1
        end

        if active then
            civ_alert.burrows:resize(0)
            if burrow_id then
                civ_alert.burrows:insert('#', burrow_id)
            end
            df.global.plotinfo.alerts.civ_alert_idx = alert_idx
            log.info("CIVILIAN ALERT: sounded alarm with burrow ID " .. tostring(burrow_id))
        else
            df.global.plotinfo.alerts.civ_alert_idx = -1
            log.info("CIVILIAN ALERT: cleared alarm")
        end
    end)
end

-- Sets an item's dump flag.
-- Returns true on success or if dry-run.
function mark_item_for_dump(item, dump)
    if not item then
        log.warn('mark_item_for_dump called with nil item')
        return false
    end
    if dry_run then
        log.info(string.format("DRY RUN: would set item #%d dump state to %s", item.id, tostring(dump)))
        return true
    end
    return safe_act('mark_item_for_dump', function()
        item.flags.dump = dump
    end)
end

-- Marks a unit for slaughter.
-- Returns true on success or if dry-run.
function mark_unit_for_slaughter(unit, slaughter)
    if not unit then
        log.warn('mark_unit_for_slaughter called with nil unit')
        return false
    end
    if dry_run then
        log.info(string.format("DRY RUN: would set unit #%d (%s) slaughter state to %s",
            unit.id, dfhack.units.getReadableName(unit), tostring(slaughter)))
        return true
    end
    return safe_act('mark_unit_for_slaughter', function()
        unit.flags2.slaughter = slaughter
    end)
end

-- Enable a single labor on a unit (e.g. df.unit_labor.MINE).
-- Returns true if the labor was enabled (or would be, in dry_run mode).
function enable_labor(unit, labor)
    if not unit then
        log.warn('enable_labor called with nil unit')
        return false
    end
    if dry_run then
        log.info(string.format('DRY RUN: would enable %s on %s',
            df.unit_labor[labor], dfhack.units.getReadableName(unit)))
        return true
    end
    return safe_act('enable_labor', function()
        unit.status.labors[labor] = true
    end)
end

-- Disable a single labor on a unit (e.g. df.unit_labor.MINE).
-- Returns true if the labor was disabled (or would be, in dry_run mode).
function disable_labor(unit, labor)
    if not unit then
        log.warn('disable_labor called with nil unit')
        return false
    end
    if dry_run then
        log.info(string.format('DRY RUN: would disable %s on %s',
            df.unit_labor[labor], dfhack.units.getReadableName(unit)))
        return true
    end
    return safe_act('disable_labor', function()
        unit.status.labors[labor] = false
    end)
end

-- Mark unit for gelding.
-- Returns true on success or if dry-run.
function mark_unit_for_gelding(unit, geld)
    if not unit then
        log.warn('mark_unit_for_gelding called with nil unit')
        return false
    end
    if dry_run then
        log.info(string.format("DRY RUN: would set unit #%d (%s) marked_for_gelding to %s",
            unit.id, dfhack.units.getReadableName(unit), tostring(geld)))
        return true
    end
    return safe_act('mark_unit_for_gelding', function()
        unit.flags3.marked_for_gelding = geld
    end)
end

-- ─── Thought injection ────────────────────────────────────────────────────
-- Injects a synthetic thought directly into the unit's personality thought
-- vector (unit.status.current_soul.personality.thoughts).
--
-- There is no DFHack helper for this — we write the unit_thought struct
-- directly.  Field layout verified against df-structures df.unit.xml:
--   unit_thought.type      (enum unit_thought_type)
--   unit_thought.subtype   (int16_t; -1 = no subtype)
--   unit_thought.age       (int32_t; ticks since thought was formed; 0 = brand new)
--   unit_thought.flags     (uint32_t bitfield; 0 = no special flags)
--
-- NOTE: thoughts is a 0-indexed C++ stl-vector.  :insert('#', obj) appends
-- to the end, which is safe — DF processes the full vector each mood tick.
--
-- Parameters:
--   unit         (df.unit)              — target unit; must not be nil
--   thought_type (df.unit_thought_type) — enum value, e.g. df.unit_thought_type.ATE_FINE_MEAL
--
-- Returns true on success (or in dry_run mode), false on any failure.
function add_thought(unit, thought_type)
    if not unit then
        log.warn('add_thought called with nil unit')
        return false
    end
    if dry_run then
        log.info(string.format('DRY RUN: would inject thought %s into %s',
            tostring(df.unit_thought_type[thought_type]),
            dfhack.units.getReadableName(unit)))
        return true
    end
    return safe_act('add_thought', function()
        -- Deep nil-guard: soul → personality → thoughts  (per RULE C)
        local soul = unit.status and unit.status.current_soul
        if not soul then
            log.warn(string.format('add_thought: unit #%d has no current_soul', unit.id))
            return false
        end
        local personality = soul.personality
        if not personality then
            log.warn(string.format('add_thought: unit #%d soul has no personality', unit.id))
            return false
        end
        local thoughts = personality.thoughts
        if not thoughts then
            log.warn(string.format('add_thought: unit #%d personality has no thoughts vector', unit.id))
            return false
        end

        local t = df.unit_thought:new()
        t.type    = thought_type
        t.subtype = -1   -- no item/creature subtype
        t.age     = 0    -- brand-new thought; DF will age it normally
        t.flags   = 0    -- no special flags

        thoughts:insert('#', t)

        log.info(string.format('add_thought: injected %s into %s',
            tostring(df.unit_thought_type[thought_type]),
            dfhack.units.getReadableName(unit)))
        return true
    end)
end

return _ENV
