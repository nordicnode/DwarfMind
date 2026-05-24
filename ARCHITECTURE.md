# DwarfMind — Architecture (Phase 2)

Autonomous Dwarf Fortress agent built on top of DFHack's Lua API.
Pure Lua 5.3, no C++ plugin, no direct memory allocation, no raw job
injection. Designed for **safety first** (never crash the host) and
**transparency** (every decision flows through the console log).

## Guiding constraints (from the Master Directive)

1. **No `while true` loops.** Every cadence is driven by `dfhack.timeout`
   chains via the `repeat-util` scheduler so the game thread is never
   blocked.
2. **No raw memory allocation / `df.job:new()`.** Actions are emitted by
   calling existing DFHack commands and scripts (`dfhack.run_script`,
   `dfhack.run_command`) which run DF's own validators.
3. **`pcall` everything that reads `df.global`.** Pointers can be `nil`,
   the world can vanish mid-cycle, fields rename between DF versions.
4. **Sense → Think → Act** is a hard module boundary:
   * `sensors.lua` reads only.
   * Behavior modules (`reflex_*.lua`) decide.
   * Actions go through `actuators.lua`, which gates every write behind
     a `dry_run` flag (default `true`).  When `dry_run` is on, actuators
     log intent but never touch game state — safe to test against a live
     fort.  Flip it to `false` only after the agent has run crash-free
     for a full fortress week.

## Tick timing reference

Dwarf Fortress advances the world in discrete **ticks**.  All cadence
periods in this project are expressed in ticks.  The table below
translates the two configured periods to human-readable equivalents:

| Period (ticks) | DF time          | Real-world time at default speed¹ |
|----------------|------------------|-----------------------------------|
| **100**        | ~2 hours in-game | ~8 seconds                        |
| **1200**       | 1 dwarf day      | ~72 seconds (≈ 1.2 minutes)       |

> ¹ "Default speed" = the game running at 100 FPS with no frame-rate cap
> interference.  Slower machines or FPS caps will stretch these real-world
> durations proportionally.  The in-game durations are always exact
> regardless of machine speed.

**Why 1200?**  One dwarf day is exactly 1 200 ticks (24 in-game hours ×
50 ticks/hour).  The slow planner fires once per dwarf day so that work
orders, stockpile audits, and livestock checks happen on a predictable
calendar rhythm that mirrors how the player thinks about fortress
management.

## Lifecycle

```diagram
╭──────────────╮  enable dwarfmind   ╭──────────────────────╮
│ DFHack core  │ ──────────────────▶ │ scripts/dwarfmind.lua │
╰──────────────╯                     ╰─────────┬─────────────╯
                                               │ reqscript
                                               ▼
                                ╭───────────────────────────╮
                                │ dwarfmind/ai_core.lua     │
                                │  - registers onStateChange│
                                │  - registers repeat-util  │
                                │    cadences               │
                                ╰──────────┬────────────────╯
                                           │
              ╭────────────────────────────┼────────────────────────────╮
              ▼                            ▼                            ▼
      ╭──────────────╮             ╭───────────────╮            ╭───────────────╮
      │ Perception   │ ─snapshot─▶ │ Cognition     │ ─intents─▶ │ Action        │
      │ sensors.lua  │             │ reflex_*.lua  │            │ run_script /  │
      │ (read-only)  │             │ (pure logic)  │            │ console log   │
      ╰──────────────╯             ╰───────────────╯            ╰───────────────╯
```

## Cadences

Driven by `require('repeat-util').scheduleEvery(name, n, 'ticks', fn)`.
Two cadences; more can be slotted in without touching `ai_core`:

| Name                   | Period        | Real-time (default speed) | Callback            | Purpose                                    |
|------------------------|---------------|---------------------------|---------------------|--------------------------------------------|
| `dwarfmind/perception` | 100 t         | ≈ 8 seconds               | `ai_core.tick_fast` | Cheap reflex behaviors (idle, defense, …)  |
| `dwarfmind/planner`    | 1 200 t (1 day) | ≈ 72 seconds            | `ai_core.tick_slow` | Stockpile audits, work orders, livestock   |

