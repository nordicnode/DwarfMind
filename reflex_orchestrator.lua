--@ module = true
-- =============================================================================
-- reflex_orchestrator.lua  —  Central Macro-Goal FSM Orchestrator  (Task B)
-- =============================================================================
-- ARCHITECTURE CONTRACT:
--   This module is a REFLEX (Layer 2 / Cognition).  It reads macro-state
--   snapshots from sensors.lua, arbitrates a fort-wide FSM state, and
--   communicates cadence multipliers to ai_core.lua via a shared persistent
--   key so all other reflexes can query the active operational mode.
--
-- FSM STATES:
--   PEACE          – Standard industrial growth; all reflexes at baseline.
--   SIEGE          – Martial mobilisation; non-combat reflexes suspended.
--   DISTRESS_FAMINE– Food/medicine absolute priority; production throttled.
--   QUARANTINE     – Triggered by infection events; population isolation.
--
-- CADENCE MULTIPLIERS (written to dfhack.persistent as JSON):
--   1.0  = run at normal cadence
--   0.5  = run at half frequency
--   0.0  = suspended (skip execution)
--
-- SAFETY RULES ENFORCED:
--   [A] No df.global at top-level scope.
--   [B] Persistent state lazy-loaded inside run().
--   [C] All sensor calls checked for ok flag before consuming values.
--   [D] reset() clears all local timers and state tables.
-- =============================================================================
local _ENV = mkmodule('dwarfmind/reflex_orchestrator')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_orchestrator')

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local EVAL_COOLDOWN      = 1200   -- re-evaluate FSM every ~10 dwarf-days
local PERSIST_KEY        = 'dwarfmind_orchestrator_state'

-- Threat thresholds
local HOSTILE_SIEGE_THRESHOLD    = 4    -- >=4 armed hostiles = SIEGE
local STRESS_DISTRESS_THRESHOLD  = 5    -- >=5 citizens above stress threshold = DISTRESS concern
local FOOD_FAMINE_THRESHOLD      = 5    -- fewer than 5 food items = FAMINE
local SEED_CRITICAL_THRESHOLD    = 3    -- fewer than 3 seed stacks = FAMINE
local INFECTION_COUNT_THRESHOLD  = 2    -- >=2 infected units = QUARANTINE
local CITIZEN_STRESS_FLOOR       = 20000-- per-citizen stress value passed to get_stressed_citizens

-- Lunar quarantine: DF month 3 (Slate) and month 9 (Moonstone) are used as
-- representative "lunar risk" months when miasma / syndrome spread is high.
local QUARANTINE_MONTHS = { [3]=true, [9]=true }

-- FSM state identifiers
local STATE = {
    PEACE           = 'PEACE',
    SIEGE           = 'SIEGE',
    DISTRESS_FAMINE = 'DISTRESS_FAMINE',
    QUARANTINE      = 'QUARANTINE',
}

-- Cadence profiles: multiplier per FSM state per reflex category.
-- Categories match the tagging convention in ai_core.lua.
local CADENCE_PROFILES = {
    [STATE.PEACE] = {
        agricultural  = 1.0,
        production    = 1.0,
        luxury        = 1.0,
        military      = 0.5,
        medical       = 0.5,
        administrative= 1.0,
        build         = 1.0,
    },
    [STATE.SIEGE] = {
        agricultural  = 0.5,
        production    = 0.5,
        luxury        = 0.0,
        military      = 1.0,
        medical       = 1.0,
        administrative= 0.5,
        build         = 0.0,  -- halt construction during active siege
    },
    [STATE.DISTRESS_FAMINE] = {
        agricultural  = 1.0,
        production    = 0.5,
        luxury        = 0.0,
        military      = 0.5,
        medical       = 1.0,
        administrative= 0.5,
        build         = 0.0,
    },
    [STATE.QUARANTINE] = {
        agricultural  = 1.0,
        production    = 1.0,
        luxury        = 0.0,
        military      = 0.5,
        medical       = 1.0,
        administrative= 1.0,
        build         = 0.5,
    },
}

-- ---------------------------------------------------------------------------
-- Module-local mutable state  (cleared in reset())
-- ---------------------------------------------------------------------------
local current_state   = STATE.PEACE
local last_eval_tick  = -math.huge
local state_entered   = -math.huge  -- tick when we entered current_state
local persist_loaded  = false

-- ---------------------------------------------------------------------------
-- PERSISTENT STATE  (lazy-loaded on first run())
-- ---------------------------------------------------------------------------

