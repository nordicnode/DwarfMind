# DwarfMind Developer Agent Onboarding Guide (AGENTS.md)

Welcome, Developer Agent. This document contains the comprehensive specifications, architectural constraints, API designs, and common pitfalls of the **DwarfMind** autonomous framework. It is designed to ensure you can optimally debug, refactor, and expand this codebase without causing crashes, memory leaks, or save corruption.

---

## 🗺️ Architectural Paradigm: Sense-Think-Act

DwarfMind is designed as a decentralized cognitive system. All operations are strictly segregated into three distinct layers to maintain isolation and ensure safety:

```
┌─────────────────────────────────────────────────────────────┐
│                      Perception (Sense)                     │
│  File: sensors.lua                                          │
│  - Read-only queries of df.global structures                │
│  - Returns safe default values on failure                   │
│  - Implements caching to avoid O(N) scans on every tick     │
└──────────────┬──────────────────────────────────────────────┘
               │
               ▼ (State Snapshots)
┌─────────────────────────────────────────────────────────────┐
│                      Cognition (Think)                      │
│  Files: reflex_*.lua                                        │
│  - Evaluates snapshots to make logical decisions            │
│  - Decoupled from direct write operations                   │
│  - Uses tick-based cooldowns to prevent spamming actions    │
└──────────────┬──────────────────────────────────────────────┘
               │
               ▼ (Intents / Commands)
┌─────────────────────────────────────────────────────────────┐
│                        Action (Act)                         │
│  File: actuators.lua                                        │
│  - The single write gate for mutating game state            │
│  - Implements dry_run logging guards                        │
│  - Restricts work orders via budget allocation per tick     │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔍 Layer 1: Perception (`sensors.lua`)

All reads from the host Dwarf Fortress memory map must flow through `sensors.lua`. 

### 1. The `safe` Wrapper
Every public sensor function must be wrapped in the `safe` function. This prevents crashes if a save is unloaded or memory structures are unallocated.
```lua
-- Template for a safe sensor
function get_custom_data()
    return safe('get_custom_data', default_value, function()
        -- Direct reads here
        return data
    end)
end
```

### 2. Caching Strategy
*   **Tick-Cache**: DwarfMind maintains a local `tick_cache` table to avoid scanning heavy vectors (like `df.global.world.units.all` or `items`) multiple times in a single tick.
*   **Cache Invalidation**: On fortress load/unload, the cache is invalidated via `invalidate_cache()`.
*   **Fast vs Slow Cadence**: Do not run heavy scans (like `units.all` or building loops) on the fast tick cache. Keep `tick_fast` loops lightweight. Heavy scans must be run on the slow tick cadence (`tick_slow`, every 1200 ticks).

---

## 🧠 Layer 2: Cognition (`reflex_*.lua`)

Reflexes represent individual cognitive behaviors. They are registered and dispatched by `ai_core.lua`.

### 1. Reflex Structure Contract
Every reflex file must match the following module contract:
```lua
--@ module = true
local _ENV = mkmodule('dwarfmind/reflex_my_feature')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_my_feature')

local ACTION_COOLDOWN = 6000 -- ticks (approx. 50 dwarf days)
local last_action = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end
    
    local now = sensors.current_tick()
    if (now - last_action) < ACTION_COOLDOWN then return end
    
    -- Perception
    local stock, ok = sensors.check_stockpile_levels()
    if not ok then return end
    
    -- Cognition
    if stock.wood < 5 then
        -- Action
        actuators.run_script('workorder', 'MakeAsh', '1')
        last_action = now
    end
end

function reset()
    last_action = -math.huge
end