Both callbacks are wrapped in `dfhack.pcall` inside `ai_core` (because
`repeat-util` does **not** wrap the callback — a thrown error would
silently break the chain).

## Slow-loop dispatch pattern

`tick_slow` uses a **table-driven dispatch** rather than hand-written
`pcall` blocks.  Each entry in `SLOW_REFLEXES` is:

```lua
{ moduleRef, 'label', log_fn }
```

The loop is:

```lua
for _, entry in ipairs(SLOW_REFLEXES) do
    local mod, label, log_fn = entry[1], entry[2], entry[3]
    local ok, err = dfhack.pcall(mod.run)
    if not ok then
        log_fn('reflex_' .. label .. ' failed: ' .. tostring(err))
    end
end
```

**Adding a new slow reflex** = one table line.  No boilerplate to copy.
`log.err` entries are life-critical (quarantine, medical, etc.);
`log.warn` entries are non-critical (trade, woodcutter, etc.).

The current `SLOW_REFLEXES` table has **28 entries** in priority order
(life-critical first, economic last).

## Burrow ownership arbitration

Multiple reflexes can assign/remove a unit from a burrow, which creates
a potential conflict:

| Reflex              | Burrow used     | When active                           |
|---------------------|-----------------|---------------------------------------|
| `reflex_stress`     | `Respite`       | While unit stress > threshold         |
| `reflex_burrow`     | `Safety/Panic`  | During civilian alert                 |
| `reflex_quarantine` | `Safety/Panic`  | Werebeast fallback (no bedroom)       |
| `reflex_squad_alert`| _none_          | Activates squads only; no burrow writes|
| `reflex_tantrum_watch`| _none_        | Adds thoughts only; no burrow writes  |

`reflex_stress` already detects an active civilian alert and temporarily
removes the unit from `Respite` to avoid pathfinding conflicts.
`reflex_quarantine` uses `Safety/Panic` only as a last-resort fallback
when no bedroom exists.  As reflexes are added, always check this table
before assigning a unit to a new burrow.

## State-change handling

`dfhack.onStateChange.dwarfmind` reacts to:

* `SC_MAP_UNLOADED` → cancel both cadences.
* `SC_MAP_LOADED` + `gamemode == DWARF` → re-arm both cadences.

This mirrors the pattern verified in
[hack/scripts/autotraining.lua](../autotraining.lua) and is required
because `'ticks'` timers are auto-cancelled by DFHack on world unload
(per `Lua API.txt` §3158).

## Safety contract for every callback

```lua
local function step()
    if not dfhack.isMapLoaded() then return end                 -- world gone
    if df.global.gamemode ~= df.game_mode.DWARF then return end -- not a fort
    local ok, err = dfhack.pcall(do_work)                       -- never crash
    if not ok then log.err('step failed: ' .. tostring(err)) end
end
```

## Modules

