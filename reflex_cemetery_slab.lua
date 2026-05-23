-- DwarfMind reflex: slab manager.
-- Periodically checks blank stone slab stock.
-- Enables the C++ 'autoslab' plugin.
-- Queues ConstructSlab work orders if blank slab stock is low (<3).
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_cemetery_slab')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_cemetery_slab')

-- Cooldown to avoid spamming the plugin enable / work orders.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

-- ─── Helpers ─────────────────────────────────────────────────────────────
local function count_blank_slabs()
    local count = 0
    if df.global.world.items.other.SLAB then
        for _, slab in ipairs(df.global.world.items.other.SLAB) do
            local f = slab.flags
            if not f.in_building and not f.forbid and not f.dump and not f.removed then
                if df.item_slabst:is_instance(slab) then
                    local slab_cast = df.item_slabst:interpret(slab)
                    -- Check if slab is blank (i.e. not engraved)
                    local is_blank = true
                    if slab_cast.engraving_type ~= -1 and slab_cast.engraving_type ~= 0 then
                        if df.slab_engraving_type then
                            if slab_cast.engraving_type == df.slab_engraving_type.Memorial or slab_cast.engraving_type == df.slab_engraving_type.Secrets then
                                is_blank = false
                            end
                        else
                            is_blank = false
                        end
                    end
                    if slab_cast.description and slab_cast.description ~= "" then
                        is_blank = false
                    end
                    
                    if is_blank then
                        count = count + 1
                    end
                end
            end
        end
    end
    return count
end

-- ─── Reflex cycle ────────────────────────────────────────────────────────
function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end

    if (now - last_action) < ACTION_COOLDOWN then return end

    -- 1. Ensure C++ autoslab plugin is enabled
    actuators.run_script('enable', 'autoslab')

    -- 2. Audit blank slabs
    local blank_count = count_blank_slabs()

    -- 3. Audit queued slab work orders
    local queued_slabs = 0
    for _, order in ipairs(df.global.world.manager_orders) do
        if order.job_type == df.job_type.ConstructSlab then
            queued_slabs = queued_slabs + order.amount_left
        end
    end

    local total_available = blank_count + queued_slabs
    log.info(string.format('cemetery slab status: blank slabs in stock = %d, queued = %d, total = %d',
        blank_count, queued_slabs, total_available))

    if total_available < 3 then
        local deficit = 3 - total_available
        log.warn(string.format('blank slab supply low: %d (threshold < 3) -> queueing %d ConstructSlab orders',
            total_available, deficit))
        actuators.run_script('workorder', 'ConstructSlab', tostring(deficit))
        last_action = now
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
