-- DwarfMind core: lifecycle, scheduler, and tick dispatch.
-- All behavior modules are invoked from here. The module owns no game
-- state — only the registry of cadences and the state-change hook.
--@ module = true

local _ENV = mkmodule('dwarfmind/ai_core')

local repeatUtil   = require('repeat-util')
local logger       = reqscript('dwarfmind/logger')
local sensors      = reqscript('dwarfmind/sensors')
local actuators    = reqscript('dwarfmind/actuators')
local reflexIdle   = reqscript('dwarfmind/reflex_idle')
local reflexButcher = reqscript('dwarfmind/reflex_butcher')
local reflexDistress = reqscript('dwarfmind/reflex_distress')
local reflexDefense = reqscript('dwarfmind/reflex_defense')
local reflexProduction = reqscript('dwarfmind/reflex_production')
local reflexCleanup = reqscript('dwarfmind/reflex_cleanup')
local reflexBeds = reqscript('dwarfmind/reflex_beds')
local reflexTrade = reqscript('dwarfmind/reflex_trade')
local reflexQuarantine = reqscript('dwarfmind/reflex_quarantine')
local reflexWoodcutter = reqscript('dwarfmind/reflex_woodcutter')
local reflexMedical = reqscript('dwarfmind/reflex_medical')
local reflexCemetery = reqscript('dwarfmind/reflex_cemetery')
local reflexPasture = reqscript('dwarfmind/reflex_pasture')
local reflexBurrow = reqscript('dwarfmind/reflex_burrow')
local reflexFarming = reqscript('dwarfmind/reflex_farming')
local reflexNobleDemands = reqscript('dwarfmind/reflex_noble_demands')
local reflexGarbage = reqscript('dwarfmind/reflex_garbage')
local reflexMilitaryGear = reqscript('dwarfmind/reflex_military_gear')
local reflexStress = reqscript('dwarfmind/reflex_stress')
local reflexHydrology = reqscript('dwarfmind/reflex_hydrology')
local reflexClothing = reqscript('dwarfmind/reflex_clothing')
local reflexSeedwatch = reqscript('dwarfmind/reflex_seedwatch')
local reflexMoodHelper = reqscript('dwarfmind/reflex_mood_helper')
local reflexCemeterySlab = reqscript('dwarfmind/reflex_cemetery_slab')
local reflexGeld = reqscript('dwarfmind/reflex_geld')
local reflexAutoContainer = reqscript('dwarfmind/reflex_auto_container')
local reflexSoapChain = reqscript('dwarfmind/reflex_soap_chain')
local reflexAccessSecurity = reqscript('dwarfmind/reflex_access_security')

local log = logger.for_module('ai_core')

-- ─── Configuration ───────────────────────────────────────────────────────
-- All module-local to avoid polluting _G per ARCHITECTURE.md contract.
local GLOBAL_KEY        = 'dwarfmind'        -- prefix for repeat-util names + onStateChange slot
local PERCEPTION_PERIOD = 100                -- ticks between fast loop iterations (every ~2 seconds)
local PLANNER_PERIOD    = 1200               -- ticks between slow loop iterations (1200 = 1 dwarf day, not 50)

local NAME_FAST = GLOBAL_KEY .. '/perception'
local NAME_SLOW = GLOBAL_KEY .. '/planner'

-- ─── Internal state ──────────────────────────────────────────────────────
-- Whether the lifecycle hook believes the loop should be running.
-- (Distinct from "is a timer currently armed" because timers vanish on
--  world-unload regardless of our wishes.)
local enabled = false

-- ─── Tick callbacks ──────────────────────────────────────────────────────
-- Fast loop: cheap reflex behaviors that need to react quickly.
-- Defense lever loops stay here for sub-second response times.
function tick_fast()
    if not sensors.is_fort_loaded() then return end
    local ok, err = dfhack.pcall(function()
        reflexIdle.run()
    end)
    if not ok then log.err('tick_fast reflexIdle failed: ' .. tostring(err)) end

    local ok2, err2 = dfhack.pcall(function()
        reflexDistress.run()
    end)
    if not ok2 then log.err('tick_fast reflexDistress failed: ' .. tostring(err2)) end

    local ok_def, err_def = dfhack.pcall(function()
        reflexDefense.run()
    end)
    if not ok_def then log.err('tick_fast reflexDefense failed: ' .. tostring(err_def)) end

    local ok_bur, err_bur = dfhack.pcall(function()
        reflexBurrow.run()
    end)
    if not ok_bur then log.err('tick_fast reflexBurrow failed: ' .. tostring(err_bur)) end

    local ok_sec, err_sec = dfhack.pcall(function()
        reflexAccessSecurity.run()
    end)
    if not ok_sec then log.err('tick_fast reflexAccessSecurity failed: ' .. tostring(err_sec)) end
