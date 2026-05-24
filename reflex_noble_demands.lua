-- DwarfMind reflex: noble room deficits and active production mandates.
-- Monitors noble quarters deficits, queues furniture stockpiles, and automatically
-- satisfies noble mandates by queueing corresponding work orders.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_noble_demands')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_noble_demands')

-- Cooldown to avoid duplicate work orders.
local ACTION_COOLDOWN = 6000
local last_action = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end

    -- 1. Check noble room deficits
    local deficits, def_ok = sensors.get_noble_room_deficits()
    if def_ok and #deficits > 0 then
        for _, def in ipairs(deficits) do
            local name = dfhack.units.getReadableName(def.unit)
            local title = def.position.name[0] or "noble"
            local missing = {}
            if def.missing_bedroom then table.insert(missing, "bedroom") end
            if def.missing_office then table.insert(missing, "office") end
            if def.missing_dining then table.insert(missing, "dining room") end
            log.warn(string.format('noble quarters deficit: %s (%s) is missing assigned: %s',
                name, title, table.concat(missing, ', ')))
        end
    end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    -- 2. Maintain a baseline of unplaced room furniture for noble quarters
    -- We want to ensure at least 2 empty tables, chairs, cabinets, and chests (boxes) are in stock.
    local queued_any = false
    local world_orders = df.global.world.manager_orders

    local function count_queued(job_type)
        local n = 0
        for o = 0, #world_orders - 1 do
            local order = world_orders[o]
            if order.job_type == job_type then
                n = n + order.amount_left
            end
        end
        return n
    end

    -- We'll check stockpiled counts of furniture items using df.global.world.items.other
    local other = df.global.world.items.other
    local function count_stock(vec)
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

    local furniture = {
        { name = 'tables',    stock = count_stock(other.TABLE),    queued = count_queued(df.job_type.ConstructTable),    job = 'ConstructTable' },
        { name = 'chairs',    stock = count_stock(other.CHAIR),    queued = count_queued(df.job_type.ConstructChair),    job = 'ConstructChair' },
        { name = 'chests',    stock = count_stock(other.BOX),      queued = count_queued(df.job_type.ConstructBox),      job = 'ConstructBox' },
        { name = 'cabinets',  stock = count_stock(other.CABINET),  queued = count_queued(df.job_type.ConstructCabinet),  job = 'ConstructCabinet' },
    }

    for _, furn in ipairs(furniture) do
        local total = furn.stock + furn.queued
        if total < 2 then
            local deficit = 2 - total
            log.info(string.format('noble quarters support: %s stock low (%d stock, %d queued) -> queueing %d',
                furn.name, furn.stock, furn.queued, deficit))
            actuators.run_script('workorder', string.format('[{"job":"%s","amount_total":%d,"material_category":["stone"]}]', furn.job, deficit))
            queued_any = true
        end
    end

    -- 3. Fulfill active noble production mandates
    local mandates, mand_ok = sensors.check_active_mandates()
    if mand_ok and #mandates > 0 then
        for _, m in ipairs(mandates) do
            -- check if it is a production mandate (mode == 0 is manufacture)
            -- and has items remaining
            if m.mode == 0 and m.amount_remaining > 0 and m.job_type > -1 then
                local job_enum_name = df.job_type[m.job_type]
                if job_enum_name then
                    -- check if we already have a manager order for this job type
                    local already_ordered = false
                    for o = 0, #world_orders - 1 do
                        if world_orders[o].job_type == m.job_type then
                            already_ordered = true
                            break
                        end
                    end

                    if not already_ordered then
                        local mat_token = nil
                        if m.mat_type and m.mat_type > -1 then
                            local matinfo = dfhack.matinfo.decode(m.mat_type, m.mat_index)
                            if matinfo then
                                mat_token = matinfo:getToken()
                            end
                        end

                        if mat_token then
                            log.warn(string.format('mandate fulfillment: noble demands %d of %s (material %s) -> queueing workorder',
                                m.amount_remaining, job_enum_name, mat_token))
                            actuators.run_script('workorder', string.format('[{"job":"%s","amount_total":%d,"material":"%s"}]',
                                job_enum_name, m.amount_remaining, mat_token))
                        else
                            log.warn(string.format('mandate fulfillment: noble demands %d of %s -> queueing workorder',
                                m.amount_remaining, job_enum_name))
                            actuators.run_script('workorder', job_enum_name, tostring(m.amount_remaining))
                        end
                        queued_any = true
                    end
                end
            end
        end
    end

    if queued_any then
        last_action = now
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