| File | Role |
|------|------|
| [dwarfmind.lua](../dwarfmind.lua) | Entry script. `enable`/`disable`/`status` user interface. |
| [dwarfmind/ai_core.lua](ai_core.lua) | Lifecycle, scheduler registration, tick dispatch. |
| [dwarfmind/sensors.lua](sensors.lua) | Read-only world queries: `get_idle_dwarves`, `check_stockpile_levels`, etc. |
| [dwarfmind/actuators.lua](actuators.lua) | Write gate: `enable_labor`, `run_script`. `dry_run` flag logs without mutating. |
| [dwarfmind/logger.lua](logger.lua) | Structured console logging with levels and module tags. |
| **Fast-loop reflexes (every 100 t)** | |
| [dwarfmind/reflex_idle.lua](reflex_idle.lua) | Announces idle citizens via the logger. |
| [dwarfmind/reflex_distress.lua](reflex_distress.lua) | Monitors citizen health, starvation, and strange mood blocks. |
| [dwarfmind/reflex_defense.lua](reflex_defense.lua) | Auto-pulls defense levers (word-boundary matched) when hostiles appear. |
| [dwarfmind/reflex_squad_alert.lua](reflex_squad_alert.lua) | Activates fort-defense squads by name keyword when hostiles appear; auto-deactivates when map clears. |
| [dwarfmind/reflex_burrow.lua](reflex_burrow.lua) | Triggers civilian panic alerts and routes citizens to Safety burrow. |
| [dwarfmind/reflex_access_security.lua](reflex_access_security.lua) | Door/hatch access control based on zone security rules. |
| **Slow-loop reflexes (every 1 200 t = 1 dwarf day)** | |
| [dwarfmind/reflex_mood_helper.lua](reflex_mood_helper.lua) | Strange mood assistant — prioritises workshop and material acquisition. |
| [dwarfmind/reflex_medical.lua](reflex_medical.lua) | Audits Chief Medical Dwarf office and hospital supply buffers. |
| [dwarfmind/reflex_infirmary_supply.lua](reflex_infirmary_supply.lua) | Monitors hospital zones for critically low surgery supplies: sutures, crutches, plaster powder, buckets. |
| [dwarfmind/reflex_production.lua](reflex_production.lua) | Monitors food/drink levels and auto-queues work orders. |
| [dwarfmind/reflex_cemetery.lua](reflex_cemetery.lua) | Monitors dead citizens, builds coffins, and auto-zones graves. |
| [dwarfmind/reflex_cemetery_slab.lua](reflex_cemetery_slab.lua) | Engraves slabs for missing citizens to prevent ghost rampages. |
| [dwarfmind/reflex_quarantine.lua](reflex_quarantine.lua) | Werebeast bedroom door quarantine during full moon (days 25–28); Safety burrow fallback when no bedroom exists. |
| [dwarfmind/reflex_stress.lua](reflex_stress.lua) | Stress spa / mental health intervention; persists recovery state across saves. |
| [dwarfmind/reflex_tantrum_watch.lua](reflex_tantrum_watch.lua) | Early-warning tantrum detection at a lower stress floor (2 500) with bad-thought inspection and fine-meal consolation. |
| [dwarfmind/reflex_farming.lua](reflex_farming.lua) | Ensures DFHack autofarm plugin is enabled and configured. |
| [dwarfmind/reflex_seedwatch.lua](reflex_seedwatch.lua) | Seed watch — protects plump helmet seeds from the kitchen. |
| [dwarfmind/reflex_hydrology.lua](reflex_hydrology.lua) | Cistern water level management. |
| [dwarfmind/reflex_beds.lua](reflex_beds.lua) | Audits bedroom status and auto-queues ConstructBed work orders. |
| [dwarfmind/reflex_clothing.lua](reflex_clothing.lua) | Clothing replacement and hygiene logistics. |
| [dwarfmind/reflex_military_gear.lua](reflex_military_gear.lua) | Audits squad sizes and automatically forges weapons/armor deficits. |
| [dwarfmind/reflex_siege_ammo.lua](reflex_siege_ammo.lua) | Ammunition and siege ammo forging management. |
| [dwarfmind/reflex_noble_demands.lua](reflex_noble_demands.lua) | Satisfies noble room/furniture demands and triggers mandate fulfillment. |
| [dwarfmind/reflex_butcher.lua](reflex_butcher.lua) | Detects excess livestock by species and queues butchering. |
| [dwarfmind/reflex_geld.lua](reflex_geld.lua) | Livestock gelding for population control. |
| [dwarfmind/reflex_trade.lua](reflex_trade.lua) | Auto-marks finished goods and gems for trade when caravans are AtDepot. |
| [dwarfmind/reflex_woodcutter.lua](reflex_woodcutter.lua) | Dynamic control of the autochop plugin based on wood stock thresholds. |
| [dwarfmind/reflex_pasture.lua](reflex_pasture.lua) | Automatically assigns unpastured grazing livestock to pen/pasture zones. |
| [dwarfmind/reflex_garbage.lua](reflex_garbage.lua) | Identifies cluttered workshops and marks products for dumping. |
| [dwarfmind/reflex_cleanup.lua](reflex_cleanup.lua) | Claims forbidden rotting remains inside the fort to prevent miasma. |
| [dwarfmind/reflex_auto_container.lua](reflex_auto_container.lua) | Auto container management (barrels/pots). |
| [dwarfmind/reflex_soap_chain.lua](reflex_soap_chain.lua) | Soap production chain coordination. |
| [dwarfmind/reflex_vermin_control.lua](reflex_vermin_control.lua) | Pet population control (cat management). |
| [dwarfmind/reflex_justice.lua](reflex_justice.lua) | Justice and law enforcement audit. |