end

-- Slow loop: planner / accounting work. Runs every PLANNER_PERIOD ticks
-- (1 tick = 1/1200 of a dwarf day; 1200 ticks = 1 dwarf day).
--
-- Moved reflex_quarantine and reflex_cleanup here from tick_fast because
-- lunar phase checks and rotting item scans don't need sub-second reaction speeds.
-- reflex_butcher moved after beds (not life-critical, lower priority than shelter).
--
-- Execution order is by priority: medical > cemetery > quarantine > beds > butcher > rest.
-- This ensures higher-priority needs (health, burial, shelter) are addressed
-- first if the work order budget becomes exhausted.
function tick_slow()
    if not sensors.is_fort_loaded() then return end
    actuators.reset_order_budget() -- Reset the gating budget every slow tick cycle
    
    -- Stockpile snapshot (informational only, no orders)
    local ok_stock, err_stock = dfhack.pcall(function()
        local s, sensor_ok = sensors.check_stockpile_levels()
        if sensor_ok then
            log.info(string.format(
                'stockpile snapshot: food=%d drink=%d seeds=%d wood=%d stone=%d',
                s.food or 0, s.drink or 0, s.seeds or 0, s.wood or 0, s.stone or 0))
        else
            log.warn('stockpile snapshot: sensor failed')
        end
    end)
    if not ok_stock then log.warn('stockpile snapshot failed: ' .. tostring(err_stock)) end

    -- === High-priority Life & Death Reflexes ===
        -- 1. Strange mood assistant (crucial to solve/satisfy mood requests quickly)
        local ok_mood, err_mood = dfhack.pcall(function()
            reflexMoodHelper.run()
        end)
        if not ok_mood then log.err('reflex_mood_helper failed: ' .. tostring(err_mood)) end

        -- 2. Medical supplies (critical - health/life safety)
        local ok_med, err_med = dfhack.pcall(function()
            reflexMedical.run()
        end)
        if not ok_med then log.err('reflex_medical failed: ' .. tostring(err_med)) end

        -- 3. Food & Drink Production (critical — prevents starvation)
        local ok_prod, err_prod = dfhack.pcall(function()
            reflexProduction.run()
        end)
        if not ok_prod then log.warn('reflex_production failed: ' .. tostring(err_prod)) end

        -- 4. Cemetery / coffin deficits (critical - miasma/dignity/ghosts)
        local ok_cem, err_cem = dfhack.pcall(function()
            reflexCemetery.run()
        end)
        if not ok_cem then log.err('reflex_cemetery failed: ' .. tostring(err_cem)) end

        -- 5. Cemetery slab engraving management (critical - prevents ghost rampages)
        local ok_slab, err_slab = dfhack.pcall(function()
            reflexCemeterySlab.run()
        end)
        if not ok_slab then log.err('reflex_cemetery_slab failed: ' .. tostring(err_slab)) end

        -- 6. Werebeast lunar quarantine (critical - prevents fort infection wipes)
        local ok_quar, err_quar = dfhack.pcall(function()
            reflexQuarantine.run()
        end)
        if not ok_quar then log.err('reflex_quarantine failed: ' .. tostring(err_quar)) end

        -- 7. Stress spa / mental health intervention (critical - prevents tantrums/insanity)
        local ok_stress, err_stress = dfhack.pcall(function()
            reflexStress.run()
        end)
        if not ok_stress then log.err('reflex_stress failed: ' .. tostring(err_stress)) end

        -- === Support / Economic Reflexes ===
        -- 8. Farming / crop rotation management
        local ok_farm, err_farm = dfhack.pcall(function()
            reflexFarming.run()
        end)
        if not ok_farm then log.warn('reflex_farming failed: ' .. tostring(err_farm)) end

        -- 9. Seed watch / plump helmet kitchen safety
        local ok_seed, err_seed = dfhack.pcall(function()
            reflexSeedwatch.run()
        end)
        if not ok_seed then log.warn('reflex_seedwatch failed: ' .. tostring(err_seed)) end

        -- 10. Hydrology / cistern water level management
        local ok_hydro, err_hydro = dfhack.pcall(function()
            reflexHydrology.run()
        end)
        if not ok_hydro then log.warn('reflex_hydrology failed: ' .. tostring(err_hydro)) end

        -- 11. Bedroom deficits (important - citizen happiness)
        local ok_beds, err_beds = dfhack.pcall(function()
            reflexBeds.run()
        end)
        if not ok_beds then log.warn('reflex_beds failed: ' .. tostring(err_beds)) end

        -- 12. Clothing replacement / hygiene logistics
        local ok_clothing, err_clothing = dfhack.pcall(function()
            reflexClothing.run()
        end)
        if not ok_clothing then log.warn('reflex_clothing failed: ' .. tostring(err_clothing)) end

        -- 13. Military weapons and armor forging management
        local ok_mil, err_mil = dfhack.pcall(function()
            reflexMilitaryGear.run()
        end)
        if not ok_mil then log.warn('reflex_military_gear failed: ' .. tostring(err_mil)) end

        -- 14. Noble room demands and mandates management (luxury furniture)
        local ok_nob, err_nob = dfhack.pcall(function()
            reflexNobleDemands.run()
        end)
        if not ok_nob then log.warn('reflex_noble_demands failed: ' .. tostring(err_nob)) end

        -- 15. Livestock butchering (non-critical population management)
        local ok_butcher, err_butcher = dfhack.pcall(function()
            reflexButcher.run()
        end)
        if not ok_butcher then log.warn('reflex_butcher failed: ' .. tostring(err_butcher)) end

        -- 16. Livestock gelding population control
        local ok_geld, err_geld = dfhack.pcall(function()
            reflexGeld.run()
        end)
        if not ok_geld then log.warn('reflex_geld failed: ' .. tostring(err_geld)) end

        -- 17. Trade depot management
        local ok_trade, err_trade = dfhack.pcall(function()
            reflexTrade.run()
        end)
        if not ok_trade then log.warn('reflex_trade failed: ' .. tostring(err_trade)) end

        -- 18. Woodcutter/autochop management
        local ok_wc, err_wc = dfhack.pcall(function()
            reflexWoodcutter.run()
        end)
        if not ok_wc then log.warn('reflex_woodcutter failed: ' .. tostring(err_wc)) end

        -- 19. Pasture assignment management
        local ok_past, err_past = dfhack.pcall(function()
            reflexPasture.run()
        end)
        if not ok_past then log.warn('reflex_pasture failed: ' .. tostring(err_past)) end

        -- 20. Workshop clutter and garbage management
        local ok_garb, err_garb = dfhack.pcall(function()
            reflexGarbage.run()
        end)
        if not ok_garb then log.warn('reflex_garbage failed: ' .. tostring(err_garb)) end

        -- 21. Cleanup: claim forbidden rotting items to prevent miasma
        local ok_cln, err_cln = dfhack.pcall(function()
            reflexCleanup.run()
        end)
        if not ok_cln then log.warn('reflex_cleanup failed: ' .. tostring(err_cln)) end

        -- 22. Auto container management (barrels/pots)
        local ok_cont, err_cont = dfhack.pcall(function()
            reflexAutoContainer.run()
        end)
        if not ok_cont then log.warn('reflex_auto_container failed: ' .. tostring(err_cont)) end

        -- 23. Soap production chain coordination
        local ok_soap, err_soap = dfhack.pcall(function()
            reflexSoapChain.run()
        end)
        if not ok_soap then log.warn('reflex_soap_chain failed: ' .. tostring(err_soap)) end
