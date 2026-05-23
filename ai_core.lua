-- DwarfMind core: lifecycle, scheduler, and tick dispatch.
-- All behavior modules are invoked from here. The module owns no game
-- state — only the registry of cadences and the state-change hook.
--@ module = true

local _ENV = mkmodule('dwarfmind/ai_core')

local repeatUtil   = require('repeat-util')
local eventful     = require('eventful')
local logger       = reqscript('dwarfmind/logger')
local log          = logger.for_module('ai_core')
local sensors      = reqscript('dwarfmind/sensors')

-- ─── Reflexes ────────────────────────────────────────────────────────────────
-- Each module is loaded lazily on first arm() call and cached here.
local R = {}

local REFLEX_MODULES = {
    'mood_helper', 'medical', 'production', 'cemetery', 'cemetery_slab',
    'quarantine', 'stress', 'farming', 'seedwatch', 'hydrology',
    'beds', 'clothing', 'military_gear', 'noble_demands',
    'butcher', 'geld', 'trade', 'woodcutter', 'pasture',
    'garbage', 'cleanup',
    -- fast-tick reflexes
    'idle', 'distress', 'defense', 'burrow',
}

local function load_reflex(name)
    if not R[name] then
        R[name] = reqscript('dwarfmind/reflex_' .. name)
    end
    return R[name]
end

-- ─── Fast tick (every ~10 DF frames) ─────────────────────────────────────────
local function tick_fast()
    if not sensors.is_fort_loaded() then return end

    local ok, err = dfhack.pcall(function() load_reflex('idle').run() end)
    if not ok then log.err('tick_fast reflexIdle failed: ' .. tostring(err)) end

    local ok2, err2 = dfhack.pcall(function() load_reflex('distress').run() end)
    if not ok2 then log.err('tick_fast reflexDistress failed: ' .. tostring(err2)) end

    local ok_def, err_def = dfhack.pcall(function() load_reflex('defense').run() end)
    if not ok_def then log.err('tick_fast reflexDefense failed: ' .. tostring(err_def)) end

    local ok_bur, err_bur = dfhack.pcall(function() load_reflex('burrow').run() end)
    if not ok_bur then log.err('tick_fast reflexBurrow failed: ' .. tostring(err_bur)) end
end

