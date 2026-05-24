-- DwarfMind reflex: early-warning tantrum detection independent of raw stress score.
-- reflex_stress catches dwarves above STRESS_THRESHOLD=5000 and assigns them
-- to the spa. But a dwarf can enter a tantrum spiral from accumulated bad
-- thoughts (e.g. witnessing death, losing a loved one, tribute demands) without
-- ever breaching that threshold. This reflex monitors at a lower floor and
-- inspects the bad-thought list for high-weight persistent negatives.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_tantrum_watch')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_tantrum_watch')

-- Stress level below which we ignore the unit entirely (fast exit).
local IGNORE_BELOW       = 500
-- Stress floor that triggers a deep bad-thought inspection.
local TANTRUM_STRESS_FLOOR = 2500
-- How many ticks before we re-announce the same unit.
local ANNOUNCE_COOLDOWN  = 2400

-- Bad-thought type enums that carry heavy persistent weight and can trigger
-- tantrum moods independently of the raw stress integer.
-- Using df.unit_thought_type enum values for portability.
local HIGH_WEIGHT_THOUGHTS = {
    df.unit_thought_type.FELT_DEAD_UNIT_IN_FORT,
    df.unit_thought_type.LOST_LOVED_ONE,
    df.unit_thought_type.DEMANDED_TRIBUTE,
    df.unit_thought_type.KILLED_UNIT,
    df.unit_thought_type.COWORKER_DIED_AT_WORK,
    df.unit_thought_type.FELT_SCARED,
}
-- Build a lookup set for O(1) membership test.
local HIGH_WEIGHT_SET = {}
for _, t in ipairs(HIGH_WEIGHT_THOUGHTS) do
    HIGH_WEIGHT_SET[t] = true
end

-- How many high-weight thoughts a unit must have before we intervene.
local HIGH_THOUGHT_TRIGGER = 2

-- Per-unit announce cooldown table: [unit_id] = last_announce_tick
local last_announce = {}

-- Returns the count of high-weight bad thoughts currently active on `unit`.
local function count_heavy_thoughts(unit)
    local soul = unit.status.current_soul
    if not soul then return 0 end
    local thoughts = soul.personality.thoughts
    if not thoughts then return 0 end
    local count = 0
    for i = 0, #thoughts - 1 do
        local t = thoughts[i]
        if t and t.type and HIGH_WEIGHT_SET[t.type] then
            count = count + 1
        end
    end
    return count
end

-- Returns the current stress level from the unit soul, or nil on failure.
local function get_stress(unit)
    local soul = unit.status and unit.status.current_soul
    if not soul then return nil end
    return soul.personality.stress_level
end

-- Returns true if the unit is currently in an active bad mood / tantrum.
local function is_tantrumming(unit)
    local mood = unit.mood
    return mood == df.unit_mood_type.Berserk
        or mood == df.unit_mood_type.Tantrum
        or mood == df.unit_mood_type.Melancholy
end

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end

    -- Prune stale cooldown entries.
    for uid, last in pairs(last_announce) do
        if (now - last) >= ANNOUNCE_COOLDOWN then
            last_announce[uid] = nil
        end
    end

    local citizens, ok = sensors.get_citizens()
    if not ok then
        log.warn('get_citizens failed; skipping tantrum watch')
        return
    end

    for _, unit in ipairs(citizens) do
        if not unit or not unit.id then goto continue end

        -- Fast exit: already tantrumming (reflex_stress or player should handle)
        if is_tantrumming(unit) then
            local uid = unit.id
            local last = last_announce[uid] or -math.huge
            if (now - last) >= ANNOUNCE_COOLDOWN then
                log.err(string.format(
                    'TANTRUM: %s is actively tantrumming/berserk! Immediate intervention required.',
                    dfhack.TranslateName(unit.name, true)))
                last_announce[uid] = now
            end
            goto continue
        end

        local stress = get_stress(unit)
        if not stress then goto continue end
        if stress < IGNORE_BELOW then goto continue end

        -- Inspect at the lower floor for heavy thought accumulation.
        if stress >= TANTRUM_STRESS_FLOOR then
            local heavy = count_heavy_thoughts(unit)
            local uid   = unit.id
            local last  = last_announce[uid] or -math.huge

            if heavy >= HIGH_THOUGHT_TRIGGER and (now - last) >= ANNOUNCE_COOLDOWN then
                local name = dfhack.TranslateName(unit.name, true)
                log.warn(string.format(
                    'tantrum risk: %s (stress=%d, heavy thoughts=%d) — ' ..
                    'queuing fine meal consolation',
                    name, stress, heavy))

                -- Consolation intervention: queue a fine meal thought.
                -- This is a lightweight boost that does not require burrow
                -- assignment and will not conflict with reflex_stress spa logic.
                local ok_act, err_act = dfhack.pcall(function()
                    actuators.add_thought(unit,
                        df.unit_thought_type.ATE_FINE_MEAL)
                end)
                if not ok_act then
                    log.warn(string.format(
                        'add_thought failed for %s: %s', name, tostring(err_act)))
                end

                last_announce[uid] = now
            end
        end

        ::continue::
    end
end

function reset()
    last_announce = {}
end

return _ENV