return _ENV
```

### 2. Cooldown Management
*   Reflexes should avoid executing active mutations on every tick.
*   Ensure a monotonic `now - last_action` tick cooldown check is executed before logic runs.
*   Cooldowns must be stored in local variables inside the module scope, *never* in global state.

### 3. Persistent State Management
If a reflex needs to track state across save/load boundaries, it must use DFHack's `dfhack.persistent` API:
*   Serialize state tables to JSON strings using the `json` module.
*   **Important**: Do not call `dfhack.persistent.get()` or `dfhack.persistent.save()` in the top-level chunk of the file. This will crash the main menu screen when the module is required. Instead, lazy-load state on the first call to `run()`.

---

## 🛠️ Layer 3: Action (`actuators.lua`)

All state modifications must route through `actuators.lua` to ensure safety and auditability.

### 1. `dry_run` Safety Gate
*   By default, `dry_run` is set to `true`.
*   All actuators must check `is_dry_run()` and log their intended actions without executing them if `dry_run` is enabled.
*   Do not bypass this guard in production.

### 2. Command Types
*   **`run_script(name, ...)`**: Invokes a DFHack Lua script (e.g. `workorder`, `lever`).
*   **`run_command(name, ...)`**: Invokes a DFHack C++ plugin command (e.g. `enable`, `autochop`, `autofarm`). Arguments are automatically formatted as a single string for `dfhack.run_command`.

### 3. Manager Order Budget Coordinator
*   To prevent multiple reflexes from filling up the manager order queue in a single tick, `actuators.lua` maintains an order budget.
*   Each `run_script('workorder', ...)` call consumes `1` budget slot.
*   `can_queue_order()` checks if budget remains. The budget is reset every slow tick via `reset_order_budget()`.

---

## 📐 Indexing & Data Structures (CRITICAL)

Dwarf Fortress utilizes C++ arrays and vectors, while Lua uses native tables. You must master the indexing differences to avoid out-of-bound crashes or silent failures:

| Structure Type | Index Base | Iteration Protocol | Example |
|---|---|---|---|
| **C++ Vectors** (e.g., `df.global.world.units.all`) | **0-indexed** | `for i = 0, #vec - 1 do` | `local unit = vec[i]` |
| **Lua Tables** (e.g., table returned by `get_citizens()`) | **1-indexed** | `for _, item in ipairs(tbl) do` | `local u = tbl[1]` |

### C++ Vector Iteration Example:
```lua
local list = df.global.plotinfo.burrows.list
for i = 0, #list - 1 do
    local burrow = list[i]
    -- do work
end
```

### Lua Table Iteration Example:
```lua
local citizens = sensors.get_citizens() -- returns Lua table
for _, u in ipairs(citizens) do
    -- do work
end
```

---

## ⚠️ Common Bugs & Code Smells to Avoid

### 1. Top-Level `df.global` or `dfhack` Calls
Any code placed at the top level of a script runs immediately when the script is parsed (on DFHack startup / main menu). Reading `df.global` or calling `dfhack.persistent` at the top level will throw errors because no world is loaded.
*   **Bad**:
    ```lua
    local world_orders = df.global.world.manager_orders -- CRASH AT MAIN MENU
    ```
*   **Good**:
    ```lua
    function run()
        local world_orders = df.global.world.manager_orders -- Safe: only runs when loaded
    end
    ```

### 2. Nil Pointer Hazards on Nested Structures
DF structures are nested. Always check parent fields before indexing child properties to prevent runtime errors:
*   **Bad**:
    ```lua
    if u.job.current_job ~= nil then ... -- Crashes if u.job is nil
    ```
*   **Good**:
    ```lua
    if u.job and u.job.current_job ~= nil then ...
    ```

### 3. Invalid API Assumptions
Do not assume standard functions exist without searching the codebase first. For example, `dfhack.units.isBleeding(u)` is not a standard API. Instead, inspect blood properties directly:
```lua
if u.body and u.body.blood_max and u.body.blood_max > 0 then
    local is_bleeding = u.body.blood_count < u.body.blood_max
end
```

---

## 🧪 Testing and Quality Control

Before submitting code, you must perform two validations:

1.  **Syntax Verification**:
    Ensure the code is free of syntax errors:
    ```bash
    luac -p /absolute/path/to/modifiedfile.lua
    ```
2.  **Top-Level Require Check**:
    Ensure the file loads cleanly without throwing exceptions during startup/require:
    ```bash
    lua -e 'local mock = setmetatable({}, { __index = _G }); _G.mkmodule = function() return mock end; _G.reqscript = function() return {} end; loadfile("/absolute/path/to/modifiedfile.lua")()'
    ```

Maintain documentation integrity. Do not strip comments or rename existing, validated API interfaces unless specifically requested. Follow the **Sense-Think-Act** architecture consistently.
