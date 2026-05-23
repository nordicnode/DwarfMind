-- DwarfMind reflex: workshop clutter clearing.
-- Periodically checks for cluttered workshops containing finished goods waiting to be hauled.
-- Automatically marks contained finished items for dumping to clear space and lift production speed penalties.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_garbage')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_garbage')

-- Cooldown to avoid spamming item updates.
local ACTION_COOLDOWN = 1200
local last_action = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    local cluttered, ok = sensors.get_cluttered_workshops()
    if not ok or #cluttered == 0 then return end

    local marked_count = 0
    for _, clut in ipairs(cluttered) do
        local bld = clut.building
        log.warn(string.format('workshop clutter: workshop #%d (%s) at (%d,%d,%d) is cluttered with %d items -> marking items for dump',
            bld.id, df.building_type[bld:getType()], bld.centerx, bld.centery, bld.z, #clut.items))
        
        for _, it in ipairs(clut.items) do
            local success = actuators.mark_item_for_dump(it, true)
            if success then
                marked_count = marked_count + 1
            end
        end
    end

    if marked_count > 0 then
        log.info(string.format('clutter cleanup: marked %d workshop item(s) for dumping to clear clutter', marked_count))
        last_action = now
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