-- ─── Slow tick (every ~1200 DF frames / 1 in-game day) ────────────────────────
local function tick_slow()
    if not sensors.is_fort_loaded() then return end

    -- Snapshot stockpile levels for the day (used by multiple reflexes)
    local snap_ok, snap_err = dfhack.pcall(function()
        local s = reqscript('dwarfmind/state')
        local levels, ok = sensors.check_stockpile_levels()
        if ok then
            s.set('stockpile_snapshot', levels)
        else
            log.warn('stockpile snapshot: sensor failed')
        end
    end)
    if not snap_ok then log.err('tick_slow stockpile snapshot: ' .. tostring(snap_err)) end

    -- 1. Mood / thought helper
    local ok_mood, err_mood = dfhack.pcall(function() load_reflex('mood_helper').run() end)
    if not ok_mood then log.err('reflex_mood_helper failed: ' .. tostring(err_mood)) end

        -- 2. Medical
    local ok_med, err_med = dfhack.pcall(function() load_reflex('medical').run() end)
    if not ok_med then log.err('reflex_medical failed: ' .. tostring(err_med)) end

        -- 3. Production
    local ok_prod, err_prod = dfhack.pcall(function() load_reflex('production').run() end)
    if not ok_prod then log.err('reflex_production failed: ' .. tostring(err_prod)) end

        -- 4. Cemetery
    local ok_cem, err_cem = dfhack.pcall(function() load_reflex('cemetery').run() end)
    if not ok_cem then log.err('reflex_cemetery failed: ' .. tostring(err_cem)) end

        -- 5. Cemetery slab
    local ok_slab, err_slab = dfhack.pcall(function() load_reflex('cemetery_slab').run() end)
    if not ok_slab then log.err('reflex_cemetery_slab failed: ' .. tostring(err_slab)) end

        -- 6. Quarantine
    local ok_quar, err_quar = dfhack.pcall(function() load_reflex('quarantine').run() end)
    if not ok_quar then log.err('reflex_quarantine failed: ' .. tostring(err_quar)) end

        -- 7. Stress
    local ok_stress, err_stress = dfhack.pcall(function() load_reflex('stress').run() end)
    if not ok_stress then log.err('reflex_stress failed: ' .. tostring(err_stress)) end

        -- 8. Farming
    local ok_farm, err_farm = dfhack.pcall(function() load_reflex('farming').run() end)
    if not ok_farm then log.err('reflex_farming failed: ' .. tostring(err_farm)) end

        -- 9. Seedwatch
    local ok_seed, err_seed = dfhack.pcall(function() load_reflex('seedwatch').run() end)
    if not ok_seed then log.err('reflex_seedwatch failed: ' .. tostring(err_seed)) end

        -- 10. Hydrology
    local ok_hydro, err_hydro = dfhack.pcall(function() load_reflex('hydrology').run() end)
    if not ok_hydro then log.err('reflex_hydrology failed: ' .. tostring(err_hydro)) end

        -- 11. Beds
    local ok_beds, err_beds = dfhack.pcall(function() load_reflex('beds').run() end)
    if not ok_beds then log.err('reflex_beds failed: ' .. tostring(err_beds)) end

        -- 12. Clothing
    local ok_clothing, err_clothing = dfhack.pcall(function() load_reflex('clothing').run() end)
    if not ok_clothing then log.err('reflex_clothing failed: ' .. tostring(err_clothing)) end

        -- 13. Military gear
    local ok_mil, err_mil = dfhack.pcall(function() load_reflex('military_gear').run() end)
    if not ok_mil then log.err('reflex_military_gear failed: ' .. tostring(err_mil)) end

        -- 14. Noble demands
    local ok_nob, err_nob = dfhack.pcall(function() load_reflex('noble_demands').run() end)
    if not ok_nob then log.err('reflex_noble_demands failed: ' .. tostring(err_nob)) end

        -- 15. Butcher
    local ok_butcher, err_butcher = dfhack.pcall(function() load_reflex('butcher').run() end)
    if not ok_butcher then log.err('reflex_butcher failed: ' .. tostring(err_butcher)) end

        -- 16. Geld
    local ok_geld, err_geld = dfhack.pcall(function() load_reflex('geld').run() end)
    if not ok_geld then log.err('reflex_geld failed: ' .. tostring(err_geld)) end

        -- 17. Trade
    local ok_trade, err_trade = dfhack.pcall(function() load_reflex('trade').run() end)
    if not ok_trade then log.err('reflex_trade failed: ' .. tostring(err_trade)) end

        -- 18. Woodcutter
    local ok_wc, err_wc = dfhack.pcall(function() load_reflex('woodcutter').run() end)
    if not ok_wc then log.err('reflex_woodcutter failed: ' .. tostring(err_wc)) end

        -- 19. Pasture
    local ok_past, err_past = dfhack.pcall(function() load_reflex('pasture').run() end)
    if not ok_past then log.err('reflex_pasture failed: ' .. tostring(err_past)) end

        -- 20. Garbage
    local ok_garb, err_garb = dfhack.pcall(function() load_reflex('garbage').run() end)
    if not ok_garb then log.err('reflex_garbage failed: ' .. tostring(err_garb)) end

        -- 21. Cleanup
    local ok_cln, err_cln = dfhack.pcall(function() load_reflex('cleanup').run() end)
    if not ok_cln then log.err('reflex_cleanup failed: ' .. tostring(err_cln)) end
end

-- ─── Scheduler ───────────────────────────────────────────────────────────────
local FAST_TICK_ID = 'dwarfmind/tick_fast'
local SLOW_TICK_ID = 'dwarfmind/tick_slow'

local function register_ticks()
    repeatUtil.scheduleEvery(FAST_TICK_ID,   10, 'ticks', tick_fast)
    repeatUtil.scheduleEvery(SLOW_TICK_ID, 1200, 'ticks', tick_slow)
    log.info('ticks registered: fast=10 slow=1200')
end

local function unregister_ticks()
    repeatUtil.cancel(FAST_TICK_ID)
    repeatUtil.cancel(SLOW_TICK_ID)
    log.info('ticks unregistered')
end

-- ─── Lifecycle ───────────────────────────────────────────────────────────────
local enabled = false

-- Called by the outer dfhack plugin enable hook.
function arm()
    if enabled then
        log.warn('already enabled')
        return
    end
    enabled = true
    sensors.invalidate_cache()

    -- Reset all reflex modules so they start from a clean state on
    -- every new fortress load (avoids stale state from prior session).
    for _, name in ipairs(REFLEX_MODULES) do
        local ok, err = dfhack.pcall(function()
            local m = load_reflex(name)
            if m.reset then m.reset() end
        end)
        if not ok then
            log.err(string.format('reset of reflex_%s failed: %s', name, tostring(err)))
        end
    end

    register_ticks()
    log.info('DwarfMind armed')
end

-- Called by the outer dfhack plugin disable hook.
function disarm()
    if not enabled then
        log.warn('already disabled')
        return
    end
    enabled = false
    unregister_ticks()
    log.info('DwarfMind disarmed')
end

function is_enabled()
    return enabled
end

return _ENV