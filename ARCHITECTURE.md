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
Two cadences for the MVP; more can be slotted in without touching
`ai_core`:

| Name                          | Period   | Callback                | Purpose                                     |
|-------------------------------|----------|-------------------------|---------------------------------------------|
| `dwarfmind/perception`        | 100 t    | `ai_core.tick_fast`     | Cheap reflex behaviors (idle detection, …)  |
| `dwarfmind/planner`           | 1200 t   | `ai_core.tick_slow`     | Stockpile snapshots, livestock management      |

Both callbacks are wrapped in `dfhack.pcall` inside `ai_core` (because
`repeat-util` does **not** wrap the callback — a thrown error would
silently break the chain).

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

## Modules in this MVP

| File                                                      | Role                                                                            |
|-----------------------------------------------------------|---------------------------------------------------------------------------------|
| [dwarfmind.lua](../dwarfmind.lua)                         | Entry script. `enable`/`disable`/`status` user interface.                       |
| [dwarfmind/ai_core.lua](ai_core.lua)                      | Lifecycle, scheduler registration, tick dispatch.                               |
| [dwarfmind/sensors.lua](sensors.lua)                      | Read-only world queries: `get_idle_dwarves`, `check_stockpile_levels`, etc.    |
| [dwarfmind/actuators.lua](actuators.lua)                  | Write gate: `enable_labor`, `run_script`.  `dry_run` flag logs without mutating.|
| [dwarfmind/reflex_idle.lua](reflex_idle.lua)              | MVP behavior: announces idle citizens via the logger.                           |
| [dwarfmind/reflex_distress.lua](reflex_distress.lua)      | Monitors citizen health, starvation, and strange mood blocks, logging warnings. |
| [dwarfmind/reflex_defense.lua](reflex_defense.lua)        | Auto-pulls defense levers when hostiles are detected on the map.                |
| [dwarfmind/reflex_production.lua](reflex_production.lua)  | Monitors food/drink levels and auto-queues work orders.                         |
| [dwarfmind/reflex_cleanup.lua](reflex_cleanup.lua)        | Claims forbidden rotting remains inside the fort to prevent miasma.             |
| [dwarfmind/reflex_beds.lua](reflex_beds.lua)              | Audits bedroom status and auto-queues ConstructBed work orders.                  |
| [dwarfmind/reflex_butcher.lua](reflex_butcher.lua)        | Detects excess livestock by species, suggests butchering via actuators.          |
| [dwarfmind/reflex_trade.lua](reflex_trade.lua)            | Auto-marks finished goods and gems for trade when caravans are AtDepot.         |
| [dwarfmind/reflex_quarantine.lua](reflex_quarantine.lua)  | Werebeast bedroom door quarantine during full moon (days 25-28) and release (day 1).|
| [dwarfmind/reflex_woodcutter.lua](reflex_woodcutter.lua)  | Dynamic control of the C++ autochop plugin based on wood log stock thresholds.  |
| [dwarfmind/reflex_medical.lua](reflex_medical.lua)        | Audits Chief Medical Dwarf office and hospital supply buffers.                  |
| [dwarfmind/reflex_cemetery.lua](reflex_cemetery.lua)      | Monitors dead citizens, builds coffins, and auto-zones graves via the burial script.|
| [dwarfmind/reflex_pasture.lua](reflex_pasture.lua)        | Automatically assigns unpastured grazing livestock to pen/pasture zones.        |
| [dwarfmind/reflex_burrow.lua](reflex_burrow.lua)          | Automatically triggers civilian panic alerts and routes citizens to burrows.   |
| [dwarfmind/reflex_farming.lua](reflex_farming.lua)        | Ensures DFHack autofarm plugin is enabled and configured.                       |
| [dwarfmind/reflex_noble_demands.lua](reflex_noble_demands.lua) | Satisfies noble room/furniture demands and triggers mandate fulfillment orders.|
| [dwarfmind/reflex_garbage.lua](reflex_garbage.lua)        | Identifies cluttered workshops and marks products for dumping to clear space.   |
| [dwarfmind/reflex_military_gear.lua](reflex_military_gear.lua) | Audits squad sizes and automatically forges weapons/armor deficits.           |
| [dwarfmind/logger.lua](logger.lua)                        | Structured console logging with levels and module tags.                         |

## Inter-module wiring

```diagram
╭───────────────╮       ╭───────────╮       ╭──────────────╮
│ dwarfmind.lua │──────▶│ ai_core   │──────▶│ logger       │
╰───────────────╯       │           │       ╰──────────────╯
                        │           │──────▶ sensors
                        │           │──────▶ actuators     (all writes via safe_act)
                        │           │──────▶ reflex_idle   ──▶ sensors + logger
                        │           │──────▶ reflex_distress──▶ sensors + logger
                        │           │──────▶ reflex_defense──▶ sensors + actuators
                        │           │──────▶ reflex_production──▶ sensors + actuators
                        │           │──────▶ reflex_cleanup──▶ sensors + actuators
                        │           │──────▶ reflex_beds   ──▶ sensors + actuators
                        │           │──────▶ reflex_butcher──▶ sensors + actuators
                        │           │──────▶ reflex_trade  ──▶ sensors + actuators
                        │           │──────▶ reflex_quarantine──▶ sensors + actuators
                        │           │──────▶ reflex_woodcutter──▶ sensors + actuators
                        │           │──────▶ reflex_medical ──▶ sensors + actuators
                        │           │──────▶ reflex_cemetery──▶ sensors + actuators
                        │           │──────▶ reflex_pasture ──▶ sensors + actuators
                        │           │──────▶ reflex_burrow  ──▶ sensors + actuators
                        │           │──────▶ reflex_farming ──▶ sensors + actuators
                        │           │──────▶ reflex_noble_demands ──▶ sensors + actuators
                        │           │──────▶ reflex_garbage ──▶ sensors + actuators
                        │           │──────▶ reflex_military_gear ──▶ sensors + actuators
                        ╰───────────╯
```

Loaded via `reqscript('dwarfmind/<name>')` so each file is also a
standalone module with `--@module = true`. No global state escapes the
module table.

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
3. Watch the console: every 100 ticks the reflex prints idle citizens.
4. Unload the fortress (Esc → Save and Continue → Main Menu). The two
   cadences must disappear from `repeat-util` (`reload-script` test).
5. Load again: cadences re-appear without manual intervention.
6. `disable dwarfmind` cancels both cadences and the state-change hook.