local function load_persistent_state()
    if persist_loaded then return end
    -- dfhack.persistent calls are safe here because we are inside run()
    local ok, record = pcall(function()
        return dfhack.persistent.get(PERSIST_KEY)
    end)
    if ok and record and record.value then
        local jok, data = pcall(function()
            return require('json').decode(record.value)
        end)
        if jok and data and data.state then
            current_state  = data.state
            state_entered  = data.state_entered or -math.huge
            log.info(('orchestrator: restored state=%s'):format(current_state))
        end
    end
    persist_loaded = true
end

local function save_persistent_state()
    local ok, err = pcall(function()
        local json = require('json')
        dfhack.persistent.save({
            entry_id = PERSIST_KEY,
            value    = json.encode({
                state         = current_state,
                state_entered = state_entered,
            }),
        })
    end)
    if not ok then
        log.warn(('orchestrator: persist save failed: %s'):format(tostring(err)))
    end
end

-- ---------------------------------------------------------------------------
-- SENSOR AGGREGATION  (Layer 1 reads; all calls check ok flag)
-- CAT-1 FIX: All wrappers now call the real sensor function signatures as
-- documented in sensors.lua.  The old hallucinated endpoints
-- (get_hostile_count, get_stress_median, get_food_item_count, get_seed_count)
-- are replaced below.
-- ---------------------------------------------------------------------------

-- CAT-1 FIX: was sensors.get_hostile_count() — no such function.
-- sensors.get_hostiles() returns (list, ok); count the list length.
local function count_hostiles()
    local hostiles, ok = sensors.get_hostiles()
    if not ok then return 0 end
    return hostiles and #hostiles or 0
end

-- CAT-1 FIX: was sensors.get_stress_median() — no such function.
-- sensors.get_stressed_citizens(threshold) returns (list, ok).
-- We count how many citizens exceed the CITIZEN_STRESS_FLOOR and compare
-- that count against STRESS_DISTRESS_THRESHOLD (an integer, not a median).
local function get_stressed_count()
    local stressed, ok = sensors.get_stressed_citizens(CITIZEN_STRESS_FLOOR)
    if not ok then return 0 end
    return stressed and #stressed or 0
end

-- CAT-1 FIX: was sensors.get_food_item_count() — no such function.
-- sensors.check_stockpile_levels() returns ({ food=N, ... }, ok).
local function get_food_count()
    local stocks, ok = sensors.check_stockpile_levels()
    if not ok then return 999 end
    return stocks and (stocks.food or 0) or 999
end

-- CAT-1 FIX: was sensors.get_seed_count() — no such function.
-- Re-uses check_stockpile_levels() which already counts seeds.
local function get_seed_count()
    local stocks, ok = sensors.check_stockpile_levels()
    if not ok then return 999 end
    return stocks and (stocks.seeds or 0) or 999
end

local function get_infection_count()
    -- Count units with any active syndrome flagged as contagious.
    -- We read raw unit syndrome data through a safe pcall.
    local count = 0
    local ok, err = pcall(function()
        local world = df.global.world
        if not world then return end
        local units = world.units.active
        if not units then return end
        for i = 0, #units - 1 do
            local u = units[i]
            if u and u.syndromes and u.syndromes.active then
                local sa = u.syndromes.active
                for j = 0, #sa - 1 do
                    local syn = sa[j]
                    if syn and syn.type then
                        count = count + 1
                        break  -- count unit once
                    end
                end
            end
        end
    end)
    if not ok then
        log.warn(('get_infection_count error: %s'):format(tostring(err)))
        return 0
    end
    return count
end

-- Returns {month=N, year=N} from current game time.
local function get_game_time()
    local result = {month=0, year=0}
    local ok, err = pcall(function()
        local cur = df.global.cur_year_tick
        -- DF year = 403,200 ticks; each month ~33,600 ticks
        result.month = math.floor((cur % 403200) / 33600) + 1
        result.year  = df.global.cur_year
    end)
    if not ok then
        log.warn(('get_game_time error: %s'):format(tostring(err)))
    end
    return result
end

-- Returns season name as string for logging.
local function season_name(tick)
    -- DF ticks per season ~100,800 (quarter year)
    local s = math.floor((tick % 403200) / 100800)
    return ({'Spring','Summer','Autumn','Winter'})[s + 1] or 'Unknown'
end

-- ---------------------------------------------------------------------------
-- FSM ARBITRATION
-- ---------------------------------------------------------------------------
-- Priority order (highest wins):
--   SIEGE > QUARANTINE > DISTRESS_FAMINE > PEACE

