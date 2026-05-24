-- DwarfMind core: lifecycle, scheduler, and tick dispatch.
-- All behavior modules are invoked from here. The module owns no game
-- state — only the registry of cadences and the state-change hook.
--@ module = true

local _ENV = mkmodule('dwarfmind/ai_core')

local repeatUtil   = require('repeat-util')
local logger       = reqscript('dwarfmind/logger')
local sensors      = reqscript('dwarfmind/sensors')
local actuators    = reqscript('dwarfmind/actuators')
-- CAT-4 FIX: Load orchestrator so tick_slow can dispatch it first and gate
-- all downstream reflexes through its cadence multipliers.
local orchestrator = reqscript('dwarfmind/reflex_orchestrator')
local reflexIdle   = reqscript('dwarfmind/reflex_idle')
local reflexButcher = reqscript('dwarfmind/reflex_butcher')
local reflexDistress = reqscript('dwarfmind/reflex_distress')
local reflexDefense = reqscript('dwarfmind/reflex_defense')
local reflexSquadAlert = reqscript('dwarfmind/reflex_squad_alert')
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
local reflexTantrumWatch = reqscript('dwarfmind/reflex_tantrum_watch')
local reflexHydrology = reqscript('dwarfmind/reflex_hydrology')
local reflexClothing = reqscript('dwarfmind/reflex_clothing')
local reflexSeedwatch = reqscript('dwarfmind/reflex_seedwatch')
local reflexMoodHelper = reqscript('dwarfmind/reflex_mood_helper')
local reflexCemeterySlab = reqscript('dwarfmind/reflex_cemetery_slab')
local reflexGeld = reqscript('dwarfmind/reflex_geld')
local reflexAutoContainer = reqscript('dwarfmind/reflex_auto_container')
local reflexSoapChain = reqscript('dwarfmind/reflex_soap_chain')
local reflexAccessSecurity = reqscript('dwarfmind/reflex_access_security')
local reflexSiegeAmmo = reqscript('dwarfmind/reflex_siege_ammo')
local reflexVerminControl = reqscript('dwarfmind/reflex_vermin_control')
local reflexJustice = reqscript('dwarfmind/reflex_justice')
local reflexInfirmarySupply = reqscript('dwarfmind/reflex_infirmary_supply')
-- New slow-loop reflexes
local reflexHospitality     = reqscript('dwarfmind/reflex_hospitality')
local reflexMeltCoordinator = reqscript('dwarfmind/reflex_melt_coordinator')
local reflexTrapLogistics   = reqscript('dwarfmind/reflex_trap_logistics')
local reflexPotashChain     = reqscript('dwarfmind/reflex_potash_chain')
local reflexBookkeeperAudit = reqscript('dwarfmind/reflex_bookkeeper_audit')

local log = logger.for_module('ai_core')

-- ─── Configuration ───────────────────────────────────────────────────────
-- All module-local to avoid polluting _G per ARCHITECTURE.md contract.
local GLOBAL_KEY        = 'dwarfmind'        -- prefix for repeat-util names + onStateChange slot
local PERCEPTION_PERIOD = 100                -- ticks between fast loop iterations
                                             -- (~8 real-seconds at default game speed)
local PLANNER_PERIOD    = 1200               -- ticks between slow loop iterations
                                             -- (1200 ticks = 1 dwarf day ~= 72 real-seconds
                                             --  at default speed of 100 ticks/frame)

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
-- NOTE: fast-loop defense reflexes are NOT gated through orchestrator cadence;
-- a PEACE-state military multiplier of 0.5 must never suppress the sub-second
-- hostile response.  Cadence scaling applies only to the slow planner loop.
--
-- BUG FIX: all pcall pairs now use unique local variable names
-- (ok_idle/err_idle, ok_dist/err_dist, ...) so that no outer variable is
-- accidentally shadowed and error messages are attributed correctly.
function tick_fast()
    if not sensors.is_fort_loaded() then return end

    local ok_idle, err_idle = dfhack.pcall(function()
        reflexIdle.run()
    end)
    if not ok_idle then log.err('tick_fast reflexIdle failed: ' .. tostring(err_idle)) end

    local ok_dist, err_dist = dfhack.pcall(function()
        reflexDistress.run()
    end)
    if not ok_dist then log.err('tick_fast reflexDistress failed: ' .. tostring(err_dist)) end

    local ok_def, err_def = dfhack.pcall(function()
        reflexDefense.run()
    end)
    if not ok_def then log.err('tick_fast reflexDefense failed: ' .. tostring(err_def)) end

    -- Squad activation runs in fast loop so squads are called to arms in the
    -- same tick that levers are pulled (both react to get_hostiles()).
    local ok_sqd, err_sqd = dfhack.pcall(function()
        reflexSquadAlert.run()
    end)
    if not ok_sqd then log.err('tick_fast reflexSquadAlert failed: ' .. tostring(err_sqd)) end

    local ok_bur, err_bur = dfhack.pcall(function()
        reflexBurrow.run()
    end)
    if not ok_bur then log.err('tick_fast reflexBurrow failed: ' .. tostring(err_bur)) end

    local ok_sec, err_sec = dfhack.pcall(function()
        reflexAccessSecurity.run()
    end)
    if not ok_sec then log.err('tick_fast reflexAccessSecurity failed: ' .. tostring(err_sec)) end
