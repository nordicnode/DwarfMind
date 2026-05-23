-- DwarfMind reflex: werebeast lunar quarantine.
-- Scans for lycanthropy-infected citizens, calculates the calendar's day of the month
-- (moon cycle: 28 days), locks their bedroom doors on days 25-28, and unlocks them on day 1.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_quarantine')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_quarantine')

-- Reset function for save/load cycle — no persistent state currently but
-- added so future cooldowns/tracking survive fortress reloads.
function reset()
end

local function is_door_adjacent_to_room(door, room)
    if door.z ~= room.z then return false end
    
    local rx1, rx2 = room.room.x, room.room.x + room.room.width - 1
    local ry1, ry2 = room.room.y, room.room.y + room.room.height - 1
    
    local dx, dy = door.x1, door.y1
    -- Check if door is within [room.x - 1, room.x + room.width]
    -- and [room.y - 1, room.y + room.height]
    if dx >= rx1 - 1 and dx <= rx2 + 1 and dy >= ry1 - 1 and dy <= ry2 + 1 then
        return true
    end
    return false
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
    for _, b in ipairs(df.global.world.buildings.other.BED) do
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

    for _, u in ipairs(werebeasts) do
        -- Find their bedroom bed
        local bed = citizen_beds[u.id]

        if bed then
            -- Find adjacent doors
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
                            log.warn(string.format('LUNAR QUARANTINE: Locking werebeast %s in bedroom (day %d/28) @ (%d,%d,%d)',
                                sensors.describe_unit(u), day_of_month, door.x1, door.y1, door.z))
                            actuators.set_door_forbidden(door, true)
                        end
                    end
                else
                    log.warn(string.format('CRITICAL LUNAR QUARANTINE WARNING: Infected werebeast %s is NOT in bedroom (day %d/28)! Currently at (%d,%d,%d). Leaving door open.',
                        sensors.describe_unit(u), day_of_month, u.pos.x, u.pos.y, u.pos.z))
                end
            -- Days 1-24: unlock bedroom doors (werebeast is safe outside full moon)
            else
                for _, door in ipairs(adjacent_doors) do
                    if door.door_flags.forbidden then
                        log.warn(string.format('LUNAR QUARANTINE: Unlocking werebeast %s bedroom (day %d/28) @ (%d,%d,%d)',
                            sensors.describe_unit(u), day_of_month, door.x1, door.y1, door.z))
                        actuators.set_door_forbidden(door, false)
                    end
                end
            end
        else
            -- Infected citizen has no bedroom! Warn player loudly.
            log.warn(string.format('CRITICAL: infected werebeast %s has no bedroom bed! Cannot quarantine automatically!',
                sensors.describe_unit(u)))
        end
    end
end

return _ENV
