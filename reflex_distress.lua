-- DwarfMind reflex: monitor citizen distress.
-- Periodically checks citizen wellness indicators (hunger, thirst, sleep, injuries, strange moods).
-- Announces issues in the console log with name, symptoms, and coordinates.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_distress')

local sensors = reqscript('dwarfmind/sensors')
local logger  = reqscript('dwarfmind/logger')
local log     = logger.for_module('reflex_distress')

-- Cooldown so we don't spam the console with the same names every cycle.
-- Re-announce a given unit at most once per ANNOUNCE_INTERVAL ticks.
local ANNOUNCE_INTERVAL = 1500
local last_announce = {} -- [unit_id] = {tick=N, hist_id=N, birth=N}

-- One reflex cycle. Returns the number of distressed citizens detected.
function run()
    if not sensors.is_fort_loaded() then return 0 end

    local distressed, ok = sensors.get_distressed_citizens()
    if not ok then
        log.warn('get_distressed_citizens failed')
        return 0
    end
    local now, tick_ok = sensors.current_tick()
    if tick_ok and now >= 0 then
        -- Prune expired entries to prevent memory leaks from dead/departed units.
        for id, record in pairs(last_announce) do
            if (now - record.tick) >= ANNOUNCE_INTERVAL then
                last_announce[id] = nil
            end
        end
    else
        now = 0
    end

    if #distressed == 0 then
        log.debug('no distressed citizens')
        return 0
    end

    log.info(string.format('detected %d citizen(s) in distress', #distressed))

    for _, entry in ipairs(distressed) do
        local u = entry.unit
        local record = last_announce[u.id]

        -- Catch ID recycling
        if record and (record.hist_id ~= u.hist_figure_id or record.birth ~= u.birth_year) then
            record = nil
        end

        local last_tick = record and record.tick or -math.huge
        if (now - last_tick) >= ANNOUNCE_INTERVAL then
            local issues = {}
            if entry.thirst then
                local severity = entry.thirst > 50000 and "CRITICAL dehydration" or "dehydration"
                table.insert(issues, string.format('%s (thirst=%d)', severity, entry.thirst))
            end
            if entry.hunger then
                local severity = entry.hunger > 75000 and "CRITICAL starvation" or "hunger"
                table.insert(issues, string.format('%s (hunger=%d)', severity, entry.hunger))
            end
            if entry.sleepiness then
                local severity = entry.sleepiness > 150000 and "CRITICAL sleep deprivation"
                              or entry.sleepiness > 100000 and "severe drowsiness"
                              or "drowsiness"
                table.insert(issues, string.format('%s (sleepiness=%d)', severity, entry.sleepiness))
            end
            if entry.pain then
                table.insert(issues, string.format('severe pain (pain=%d)', entry.pain))
            end
            if entry.unconscious then
                table.insert(issues, string.format('unconscious (timer=%d)', entry.unconscious))
            end
            if entry.bleeding then
                table.insert(issues, 'bleeding/blood loss')
            end
            if entry.needs_hospital then
                table.insert(issues, 'requires medical attention / hospitalization')
            end
            if entry.mood_stuck_workshop then
                table.insert(issues, 'strange mood: STUCK waiting for a workshop')
            end
            if entry.mood_stuck_item then
                local missing_str = ""
                if entry.mood_missing_items and #entry.mood_missing_items > 0 then
                    missing_str = " (waiting for: " .. table.concat(entry.mood_missing_items, ", ") .. ")"
                end
                table.insert(issues, 'strange mood: STUCK waiting for materials/items' .. missing_str)
            end

            log.warn(string.format('  distressed: %s — Issues: %s',
                sensors.describe_unit(u), table.concat(issues, ', ')))
            last_announce[u.id] = {tick = now, hist_id = u.hist_figure_id, birth = u.birth_year}
        end
    end

    return #distressed
end

-- For tests / hot reloading: clear the cooldown table.
function reset()
    last_announce = {}
end

return _ENV