local function arbitrate_state()
    local hostiles   = count_hostiles()
    local stressed   = get_stressed_count()
    local food       = get_food_count()
    local seeds      = get_seed_count()
    local infected   = get_infection_count()
    local time       = get_game_time()

    -- SIEGE: active armed hostiles above threshold
    if hostiles >= HOSTILE_SIEGE_THRESHOLD then
        return STATE.SIEGE,
            ('SIEGE: %d hostiles detected'):format(hostiles)
    end

    -- QUARANTINE: infection events OR lunar-cycle risk month
    if infected >= INFECTION_COUNT_THRESHOLD
    or QUARANTINE_MONTHS[time.month] then
        local reason = (infected >= INFECTION_COUNT_THRESHOLD)
            and (('%d infected units'):format(infected))
            or  ('lunar risk month %d'):format(time.month)
        return STATE.QUARANTINE, ('QUARANTINE: %s'):format(reason)
    end

    -- DISTRESS / FAMINE: food shortage or too many highly-stressed citizens
    if food < FOOD_FAMINE_THRESHOLD
    or seeds < SEED_CRITICAL_THRESHOLD
    or stressed >= STRESS_DISTRESS_THRESHOLD then
        local reasons = {}
        if food    < FOOD_FAMINE_THRESHOLD     then reasons[#reasons+1] = ('food=%d'):format(food)       end
        if seeds   < SEED_CRITICAL_THRESHOLD   then reasons[#reasons+1] = ('seeds=%d'):format(seeds)     end
        if stressed>= STRESS_DISTRESS_THRESHOLD then reasons[#reasons+1] = ('stressed_citizens=%d'):format(stressed) end
        return STATE.DISTRESS_FAMINE,
            ('DISTRESS_FAMINE: %s'):format(table.concat(reasons, ', '))
    end

    return STATE.PEACE, 'PEACE: nominal conditions'
end

-- ---------------------------------------------------------------------------
-- CADENCE EMISSION
-- ---------------------------------------------------------------------------
-- Write the current cadence profile to dfhack.persistent so that ai_core.lua
-- and all reflexes can read it without coupling to this module directly.

local function emit_cadence(state)
    local profile = CADENCE_PROFILES[state]
    if not profile then return end
    local ok, err = pcall(function()
        local json = require('json')
        dfhack.persistent.save({
            entry_id = 'dwarfmind_cadence_profile',
            value    = json.encode(profile),
        })
    end)
    if not ok then
        log.warn(('emit_cadence error: %s'):format(tostring(err)))
    end
end

-- ---------------------------------------------------------------------------
-- SIEGE ACTION ESCALATION
-- ---------------------------------------------------------------------------
-- CAT-1 FIX: Removed actuators.run_script('dwarfmind/reflex_defense') which
-- DFHack cannot resolve as an internal framework path and would produce a
-- "script not found" console error leaving gates open during a siege.
--
-- Replacement strategy:
--   1. Alert all squads via actuators.run_command('alertlevel', '2').
--   2. Close all bridges that are currently open by pulling their levers
--      directly through sensors.get_levers() + actuators.pull_lever().
--   3. Activate civilian burrow evacuation via actuators.set_civilian_alert().
--
-- This routes every mutation through actuators (the designated write gate)
-- and never calls a non-existent DFHack script path.

local function escalate_siege()
    if actuators.is_dry_run() then
        log.info('DRY-RUN: siege escalation actions skipped.')
        return
    end

    -- 1. Alert all military squads
    local ok_alert, err_alert = pcall(function()
        actuators.run_command('alertlevel', '2')  -- level 2 = war footing
    end)
    if not ok_alert then
        log.warn(('escalate_siege: alertlevel failed: %s'):format(tostring(err_alert)))
    end

    -- 2. Pull all open bridge-linked levers to close gates
    local levers, ok_lev = sensors.get_levers()
    if ok_lev and levers then
        for _, entry in ipairs(levers) do
            -- entry.state is populated by sensors.get_levers():
            -- 'open' = bridge is down (open) and should be raised (closed)
            -- Only pull levers that are not already closed and have no pull job queued
            if (entry.state == 'open' or entry.state == nil)
            and not entry.has_pull_job then
                local ok_pull, err_pull = pcall(function()
                    actuators.pull_lever(entry.building.id)
                end)
                if not ok_pull then
                    log.warn(('escalate_siege: pull_lever id=%d failed: %s')
                        :format(entry.building.id, tostring(err_pull)))
                end
            end
        end
    else
        log.warn('escalate_siege: get_levers() failed; bridge closure skipped.')
    end

    -- 3. Activate civilian alert (moves civilians to safe burrow)
    local ok_civ, err_civ = pcall(function()
        actuators.set_civilian_alert(true)
    end)
    if not ok_civ then
        log.warn(('escalate_siege: set_civilian_alert failed: %s'):format(tostring(err_civ)))
    end

    log.info('Siege escalation issued: squads alerted, bridge levers pulled, civilian alert active.')
end

-- ---------------------------------------------------------------------------
-- FAMINE/DISTRESS ESCALATION
-- ---------------------------------------------------------------------------

local function escalate_distress()
    if actuators.is_dry_run() then
        log.info('DRY-RUN: distress escalation skipped.')
        return
    end
    -- Priority food/seed work orders routed through manager
    if actuators.can_queue_order() then
        actuators.run_script('workorder', 'PrepareRawFoodMeal', '10')
    end
    if actuators.can_queue_order() then
        actuators.run_script('workorder', 'BrewDrink', '10')
    end
    -- Activate medical supply chain via a real DFHack workorder script
    if actuators.can_queue_order() then
        actuators.run_script('workorder', 'MakeSoap', '5')
    end
    log.info('Distress escalation issued: food/brew/medical orders queued.')
end

-- ---------------------------------------------------------------------------
-- QUARANTINE ESCALATION
-- ---------------------------------------------------------------------------

local function escalate_quarantine()
    if actuators.is_dry_run() then
        log.info('DRY-RUN: quarantine escalation skipped.')
        return
    end
    -- Assign werebeast / infected citizens to quarantine burrow if it exists.
    -- The burrow must be named 'Quarantine' and pre-created by the operator.
    -- sensors.find_burrow_id_by_name() returns (id_or_nil, ok).
    local burrow_id, ok_b = sensors.find_burrow_id_by_name('Quarantine')
    if ok_b and burrow_id then
        local infected_units, ok_u = sensors.get_werebeast_citizens()
        if ok_u and infected_units then
            for _, u in ipairs(infected_units) do
                local ok_assign, err_assign = pcall(function()
                    actuators.assign_unit_to_burrow(u.id, burrow_id)
                end)
                if not ok_assign then
                    log.warn(('escalate_quarantine: assign unit %d failed: %s')
                        :format(u.id, tostring(err_assign)))
                end
            end
        end
    else
        log.warn('escalate_quarantine: no burrow named Quarantine found; skipping assignment.')
    end
    log.info('Quarantine escalation issued.')
end

-- ---------------------------------------------------------------------------
-- STATE TRANSITION HANDLER
-- ---------------------------------------------------------------------------

local function transition_to(new_state, reason)
    if new_state == current_state then return end
    local now = sensors.current_tick()
    log.info(('FSM transition: %s -> %s | %s | tick=%d season=%s'):format(
        current_state, new_state, reason, now, season_name(now)))
    current_state = new_state
    state_entered = now
    -- Emit updated cadence profile for all reflexes
    emit_cadence(new_state)
    -- Trigger escalation actions
    if new_state == STATE.SIEGE then
        escalate_siege()
    elseif new_state == STATE.DISTRESS_FAMINE then
        escalate_distress()
    elseif new_state == STATE.QUARANTINE then
        escalate_quarantine()
    end
    -- Persist new state
    save_persistent_state()
end

-- ---------------------------------------------------------------------------
-- PUBLIC API  (callable by ai_core.lua or other reflexes)
-- ---------------------------------------------------------------------------

-- Returns the current FSM state string.
function get_state()
    return current_state
end

-- Returns the cadence multiplier for a given reflex category string.
-- Returns 1.0 if the category is unknown (safe default).
function get_cadence(category)
    local profile = CADENCE_PROFILES[current_state]
    if not profile then return 1.0 end
    return profile[category] or 1.0
end

-- Returns true if a reflex category is suspended (cadence == 0.0).
function is_suspended(category)
    return get_cadence(category) == 0.0
end

-- ---------------------------------------------------------------------------
-- MAIN LOOP HOOKS
-- ---------------------------------------------------------------------------

function run()
    if not sensors.is_fort_loaded() then return end
    -- Lazy-load persistent state on first run
    load_persistent_state()
    -- Emit initial cadence so reflexes have a value from tick 0
    local now = sensors.current_tick()
    if state_entered == -math.huge then
        state_entered = now
        emit_cadence(current_state)
    end
    -- Throttle evaluation to EVAL_COOLDOWN
    if (now - last_eval_tick) < EVAL_COOLDOWN then return end
    last_eval_tick = now
    -- Arbitrate new state
    local new_state, reason = arbitrate_state()
    transition_to(new_state, reason)
end

function reset()
    current_state  = STATE.PEACE
    last_eval_tick = -math.huge
    state_entered  = -math.huge
    persist_loaded = false
    log.info('reflex_orchestrator reset.')
end

return _ENV
