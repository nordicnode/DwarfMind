-- DwarfMind reflex: seed watch / plump helmet kitchen safety.
-- Monitors plump helmet spawn (seed) counts in the stockpile. If seeds
-- drop below a critical threshold, automatically bans cooking of plump
-- helmets to preserve the seed supply. Lifts the ban once stocks recover.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_seedwatch')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_seedwatch')

-- Seed count below which we ban cooking.
local DANGER_THRESHOLD = 20

-- Seed count at which we lift the cooking ban.
local SAFE_THRESHOLD = 50

-- The material raw ID for plump helmet spawn (PLANT_MAT token from raws).
local PLUMP_HELMET_TOKEN = 'MUSHROOM_HELMET_PLUMP'

-- Persistent ban status helpers using dfhack.persistent
local function get_persistent_ban()
    local entry = dfhack.persistent.get('dwarfmind/seedwatch_ban')
    return entry and entry.value == 'true'
end

local function set_persistent_ban(val)
    local entry = dfhack.persistent.get('dwarfmind/seedwatch_ban') or dfhack.persistent.save('dwarfmind/seedwatch_ban')
    entry.value = tostring(val)
end

-- Cooldown between checks.
local CHECK_INTERVAL = 600
local last_check = 0

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end

    -- Only check every CHECK_INTERVAL ticks
    if (now - last_check) < CHECK_INTERVAL then
        return
    end
    last_check = now

    -- Get current plump helmet seed count
    local seed_count, ok = sensors.get_plump_helmet_seed_count()
    if not ok then
        log.warn('get_plump_helmet_seed_count failed')
        return
    end

    log.debug(string.format('plump helmet seed count: %d (danger<%d, safe>%d)',
        seed_count, DANGER_THRESHOLD, SAFE_THRESHOLD))

    -- Check if cooking is currently banned
    local cooking_banned, ban_ok = sensors.is_plant_cooking_banned(PLUMP_HELMET_TOKEN)
    if not ban_ok then
        -- Try to determine state from our own tracking if sensor fails
        cooking_banned = get_persistent_ban()
    end

    if seed_count <= DANGER_THRESHOLD then
        -- DANGER: seeds critically low - ensure cooking is banned
        if not cooking_banned and not get_persistent_ban() then
            log.warn(string.format('SEED CRISIS: plump helmet seeds at %d (danger threshold: %d); banning cooking!',
                seed_count, DANGER_THRESHOLD))
            local success = actuators.ban_plant_cooking(PLUMP_HELMET_TOKEN)
            if success then
                set_persistent_ban(true)
                log.warn('PLUMP HELMET COOKING BANNED to preserve seeds. Will auto-lift when seeds recover.')
            end
        elseif cooking_banned then
            log.debug(string.format('plump helmet seeds still low (%d); cooking ban maintained', seed_count))
        end
    elseif seed_count >= SAFE_THRESHOLD then
        -- RECOVERY: seeds are safe - lift the ban if it was ours
        if get_persistent_ban() then
            log.info(string.format('SEED RECOVERY: plump helmet seeds at %d (safe threshold: %d); lifting cooking ban',
                seed_count, SAFE_THRESHOLD))
            local success = actuators.unban_plant_cooking(PLUMP_HELMET_TOKEN)
            if success then
                set_persistent_ban(false)
                log.info('Plump helmet cooking ban lifted; kitchens may now cook plump helmets.')
            end
        elseif cooking_banned then
            -- Ban was placed by someone else (player, other script); don't touch
            log.debug('plump helmet cooking is banned by external source; not interfering')
        end
    else
        -- MIDDLE GROUND: seeds between danger and safe
        if get_persistent_ban() then
            -- Keep the ban active until we hit SAFE_THRESHOLD
            log.debug(string.format('plump helmet seeds at %d; still below safe threshold (%d); maintaining ban',
                seed_count, SAFE_THRESHOLD))
        end
    end
end

function reset()
    last_check = 0
end

return _ENV