end

-- ─── Slow-loop reflex dispatch table ─────────────────────────────────────
-- Each entry: { module, 'label', log_fn, 'category' }
-- 'category' maps to the orchestrator's CADENCE_PROFILES key so the dispatch
-- loop can call orchestrator.is_suspended(category) before executing.
-- A nil category means the reflex is always executed (used for the orchestrator
-- itself and for meta-reflexes that manage the FSM).
--
-- CAT-4 FIX: orchestrator is dispatched FIRST so cadence multipliers are
-- written before any downstream reflex checks is_suspended()/get_cadence().
-- The per-entry category tag then lets the dispatch loop skip suspended
-- reflexes entirely, completing the Cat-4 framework alignment.
--
-- Execution order is by priority (top = highest). log_fn controls whether
-- failures are ERROR-level (life-critical) or WARN-level (non-critical).
local SLOW_REFLEXES = nil  -- populated after all locals are defined

local function init_slow_reflexes()
    SLOW_REFLEXES = {
        -- === FSM Orchestrator (always runs first; no category gate) ===
        -- CAT-4 FIX: Dispatched unconditionally so the cadence profile is always
        -- up-to-date before the rest of the reflexes are evaluated this tick.
        { orchestrator,         'orchestrator',     log.err,  nil             },

        -- === High-priority Life & Death Reflexes ===
        -- 1.  Strange mood assistant (crucial to solve/satisfy mood requests quickly)
        { reflexMoodHelper,     'mood_helper',      log.err,  'medical'       },
        -- 2.  Medical supplies (critical - health/life safety)
        { reflexMedical,        'medical',          log.err,  'medical'       },
        -- 3.  Infirmary surgery supplies: sutures, crutches, plaster, buckets
        { reflexInfirmarySupply,'infirmary_supply', log.err,  'medical'       },
        -- 4.  Food & Drink Production (critical -- prevents starvation)
        { reflexProduction,     'production',       log.warn, 'production'    },
        -- 5.  Cemetery / coffin deficits (critical - miasma/dignity/ghosts)
        { reflexCemetery,       'cemetery',         log.err,  'administrative'},
        -- 6.  Cemetery slab engraving management (critical - prevents ghost rampages)
        { reflexCemeterySlab,   'cemetery_slab',    log.err,  'administrative'},
        -- 7.  Werebeast lunar quarantine (critical - prevents fort infection wipes)
        { reflexQuarantine,     'quarantine',       log.err,  'medical'       },
        -- 8.  Stress spa / mental health intervention (critical - prevents tantrums)
        { reflexStress,         'stress',           log.err,  'medical'       },
        -- 9.  Tantrum-watch: early warning at lower stress floor + bad-thought check
        { reflexTantrumWatch,   'tantrum_watch',    log.warn, 'medical'       },
        -- === Support / Economic Reflexes ===
        -- 10. Farming / crop rotation management
        { reflexFarming,        'farming',          log.warn, 'agricultural'  },
        -- 11. Seed watch / plump helmet kitchen safety
        { reflexSeedwatch,      'seedwatch',        log.warn, 'agricultural'  },
        -- 12. Hydrology / cistern water level management
        { reflexHydrology,      'hydrology',        log.warn, 'build'         },
        -- 13. Bedroom deficits (important - citizen happiness)
        { reflexBeds,           'beds',             log.warn, 'build'         },
        -- 14. Clothing replacement / hygiene logistics
        { reflexClothing,       'clothing',         log.warn, 'production'    },
        -- 15. Military weapons and armor forging management
        { reflexMilitaryGear,   'military_gear',    log.warn, 'military'      },
        -- 16. Ammunition and siege ammo forging management
        { reflexSiegeAmmo,      'siege_ammo',       log.warn, 'military'      },
        -- 17. Noble room demands and mandates management (luxury furniture)
        { reflexNobleDemands,   'noble_demands',    log.warn, 'luxury'        },
        -- 18. Livestock butchering (non-critical population management)
        { reflexButcher,        'butcher',          log.warn, 'agricultural'  },
        -- 19. Livestock gelding population control
        { reflexGeld,           'geld',             log.warn, 'agricultural'  },
        -- 20. Trade depot management
        { reflexTrade,          'trade',            log.warn, 'administrative'},
        -- 21. Woodcutter/autochop management
        { reflexWoodcutter,     'woodcutter',       log.warn, 'production'    },
        -- 22. Pasture assignment management
        { reflexPasture,        'pasture',          log.warn, 'agricultural'  },
        -- 23. Workshop clutter and garbage management
        { reflexGarbage,        'garbage',          log.warn, 'administrative'},
        -- 24. Cleanup: claim forbidden rotting items to prevent miasma
        { reflexCleanup,        'cleanup',          log.warn, 'administrative'},
        -- 25. Auto container management (barrels/pots)
        { reflexAutoContainer,  'auto_container',   log.warn, 'production'    },
        -- 26. Soap production chain coordination
        { reflexSoapChain,      'soap_chain',       log.warn, 'production'    },
        -- 27. Pet population control (cat management)
        { reflexVerminControl,  'vermin_control',   log.warn, 'administrative'},
        -- 28. Justice and law enforcement audit
        { reflexJustice,        'justice',          log.warn, 'administrative'},
        -- === Industry Logistics & Administrative Reflexes ===
        -- 29. Bookkeeper precision audit
        { reflexBookkeeperAudit,'bookkeeper_audit', log.warn, 'administrative'},
        -- 30. Tavern mug / goblet buffer (happiness logistics)
        { reflexHospitality,    'hospitality',      log.warn, 'luxury'        },
        -- 31. Automated metal recycling
        { reflexMeltCoordinator,'melt_coordinator', log.warn, 'production'    },
        -- 32. Mechanism / TRAPPARTS engineering buffer
        { reflexTrapLogistics,  'trap_logistics',   log.warn, 'military'      },
        -- 33. Potash / fertilization chain
        { reflexPotashChain,    'potash_chain',     log.warn, 'agricultural'  },
    }