## Inter-module wiring

```diagram
╭───────────────╮       ╭───────────╮       ╭──────────────╮
│ dwarfmind.lua │──────▶│ ai_core   │──────▶│ logger       │
╰───────────────╯       │           │       ╰──────────────╯
                        │           │──────▶ sensors
                        │           │──────▶ actuators     (all writes via safe_act)
                        │           │──────▶ [fast reflexes]  ──▶ sensors + logger/actuators
                        │           │──────▶ [slow reflexes]  ──▶ sensors + actuators
                        ╰───────────╯
```

Loaded via `reqscript('dwarfmind/<name>')` so each file is also a
standalone module with `--@ module = true`. No global state escapes the
module table.

## Coding conventions

### reset() contract

Every `reflex_*.lua` **must** export a `reset()` function.  It is called
by `ai_core.arm()` on every fortress load to clear stale in-memory state
(cooldown tables, cached IDs, persistent-state load flags).  If a module
currently has no persistent state, `reset()` should still exist as an
empty function with a comment explaining what future state it will clear.

### Sensor cache

`sensors.lua` maintains a per-frame cache keyed by `df.global.cur_year_tick`.
The cache is useful for deduplicating sensor calls **within a single
`tick_fast` pass** (multiple fast reflexes calling `get_hostiles()` in
the same frame will hit the cache after the first call).  The cache
provides **no benefit** across `tick_slow` calls because each reflex runs
in a different frame — do not rely on cached sensor values persisting
between two slow-loop reflexes.

### Persistent state pattern

Use the following safe pattern for `dfhack.persistent` saves to avoid a
nil-index crash on first use (when the key does not exist yet):

```lua
local entry = dfhack.persistent.get(KEY)
if not entry then
    local ok
    ok, entry = pcall(dfhack.persistent.save, {key = KEY})
    if not ok or not entry then
        log.warn('persistent.save failed')
        return
    end
end
entry.value = encoded_string
```

## What is explicitly out of scope for the MVP

* Direct designation writes (`block.designation[…].bits.dig = …`).
* `df.global.world.manager_orders` mutation.
* `ExclusiveCallback`-style UI keystroke driving.
* Persistence to `dfhack-config/` — re-enable on each save load.

These are the obvious next milestones, but each adds at least one new
crash vector. The MVP earns the right to write to game state by first
proving it can read state, decide, and call existing scripts without
ever crashing the host across a full fortress year.

## Verification plan

1. From the DFHack console: `enable dwarfmind`.
2. `dwarfmind status` shows both cadences as scheduled.
3. Watch the console: every 100 ticks the fast reflexes log idle citizens and scan for hostiles.
4. Unload the fortress (Esc → Save and Continue → Main Menu). The two
   cadences must disappear from `repeat-util` (`reload-script` test).
5. Load again: cadences re-arm without manual intervention.
6. `disable dwarfmind` cancels both cadences and the state-change hook.