end

-- ─── Scheduler control ───────────────────────────────────────────────────
local function arm()
    -- Reset all reflex state on new fortress load to prevent stale cooldowns
    -- from the previous save causing delayed or missed actions.
    -- See GitHub issue: save/load edge cases with persistent module state.
    sensors.invalidate_cache()
    actuators.reset_order_budget()

    reflexIdle.reset()
    reflexDistress.reset()
    reflexDefense.reset()
    reflexProduction.reset()
    reflexCleanup.reset()
    reflexBeds.reset()
    reflexTrade.reset()
    reflexWoodcutter.reset()
    reflexMedical.reset()
    reflexCemetery.reset()
    reflexPasture.reset()
    reflexBurrow.reset()
    reflexFarming.reset()
    reflexNobleDemands.reset()
    reflexGarbage.reset()
    reflexMilitaryGear.reset()
    reflexButcher.reset()
    reflexQuarantine.reset()  -- was missing: stale lunar state leaked across save/load
    reflexStress.reset()
    reflexClothing.reset()
    reflexSeedwatch.reset()
    reflexHydrology.reset()
    reflexMoodHelper.reset()
    reflexCemeterySlab.reset()
    reflexGeld.reset()
    reflexAutoContainer.reset()
    reflexSoapChain.reset()
    reflexAccessSecurity.reset()

    repeatUtil.scheduleEvery(NAME_FAST, PERCEPTION_PERIOD, 'ticks', tick_fast)
    repeatUtil.scheduleEvery(NAME_SLOW, PLANNER_PERIOD,    'ticks', tick_slow)
    log.info(string.format('cadences armed (fast=%dt, slow=%dt)',
        PERCEPTION_PERIOD, PLANNER_PERIOD))