end

-- Slow loop: planner / accounting work. Runs every PLANNER_PERIOD ticks.
-- (1 tick = 1/1200 of a dwarf day; 1200 ticks = 1 dwarf day).
--
-- CAT-4 FIX: The dispatch loop now reads each entry's category tag and calls
-- orchestrator.is_suspended(category) before executing the reflex.  Suspended
-- categories are skipped entirely, completing the cadence emission feedback loop.
-- The orchestrator itself always runs (nil category = no gate).
function tick_slow()
    if not sensors.is_fort_loaded() then return end
    actuators.reset_order_budget() -- Reset the gating budget every slow tick cycle

    -- Lazy-initialise the dispatch table (can't reference reflex locals at
    -- module load time because reqscript hasn't run them yet).
    if not SLOW_REFLEXES then init_slow_reflexes() end

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

    -- CAT-4 FIX: Dispatch each reflex through orchestrator cadence gate.
    -- entry[4] is the category string (nil = always run).
    -- Suspended categories are skipped without logging to avoid log spam.
    for _, entry in ipairs(SLOW_REFLEXES) do
        local mod, label, log_fn, category = entry[1], entry[2], entry[3], entry[4]
        -- Gate check: skip if the orchestrator has suspended this category.
        -- The orchestrator entry itself has category=nil and is always executed.
        if category == nil or not orchestrator.is_suspended(category) then
            local ok, err = dfhack.pcall(mod.run)
            if not ok then
                log_fn('reflex_' .. label .. ' failed: ' .. tostring(err))
            end
        end
    end
end

-- ─── Scheduler control ───────────────────────────────────────────────────
local function arm()
    -- Reset all reflex state on new fortress load to prevent stale cooldowns
    -- from the previous save causing delayed or missed actions.
    sensors.invalidate_cache()
    actuators.reset_order_budget()

    -- CAT-4 FIX: orchestrator.reset() wired into arm() so its persist_loaded
    -- flag and local timers are cleared on every fortress load/unload cycle.
    orchestrator.reset()
    reflexIdle.reset()
    reflexDistress.reset()
    reflexDefense.reset()
    reflexSquadAlert.reset()
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
    reflexQuarantine.reset()
    reflexStress.reset()
    reflexTantrumWatch.reset()
    reflexClothing.reset()
    reflexSeedwatch.reset()
    reflexHydrology.reset()
    reflexMoodHelper.reset()
    reflexCemeterySlab.reset()
    reflexGeld.reset()
    reflexAutoContainer.reset()
    reflexSoapChain.reset()
    reflexAccessSecurity.reset()
    reflexSiegeAmmo.reset()
    reflexVerminControl.reset()
    reflexJustice.reset()
    reflexInfirmarySupply.reset()
    -- New reflexes
    reflexHospitality.reset()
    reflexMeltCoordinator.reset()
    reflexTrapLogistics.reset()
    reflexPotashChain.reset()
    reflexBookkeeperAudit.reset()

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
    -- CAT-4 FIX: surface current FSM state in status output
    print(('  fsm state:    %s'):format(orchestrator.get_state()))
end

return _ENV
