-- DwarfMind reflex: werebeast lunar quarantine.
-- Scans for lycanthropy-infected citizens, calculates the calendar's day of the month
-- (moon cycle: 28 days), locks their bedroom doors on days 25-28, and unlocks them on day 1.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_quarantine')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_quarantine')

-- Reset function for save/load cycle.
-- Currently no persistent cooldown state, but the function is required by
-- ai_core.arm() so it must exist.  Add persistent cleanup here if tracking
-- is added in the future.
function reset()
    -- no persistent state to clear yet
end

-- BUG FIX: Previous check used ±1 on BOTH axes simultaneously, which
-- matched doors that were only diagonally adjacent (corner-touching) and
-- do not actually block movement in Dwarf Fortress.  The corrected version
-- requires the door to be orthogonally adjacent: exactly one axis is off by
-- 1 tile while the other axis falls within the room's span.
--
-- Orthogonal adjacency means the door is in one of the four cardinal
-- directions from the room boundary — North/South wall or East/West wall.
local function is_door_adjacent_to_room(door, room)
    if door.z ~= room.z then return false end

    local rx1, rx2 = room.room.x, room.room.x + room.room.width - 1
    local ry1, ry2 = room.room.y, room.room.y + room.room.height - 1

    local dx, dy = door.x1, door.y1

    -- North or South wall: dx within room x-span, dy one tile outside room y-span
    local on_ns_wall = (dx >= rx1 and dx <= rx2) and (dy == ry1 - 1 or dy == ry2 + 1)
    -- East or West wall: dy within room y-span, dx one tile outside room x-span
    local on_ew_wall = (dy >= ry1 and dy <= ry2) and (dx == rx1 - 1 or dx == rx2 + 1)

    return on_ns_wall or on_ew_wall
end

local function is_unit_in_room(unit, room)
    if unit.pos.z ~= room.z then return false end
    local rx1, rx2 = room.room.x, room.room.x + room.room.width - 1
    local ry1, ry2 = room.room.y, room.room.y + room.room.height - 1
    local ux, uy = unit.pos.x, unit.pos.y
    return ux >= rx1 and ux <= rx2 and uy >= ry1 and uy <= ry2
end

function run()
    if not sensors.is_fort_loaded() then return end

    local werebeasts, ok = sensors.get_werebeast_citizens()
    if not ok or #werebeasts == 0 then return end

    -- Get day of month (each month is 28 days, each day is 1200 ticks) from in-game calendar
    local day_of_month, day_ok = sensors.calendar_day()
    if not day_ok then return end

    -- Get all doors
    local doors, doors_ok = sensors.get_doors()
    if not doors_ok then return end

    -- Build lookup of beds designated as rooms owned by citizen IDs
    local citizen_beds = {}
    local all_bld = df.global.world.buildings.all
    for i = 0, #all_bld - 1 do
        local b = all_bld[i]
        if b:getType() == df.building_type.Bed then
            if df.building_bedst:is_instance(b) and b.room and b.room.extents ~= nil and b.room.width > 0 then
                local owner_id = b.owner_id
                if owner_id == -1 and b.owner then
                    owner_id = b.owner.id
                end
                if owner_id and owner_id ~= -1 then
                    citizen_beds[owner_id] = b
                end
            end
        end
    end

    -- BUG FIX: When a werebeast has no bedroom the previous code only logged a
    -- warning and did nothing, leaving the infected citizen free to roam and
    -- potentially wipe the fort.  We now fall back to assigning them to the
    -- "Safety" (or "Panic") emergency burrow during the danger window so they
    -- are at least contained within a defined zone.  The player is still warned
    -- loudly so they can build a proper bedroom.
    local safety_burrow_id = sensors.find_burrow_id_by_name('Safety')
                          or sensors.find_burrow_id_by_name('Panic')

    for _, u in ipairs(werebeasts) do
        local bed = citizen_beds[u.id]

        if not bed then
            -- No bedroom — emergency containment in Safety/Panic burrow if available
            log.warn(string.format(
                'CRITICAL: infected werebeast %s has no bedroom! Cannot use door-quarantine.',
                sensors.describe_unit(u)))
            if day_of_month >= 25 and day_of_month <= 28 then
                if safety_burrow_id then
                    log.warn(string.format(
                        'LUNAR QUARANTINE FALLBACK: Assigning %s to Safety burrow (day %d/28) — BUILD A BEDROOM!',
                        sensors.describe_unit(u), day_of_month))
                    actuators.assign_unit_to_burrow(u, safety_burrow_id)
                else
                    log.warn(string.format(
                        'LUNAR QUARANTINE FAILED: %s has no bedroom AND no Safety/Panic burrow. '
                        .. 'Infection spread risk is HIGH (day %d/28). Build a bedroom or define a Safety burrow!',
                        sensors.describe_unit(u), day_of_month))
                end
            elseif safety_burrow_id then
                -- Full moon passed — remove from emergency burrow if they were assigned there
                actuators.remove_unit_from_burrow(u, safety_burrow_id)
            end
            -- Skip door-locking logic for this unit
            goto continue
        end

        do
            -- Find adjacent doors (orthogonally only — see is_door_adjacent_to_room fix above)
            local adjacent_doors = {}
            for _, d in ipairs(doors) do
                if is_door_adjacent_to_room(d, bed) then
                    table.insert(adjacent_doors, d)
                end
            end

            -- Days 25-28: lock bedroom doors (full moon cycle)
            if day_of_month >= 25 and day_of_month <= 28 then
                if is_unit_in_room(u, bed) then
                    for _, door in ipairs(adjacent_doors) do
                        if not door.door_flags.forbidden then
                            log.warn(string.format(
                                'LUNAR QUARANTINE: Locking werebeast %s in bedroom (day %d/28) @ (%d,%d,%d)',
                                sensors.describe_unit(u), day_of_month, door.x1, door.y1, door.z))
                            actuators.set_door_forbidden(door, true)
                        end
                    end
                else
                    log.warn(string.format(
                        'CRITICAL LUNAR QUARANTINE WARNING: Infected werebeast %s is NOT in bedroom '
                        .. '(day %d/28)! Currently at (%d,%d,%d). Leaving door open.',
                        sensors.describe_unit(u), day_of_month, u.pos.x, u.pos.y, u.pos.z))
                end
            -- Days 1-24: unlock bedroom doors (werebeast is safe outside full moon)
            else
                for _, door in ipairs(adjacent_doors) do
                    if door.door_flags.forbidden then
                        log.warn(string.format(
                            'LUNAR QUARANTINE: Unlocking werebeast %s bedroom (day %d/28) @ (%d,%d,%d)',
                            sensors.describe_unit(u), day_of_month, door.x1, door.y1, door.z))
                        actuators.set_door_forbidden(door, false)
                    end
                end
            end
        end

        ::continue::
    end
end

return _ENV