end

local function disarm()
    repeatUtil.cancel(NAME_FAST)
    repeatUtil.cancel(NAME_SLOW)
    log.info('cadences cancelled')
end

-- ─── State-change hook ───────────────────────────────────────────────────
-- Note on lifecycle:
--   * 'ticks' timers are auto-cancelled by DFHack on SC_WORLD_UNLOADED.
--   * repeat-util clears its own registry then, too.
--   * We re-arm on SC_MAP_LOADED so the agent survives save/load cycles.
local function install_state_hook()
    dfhack.onStateChange[GLOBAL_KEY] = function(sc)
        if sc == df.state_change_event.MAP_UNLOADED or sc == df.state_change_event.WORLD_UNLOADED then
            log.info('map unloaded; invalidating cache and cancelling cadences')
            sensors.invalidate_cache()  -- Prevent stale cache from surviving world unload
            disarm()
            return
        end
        if sc == df.state_change_event.MAP_LOADED and enabled then
            local ok, gm = pcall(function() return df.global.gamemode end)
            if ok and gm == df.game_mode.DWARF then
                arm()
            end
        end
    end
end

local function uninstall_state_hook()
    dfhack.onStateChange[GLOBAL_KEY] = nil
end

-- ─── Public API ──────────────────────────────────────────────────────────
function is_enabled() return enabled end

function enable()
    if enabled then
        log.warn('already enabled')
        return
    end
    enabled = true
    install_state_hook()
    log.info('enabled')
    if sensors.is_fort_loaded() then
        arm()
    else
        log.info('no fortress loaded; will arm cadences on SC_MAP_LOADED')
    end
end

function disable()
    if not enabled then
        log.warn('already disabled')
        return
    end
    enabled = false
    disarm()
    uninstall_state_hook()
    log.info('disabled')
end

function status()
    local level_names = {[1]='DEBUG', [2]='INFO', [3]='WARN', [4]='ERROR'}
    print(('dwarfmind: %s'):format(enabled and 'ENABLED' or 'disabled'))
    print(('  fort loaded:  %s'):format(tostring(sensors.is_fort_loaded())))
    print(('  perception:   %s (every %d ticks)')
        :format(repeatUtil.isScheduled(NAME_FAST) and 'scheduled' or 'idle',
                PERCEPTION_PERIOD))
    print(('  planner:      %s (every %d ticks)')
        :format(repeatUtil.isScheduled(NAME_SLOW) and 'scheduled' or 'idle',
                PLANNER_PERIOD))
    print(('  log level:    %s')
        :format(level_names[logger.threshold] or 'unknown'))
end

return _ENV
