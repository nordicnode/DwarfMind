# DwarfMind Sub-Agent 3 — DF / DFHack Structures Reference

All field names below were verified against the upstream
[DFHack/df-structures](https://github.com/DFHack/df-structures) XML
(`df.unit.xml`, `df.item.xml`, `df.building.xml`, `df.block.xml`,
`df.world.xml`, `df.d_basics.xml`) and cross-checked against scripts in
the local install at `/home/mikey/Games/DwarfFortress/hack/` (notably
`scripts/animal-control.lua`, `scripts/exterminate.lua`,
`lua/plugins/zone.lua`, `lua/plugins/sort/info.lua`,
`scripts/internal/notify/notifications.lua`,
`lua/dfhack/buildings.lua`, `lua/tile-material.lua`).

The Lua bindings are described in
<https://docs.dfhack.org/en/stable/docs/Lua%20API.html>. Field names
listed here are the **DFHack** Lua names (i.e. the `name=` attribute in
the XML, not `original-name`). DF often changes these between releases —
always re-verify with `lua "@df.global.world.units.active[0]"` before
trusting them.

---

## 1. `df.global.world.units.active`

`world.units` is a `unit_handlerst` compound (`df.unit.xml` line 3169):

```
df.global.world.units.all      -- every unit ever loaded (stl-vector<unit*>)
df.global.world.units.active   -- units currently on the map (stl-vector<unit*>); entry 0 is the adventurer
df.global.world.units.other    -- categorized sub-vectors (units_other)
df.global.world.units.adv_unit -- pointer; nil in fort mode mostly
```

Iterate active units with:

```lua
for _, u in ipairs(df.global.world.units.active) do ... end
```

Element type is `df.unit` (`class-type type-name='unit'`,
`df.unit.xml` line 2607). Useful top-level fields:

| Field                              | Type                                  | Notes |
|------------------------------------|---------------------------------------|-------|
| `id`                               | `int32_t`                             | Stable unit id |
| `name`                             | `language_name` compound              | `name.first_name`, `name.nickname`, `name.has_name`, `name.language` |
| `custom_profession`                | `stl-string`                          | Dwarf-set nickname for the profession |
| `profession`                       | `enum profession` (int16)             | Current profession (e.g. `df.profession.MINER`) |
| `profession2`                      | `enum profession` (int16)             | Original profession |
| `race`                             | `int32_t` → `creature_raw`            | Index into `df.global.world.raws.creatures.all[race]` |
| `caste`                            | `int16_t` → `caste_raw`               | Index into `creatures.all[race].caste[caste]` |
| `sex`                              | `pronoun_type` enum                   | 0 = female, 1 = male, -1 = neuter |
| `pos`                              | `coord` (`pos.x`, `pos.y`, `pos.z`)   | Current map tile |
| `civ_id`                           | `int32_t` → `historical_entity`       | -1 for wild; compare to `df.global.plotinfo.civ_id` |
| `population_id`                    | `int32_t`                             | Source population |
| `cultural_identity`                | `int32_t`                             | Cultural identity ref |
| `hist_figure_id`                   | `int32_t` → `historical_figure`       | -1 for non-historical |
| `mood`                             | `enum mood_type`                      | `None`, `Fey`, `Secretive`, `Possessed`, `Macabre`, `Insane`, `Berserk`, `Melancholy`, `Fell`, `Trauma` |
| `moodstage`                        | `int16` enum                          | Strange-mood progress |
| `training_level`                   | `animal_training_level` enum          | `WildUntamed`, `SemiWild`, `Trained`, `Tame`, `Domesticated`, `WildTrained`, etc. |
| `flags1` / `flags2` / `flags3` / `flags4` | bitfields                      | See below |
| `inventory`                        | `vector<unit_inventory_item*>`        | Each entry has `.item` (pointer) and `.mode` |
| `owned_items`                      | `vector<int32_t>` (item ids)          | Items the unit owns |
| `general_refs` / `specific_refs`   | vectors of refs                       | Building/squad/site links |
| `military`                         | `squad_infost` compound               | `military.squad_id`, `military.squad_position` |
| `relationship_ids[9]`              | static array, `unit_relationship_type`| Spouse, mother, father, etc. |
| `path`                             | compound                              | `path.dest` (coord), `path.goal` enum, `path.path` (coord_path) |
| `idle_area` / `follow_distance`    | coord / int32_t                       | Where the unit waits |
| `body`                             | `unit_body` compound                  | `body.physical_attrs.STRENGTH.value`, etc. |
| `status`                           | compound (see §1.4)                   | Souls, labors, demands, complaints |
| `status2`                          | compound (see §1.4)                   | Limb counts, liquid context |
| `counters`                         | compound (see §1.3)                   | Movement/combat counters |
| `counters2`                        | compound                              | Hunger/thirst/sleep, exhaustion, stored fat |
| `enemy`                            | compound                              | Were-race, normal-race, witness reports |
| `health`                           | pointer (often nil)                   | Wound/injury data; may be nil if `flags3.compute_health` not yet processed |
| `syndromes.active`                 | `vector<unit_syndrome*>`              | Currently active syndromes |
| `job`                              | compound (see §1.2)                   | `job.current_job` (`pointer<job>`), `job.hunt_target`, `job.destroy_target` |
| `birth_year` / `birth_time`        | int32_t                               | Age — use `dfhack.units.getAge(u)` instead |

### 1.1  `flags1` — `unit_flags1` (uint32_t, `df.unit.xml` line 1320)

Verified bits (DFHack name = DF original name):

| Bit | Field name              | Meaning |
|-----|-------------------------|---------|
| 0   | `move_state`            | Currently moving (CANMOVE) |
| 1   | `inactive`              | Dead or off-map; commonly named `dead` in legacy DF wikis but the XML field is `inactive` |
| 2   | `has_mood`              | In a strange mood |
| 3   | `had_mood`              | Has had a strange mood already |
| 4   | `marauder`              | Wide-class invader |
| 5   | `drowning`              | Currently drowning |
| 6   | `merchant`              | Active merchant (caravan member) |
| 7   | `forest`                | Wood-elf trader/wagon driver, also leftovers leaving the map |
| 8   | `left`                  | Has left the map |
| 9   | `rider`                 | Riding another creature |
| 10  | `incoming`              | Just arrived on map |
| 11  | `diplomat`              | Liaison / diplomat |
| 13  | `check_active_heist`    |  |
| 14  | `can_swap`              | Can swap tiles when moving |
| 15  | `on_ground`             | Prone (conscious or otherwise) |
| 16  | `projectile`            | Currently airborne projectile |
| 17  | `active_invader`        | Organized invader |
| 18  | `hidden_in_ambush`      | AMBUSH bit |
| 19  | `invader_origin`        | Came in as an invader |
| 20  | `coward`                | Will flee under losses |
| 21  | `hidden_ambusher`       | Active marauder moving in |
| 22  | `invades`               | Resident marauder |
| 24  | `ridden`                |  |
| 25  | `caged`                 | In a cage |
| 26  | `tame`                  | Tame creature |
| 27  | `chained`               | Chained / restrained |
| 30  | `suppress_wield`        |  |
| 31  | `important_historical_figure` (`NEMESIS`) | |

> Note: There is **no** flag literally named `dead`. Use `flags1.inactive`,
> `dfhack.units.isDead(unit)`, or `dfhack.units.isActive(unit)`.

### 1.2  `flags2` — `unit_flags2` (uint32_t, line 1365)

Useful bits: `swimming`, `sparring`, `no_notify`, `killed`
(set after death by `kill` function), `for_trade`, `trade_resolved`,
`locked_in_for_trading`, `slaughter` (marked for butcher),
`underworld`, `resident`, `visitor`, `visitor_uninvited`,
`calculated_inventory`, plus various health flags
(`vision_good/damaged/missing`, `breathing_good/breathing_problem`).

### 1.3  `flags3` — `unit_flags3` (uint32_t, line 1410)

Useful bits: `body_part_relsize_computed`, `compute_health`,
`on_crutch`, `weight_computed`, `ghostly`, `floundering`, `dangerous_terrain`,
`gelded`, `marked_for_gelding`, `guest` (causes "No Activity" tag),
`available_for_adoption`, `injury_thought`, `scuttle`.

### 1.4  Composite sub-structures

```
unit.counters        -- job_counter, swap_counter, death_cause, death_id,
                       winded, stunned, unconscious, suffocation, webbed,
                       soldier_mood, soldier_mood_countdown,
                       pain, nausea, dizziness
unit.counters2       -- paralysis, numbness, fever, exhaustion,
                       hunger_timer, thirst_timer, sleepiness_timer,
                       stomach_content, stomach_food, vomit_timeout, stored_fat
unit.status          -- misc_traits (vector<unit_misc_trait*>),
                       eat_history, demand_timeout, mandate_timeout,
                       souls (vector<unit_soul*>), current_soul (pointer),
                       demands, labors (bool[unit_labor]),
                       observed_traps, complaints, parleys, requests, coin_debts
unit.status2         -- limbs_stand_max/count, limbs_grasp_max/count,
                       limbs_fly_max/count, body_part_temperature,
                       liquid_type, liquid_depth
unit.job.current_job -- pointer<job>; nil when idle. Check job.current_job ~= nil
                       before reading fields like .job_type, .pos, .item_subtype
unit.job.hunt_target -- pointer<unit>; nil unless hunting
unit.job.destroy_target -- pointer<building>; nil unless attacking building
```

### 1.5  Classifying units — use `dfhack.units.*`, not flags directly

The reliable predicates (all return `bool`, all defined by the DFHack
C++ binding and exposed in `dfhack.units`):

```
dfhack.units.isActive(u)         -- not flags1.inactive
dfhack.units.isDead(u)           -- including ghosts
dfhack.units.isCitizen(u[, ignore_sanity])
dfhack.units.isFortControlled(u) -- citizen, resident, tame animal, etc.
dfhack.units.isOwnCiv(u)         -- u.civ_id == plotinfo.civ_id
dfhack.units.isOwnRace(u)
dfhack.units.isVisitor(u)
dfhack.units.isMerchant(u)       -- flags1.merchant
dfhack.units.isDiplomat(u)       -- flags1.diplomat
dfhack.units.isForest(u)         -- flags1.forest (leaving merchants)
dfhack.units.isInvader(u)        -- flags1.active_invader/marauder/etc.
dfhack.units.isHidden(u)
dfhack.units.isAnimal(u)         -- non-sapient creatures
dfhack.units.isTame(u)           -- flags1.tame
dfhack.units.isPet(u)
dfhack.units.isOpposedToLife(u)  -- undead, demons
dfhack.units.isDanger(u)         -- hostile to fort
dfhack.units.isWildlife(u)
dfhack.units.isAdult(u) / isChild(u) / isBaby(u)
dfhack.units.isGelded / isGeldable
dfhack.units.getNoblePositions(u)
dfhack.units.getProfessionName(u)
dfhack.units.getVisibleName(u)  -- returns df.language_name
dfhack.units.getAge(u[, true_age])
dfhack.units.getPosition(u)     -- x,y,z (handles riders, cages)
```

Verified in
[exterminate.lua](file:///home/mikey/Games/DwarfFortress/hack/scripts/exterminate.lua),
[zone.lua](file:///home/mikey/Games/DwarfFortress/hack/lua/plugins/zone.lua),
[notifications.lua](file:///home/mikey/Games/DwarfFortress/hack/scripts/internal/notify/notifications.lua),
[sort/info.lua](file:///home/mikey/Games/DwarfFortress/hack/lua/plugins/sort/info.lua).

Idiomatic classifier:

```lua
local U = dfhack.units
local function classify(u)
    if not U.isActive(u) or U.isDead(u) then return 'dead'
    elseif U.isCitizen(u) then return 'citizen'
    elseif U.isVisitor(u) then return 'visitor'
    elseif U.isMerchant(u) or u.flags1.merchant or u.flags1.diplomat or u.flags1.forest then return 'caravan'
    elseif U.isInvader(u) or U.isOpposedToLife(u) or U.isDanger(u) then return 'hostile'
    elseif U.isAnimal(u) then
        if U.isFortControlled(u) and U.isTame(u) then return 'fort_animal' end
        return 'wildlife'
    end
    return 'other'
end
```

### 1.6  Healthcare & Wellness (Wounds, Bleeding)

*   **Bleeding Detection**: Do not use `dfhack.units.isBleeding`. Instead, check the unit's body structure properties directly:
    ```lua
    local is_bleeding = u.body and u.body.blood_max and u.body.blood_max > 0 and u.body.blood_count < u.body.blood_max
    ```
*   **Wounds & Healthcare Flags**: Healthcare needs are tracked under the unit's health compound:
    ```lua
    local needs_hospital = u.health and u.health.flags.needs_healthcare
    ```
    *Note: `u.health` may be nil if `u.flags3.compute_health` has not yet been processed by the game engine.*

---

## 2. `df.global.world.items.all`

`world.items` is `item_handlerst` (`df.item.xml` line 2404):

```
df.global.world.items.all                -- every item (stl-vector<item*>)
df.global.world.items.other.IN_PLAY      -- items physically on the active map
df.global.world.items.other.ANY_ARTIFACT -- all artifacts
df.global.world.items.other.WEAPON       -- pointer<item_weaponst>; only "real" weapons (no trap parts)
df.global.world.items.other.ANY_WEAPON   -- weapons + trapcomps (job lookup vector)
df.global.world.items.other.FOOD         -- prepared meals only (item_foodst)
df.global.world.items.other.DRINK        -- item_drinkst
df.global.world.items.other.MEAT, .FISH, .FISH_RAW, .EGG, .CHEESE,
df.global.world.items.other.PLANT, .PLANT_GROWTH, .SEEDS,
df.global.world.items.other.POWDER_MISC, .LIQUID_MISC, .GLOB
df.global.world.items.other.AMMO, .ARMOR, .HELM, .SHOES, .GLOVES, .PANTS, .SHIELD
df.global.world.items.other.WOOD, .STONE→BOULDER, .BAR, .BLOCKS, .ROCK
df.global.world.items.other.CORPSE, .CORPSEPIECE, .REMAINS
df.global.world.items.other.ANY_CRITTER, .VERMIN, .PET
df.global.world.items.other.COIN, .GEM, .ROUGH, .SMALLGEM
df.global.world.items.other.BIN, .BOX, .BAG, .BARREL, .BUCKET, .CAGE,
df.global.world.items.other.BACKPACK, .QUIVER, .FLASK
df.global.world.items.other.BED, .CHAIR, .TABLE, .COFFIN, .DOOR, .FLOODGATE,
df.global.world.items.other.HATCH_COVER, .GRATE, .WINDOW, .GOBLET, .STATUE,
df.global.world.items.other.TOOL, .INSTRUMENT, .TOY, .ARMORSTAND, .WEAPONRACK,
df.global.world.items.other.CABINET, .ANVIL, .CATAPULTPARTS, .BALLISTAPARTS,
df.global.world.items.other.SIEGEAMMO, .TRAPPARTS, .PIPE_SECTION, .SLAB,
df.global.world.items.other.QUERN, .MILLSTONE, .TRAPCOMP, .CHAIN, .ANIMALTRAP,
df.global.world.items.other.FIGURINE, .AMULET, .BRACELET, .RING, .EARRING,
df.global.world.items.other.CROWN, .SCEPTER, .BOOK, .SHEET, .CLOTH, .THREAD,
df.global.world.items.other.SKIN_TANNED, .TOTEM, .CHEESE, .FOOD, .FOOD_STORAGE
```

(Complete list verified against `items_other` definition in
`df.item.xml` lines 2298-2403 and `items_other_id` lines 1718-2295.)

> Practical tip: iterating `items.other.X` is **much** faster than
> walking `items.all` and filtering, especially on big forts.

### 2.1  Element type `df.item`

Top-level fields (`df.item.xml` line 459):

| Field          | Type                | Notes |
|----------------|---------------------|-------|
| `id`           | `int32_t`           | Stable item id |
| `pos`          | `coord`             | Map position; meaningful only if `flags.on_ground` |
| `flags`        | `item_flags`        | See below |
| `flags2`       | `item_flags2`       | Added in v0.34.08 |
| `age`          | `uint32_t`          | Game ticks since creation |
| `stockpile_countdown`, `stockpile_delay` | int8 | Stockpile housekeeping |
| `weight`       | `massst` compound   | `.weight`, `.weight_fraction` (only if `flags.weight_computed`) |

Subtype, material, and type all come from **virtual methods**, not
data fields. Use:

```lua
local it = df.global.world.items.all[0]
it:getType()           -- enum df.item_type, e.g. df.item_type.WEAPON
it:getSubtype()        -- int16; -1 if no subtype
it:getMaterial()       -- int16 mat_type
it:getMaterialIndex()  -- int32 mat_index
it:getActualMaterial() / getActualMaterialIndex()
it:getRace() / it:getCaste()       -- only for items made of "specific creature mat"
it:getDimension()                  -- liquid/cloth dimensions
it:getStockpile()                  -- pointer to item_stockpile_ref or nil
it:isFoodStorage(), it:isCrafted(), it:isPlaster(), it:hasToolUse(use)
```

> **WARNING:** `item.subtype`, `item.mat_type`, `item.mat_index` do *not*
> exist as plain fields on the base `df.item`. Subclasses
> (`item_weaponst`, `item_armorst`, etc.) have a `subtype` pointer of
> their own type and the materials live in `mat_type`/`mat_index`
> there, but the generic, future-proof access is the vmethods above.

### 2.2  `item.flags` — `item_flags` bits (`df.item.xml` line 385)

| Bit | Field name           | Meaning |
|-----|----------------------|---------|
| 0   | `on_ground`          | Lying on the floor — `pos` is valid |
| 1   | `in_job`             | Reserved by a job |
| 2   | `hostile`            | Owned by hostile (PRESERVED) |
| 3   | `in_inventory`       | Inside a creature/workshop/container |
| 4   | `removed`            | Invisible, no position |
| 5   | `in_building`        | Part of a built building |
| 6   | `container`          | Contains other items |
| 7   | `dead_dwarf`         | Corpse / body part of a dwarf |
| 8   | `rotten`             | |
| 9   | `spider_web`         | Thread in a web |
| 10  | `construction`       | Used in a construction tile |
| 11  | `encased`            | Encased in ice / obsidian |
| 13  | `murder`             | Used for fell-mood markers |
| 14  | `foreign`            | Imported |
| 15  | `trader`             | Belongs to a caravan |
| 16  | `owned`              | Owned by a dwarf |
| 17  | `garbage_collect`    | Marked for deletion by DF |
| 18  | `artifact`           | True artifact |
| 19  | `forbid`             | Forbidden by the player |
| 20  | `already_uncategorized` | Internal cleanup |
| 21  | `dump`               | Designated for dumping |
| 22  | `on_fire`            | Burning (setting it ignites!) |
| 23  | `melt`               | Designated for melting |
| 24  | `hidden`             | Hidden from UI |
| 26  | `use_recorded`       | Transient |
| 27  | `artifact_mood`      | Crafted-artifact / named existing |
| 28  | `temps_computed`     | Has good temperature info |
| 29  | `weight_computed`    |  |
| 30  | `top_open`           | Container open |
| 31  | `from_worldgen`      | Don't retain on worldgen |

`flags2` includes: `has_rider`, `forbid_on_unretire`, `grown`,
`location_reserved`, `utterly_destroyed`, `might_contain_artifact`.

### 2.3  Filtering examples

```lua
-- All food on the ground that is not forbidden / dumped / rotten:
for _, it in ipairs(df.global.world.items.other.FOOD) do
    if it.flags.on_ground and not it.flags.forbid
       and not it.flags.dump and not it.flags.rotten then
        ...
    end
end

-- Equip-able weapons currently free:
for _, it in ipairs(df.global.world.items.other.WEAPON) do
    if not it.flags.in_inventory and not it.flags.in_job
       and not it.flags.in_building and not it.flags.forbid then
        local subtype_id = it:getSubtype()
        ...
    end
end
```

Helpers: `dfhack.items.getPosition(it)`, `dfhack.items.getDescription(it,0)`,
`dfhack.items.getGeneralRef(it, df.general_ref_type.UNIT_HOLDER)`,
`dfhack.items.getContainedItems(it)`, `dfhack.items.moveToGround(it, pos)`,
`dfhack.items.moveToContainer(it, container)`.

### 2.4  Builtin Materials and Industry Filters (Ash, Lye, Soap, Tallow, Oil)

*   **Builtin Materials (`df.builtin_mats`)**: Used to identify materials that do not have custom indexes in the inorganic raws.
    *   **Ash**: `item:getMaterial() == df.builtin_mats.ASH` (on items of type `BAR`).
    *   **Lye**: `item:getMaterial() == df.builtin_mats.LYE` (on items of type `LIQUID_MISC`).
*   **Soap**: Checked by inspecting material flags:
    ```lua
    local mat = dfhack.matinfo.decode(item:getMaterial(), item:getMaterialIndex())
    local is_soap = mat and mat.material and mat.material.flags.SOAP
    ```
*   **Tallow & Fats**: Stored as globs (`df.item_type.GLOB`). Checked via material tokens:
    ```lua
    local mat = dfhack.matinfo.decode(item:getMaterial(), item:getMaterialIndex())
    if mat and mat.material then
        local token = mat:getToken() or ""
        local is_tallow = token:find('TALLOW') or token:find('FAT')
    end
    ```
*   **Oils**: Stored as liquids (`df.item_type.LIQUID_MISC`). Checked via material tokens:
    ```lua
    local mat = dfhack.matinfo.decode(item:getMaterial(), item:getMaterialIndex())
    local is_oil = mat and mat.material and (mat:getToken() or ""):find('OIL')
    ```

---

## 3. `df.global.world.buildings.all`

`world.buildings` is `building_handler` (`df.building.xml` line 2743):

```
df.global.world.buildings.all     -- every building (stl-vector<building*>)
df.global.world.buildings.other.*  -- by category (e.g. WORKSHOP_ANY, IN_PLAY, ZONE_*, ANY_FREE)
```

Element type `df.building` (`df.building.xml` line 323). Coordinates
are two corners plus a "work" center:

| Field          | Type                              | Notes |
|----------------|-----------------------------------|-------|
| `id`           | `int32_t`                         | Stable |
| `x1`, `y1`     | `int32_t`                         | Top-left corner |
| `x2`, `y2`     | `int32_t`                         | Bottom-right corner |
| `centerx`, `centery` | `int32_t`                   | Work position (e.g. craftsdwarf stands here) |
| `z`            | `int32_t`                         | Z-level |
| `flags`        | `building_flags` bitfield         | `exists`, `site_blocked`, `room_collision`, `almost_deleted`, etc. |
| `mat_type`     | `int16_t`                         | Material |
| `mat_index`    | `int32_t`                         | Material index |
| `room`         | compound                          | See below |
| `age`          | `int32_t`                         |  |
| `race`         | `int16_t`                         |  |
| `jobs`         | `vector<job*>`                    | Queued jobs at this building |
| `name`         | `stl-string`                      | Player nickname |
| `general_refs` | vector of refs                    | Linked stockpiles, owners, etc. |
| `relations`    | `vector<building_civzonest*>`     | Zones overlapping this building |

### 3.1  Type discovery is also virtual

```lua
local b = df.global.world.buildings.all[0]
b:getType()        -- df.building_type enum
b:getSubtype()     -- e.g. workshop_type or furnace_type
b:getCustomType()  -- positive index into raws if a custom workshop
```

`df.building_type` (`df.d_basics.xml` line 10797) values relevant here:

```
NONE = -1
Chair, Bed, Table, Coffin,
FarmPlot,
Furnace, TradeDepot, Shop,
Door, Floodgate,
Box, Weaponrack, Armorstand, Workshop, Cabinet, Statue,
WindowGlass, WindowGem, Well, Bridge,
RoadDirt, RoadPaved, SiegeEngine,
Trap, AnimalTrap, Support, ArcheryTarget, Chain, Cage,
Stockpile, Civzone, Weapon,
Wagon, ScrewPump, Construction, Hatch,
GrateWall, GrateFloor, BarsVertical, BarsFloor,
GearAssembly, AxleHorizontal, AxleVertical,
WaterWheel, Windmill, TractionBench, Slab,
NestBox, Hive, Rollers, Instrument, DisplayFurniture, OfferingPlace,
BookcaseAttachedTo, BookcaseInPlay, ...
```

Use `df.building_type[t]` to get the string name, or
`df.building_type.attrs[t].name` for the human-readable label.

### 3.2  Room / "is_room" semantics

There is **no** boolean called `is_room` on `df.building`. A building
acts as a room iff its `room` compound has a non-nil `extents` pointer
and non-zero `width`/`height`:

```
building.room.extents  -- pointer<uint8_t> (building_extents_type per tile); nil = not a room
building.room.x, .y    -- top-left of extents rectangle
building.room.width, .height
```

The DFHack helper is:

```lua
dfhack.buildings.isActivityZone(bld)
dfhack.buildings.isPenPasture(bld)
dfhack.buildings.isPitPond(bld)
dfhack.buildings.isActive(bld)
dfhack.buildings.getRoomDescription(bld, unit) -- "Royal Bedroom" etc.
dfhack.buildings.findCivzonesAt(pos)
```

For a Bedroom, you want a `Bed` building (`getType() == df.building_type.Bed`)
whose `room.extents` is non-nil — that designated rectangle is the
bedroom. `bed.owner` (pointer to `df.unit`) tells you who sleeps there.
A stockpile is `getType() == df.building_type.Stockpile` and its tiles
sit in `room.extents` (encoded with `building_extents_type.Stockpile`).
A workshop is `getType() == df.building_type.Workshop`, and the specific
shop kind is `b:getSubtype()` (e.g. `df.workshop_type.Carpenters`).
A farm plot is `getType() == df.building_type.FarmPlot`.

### 3.3  Center coords for navigation

`(b.centerx, b.centery, b.z)` is the tile a worker stands on, which is
what you want for pathfinding queries. For zones/stockpiles iterate
`room.extents[(x - room.x) + (y - room.y) * room.width]` (skip
`building_extents_type.None` entries).

### 3.4  Levers & Linked Mechanisms (Bridges, Gates)

*   **Linked Mechanisms**: A lever (instance of `df.building_trapst` with `trap_type == df.trap_type.Lever`) stores links to target gates/bridges in `linked_mechanisms`:
    ```lua
    local links = lever_bld.linked_mechanisms
    for m_idx = 0, #links - 1 do
        local m = links[m_idx]
        local tref = dfhack.items.getGeneralRef(m, df.general_ref_type.BUILDING_HOLDER)
        if tref then
            local tg = tref:getBuilding()
            -- tg is the target building (e.g., bridge or floodgate)
        end
    end
    ```
*   **Gate/Bridge State**: The current open/closed status is stored in `tg.gate_flags`:
    *   **Bridges (`df.building_type.Bridge`)**:
        *   `tg.gate_flags.raised`: Bridge is closed (raised up/wall).
        *   `tg.gate_flags.raising`: Bridge is currently closing.
        *   `tg.gate_flags.lowering`: Bridge is currently opening.
        *   Otherwise (none of the above): Bridge is open (lowered down/flat).
    *   **Weapon Traps (`df.building_type.Weapon`)**:
        *   `tg.gate_flags.retracted`: Spikes are in (retracted).
    *   **Floodgates / Doors**:
        *   `tg.gate_flags.closed`: Door/gate is shut.
        *   `tg.gate_flags.closing`: Door/gate is shutting.
        *   `tg.gate_flags.opening`: Door/gate is opening.

---

## 4. Map structures

`df.global.world.map` is the `map` compound inside `df.world.xml`
(line 571). Not a real struct in the C++ source — it's a flat region
of globals exposed by DFHack as if it were a compound.

| Field                                        | Type                              |
|----------------------------------------------|-----------------------------------|
| `map.map_blocks`                             | `stl-vector<map_block*>` (every loaded 16×16×1 block) |
| `map.block_index[bx][by][bz]`                | `map_block*` (raw 3-level pointer array) |
| `map.map_block_columns`                      | `stl-vector<map_block_column*>`  |
| `map.column_index[bx][by]`                   | `map_block_column*`              |
| `map.x_count`, `.y_count`, `.z_count`        | Tile dimensions (e.g. 192, 192, 200) |
| `map.x_count_block`, `.y_count_block`, `.z_count_block` | Block dimensions (tile/16) |
| `map.region_x`, `.region_y`, `.region_z`     | World-coords of the active embark |

Get sizes via:

```lua
local sx, sy, sz = dfhack.maps.getTileSize()   -- map.x_count, y_count, z_count
local bx, by, bz = dfhack.maps.getSize()       -- map.x_count_block, y_count_block, z_count_block
```

### 4.1  `map_block` (`df.block.xml` line 226)

```
block.map_pos               -- coord of the block's top-left tile (multiple of 16 in x and y)
block.region_pos            -- coord2d for region offsets
block.flags                 -- block_flags bitfield (designated, has_aquifer, has_magma_close, ...)
block.tiletype[x][y]        -- enum df.tiletype, 16×16 static array; index is LOCAL (0..15)
block.designation[x][y]     -- tile_designation bitfield (see below)
block.occupancy[x][y]       -- tile_occupancy bitfield
block.temperature_1[x][y]   -- current temperature (uint16)
block.temperature_2[x][y]   -- ambient/normal temperature
block.lighting[x][y]        -- 0-100
block.path_cost[x][y]       -- pathfinding flood
block.walkable[x][y]        -- region IDs; equal nonzero IDs = walkable between
block.path_tag[x][y]        -- pathfinding iteration tag
block.items                 -- vector<int32_t> item ids on this block
block.block_events          -- vector<block_square_event*> (minerals, grass, spatter, ice)
block.block_burrows         -- linked list of burrows touching this block
block.local_feature         -- index into world_data.region_map
block.global_feature        -- world_underground_region ref
block.layer_depth           -- vague layer info
```

**Indexing convention:** local tile coords inside a block are
`(global_x % 16, global_y % 16)`. Verified in
[tile-material.lua](file:///home/mikey/Games/DwarfFortress/hack/lua/tile-material.lua#L80):

```lua
local block = dfhack.maps.getTileBlock(pos.x, pos.y, pos.z)  -- or ensureTileBlock
local d = block.designation[pos.x % 16][pos.y % 16]
local geo = d.geolayer_index
```

DFHack helpers (C++ binding):

```
dfhack.maps.getTileBlock(x, y, z)            -- nil if not allocated
dfhack.maps.ensureTileBlock(x, y, z)         -- allocates if missing
dfhack.maps.getTileType(x, y, z)             -- shortcut to block.tiletype[lx][ly]
dfhack.maps.getTileFlags(x, y, z)            -- designation, occupancy
dfhack.maps.isValidTilePos(x, y, z)
dfhack.maps.getRegionBiome(rx, ry)
dfhack.maps.canWalkBetween(pos1, pos2)
dfhack.maps.hasTileAssignment(blockMap, x, y) -- for burrow bitmaps
```

`df.tiletype` (`df.d_basics.xml` line 6148) is a 16-bit enum with
shape/material/variant/special attributes. Examples:

```
df.tiletype.OpenSpace, .Void, .RampTop, .MurkyPool,
df.tiletype.Floor, .Wall, .ConstructedFloor, .StoneFloor1..4,
df.tiletype.Tree, .Sapling, .Shrub, .BoulderRock, ...
-- attrs:
df.tiletype.attrs[t].caption / .shape / .material / .variant / .special
```

`df.tiletype_shape` and `df.tiletype_material` are the real per-tile
classification you'll usually compare against.

### 4.2  `tile_designation` bits

`flow_size` (3), `pile`, `dig` (3 → `tile_dig_designation`),
`smooth` (2), `hidden`, `geolayer_index` (4), `light`, `subterranean`,
`outside`, `biome` (4), `liquid_type` (Water/Magma), `water_table`,
`rained`, `traffic` (2 → `tile_traffic`), `flow_forbid`, `liquid_static`,
`feature_local`, `feature_global`, `water_stagnant`, `water_salt`.

`tile_dig_designation` values: `No`, `Default`, `UpDownStair`, `Channel`,
`Ramp`, `DownStair`, `UpStair`.

### 4.3  `tile_occupancy` bits

`building` (3 → `tile_building_occ`: `None`, `Planned`, `Passable`,
`Obstacle`, `Well`, `Floored`, `Impassable`, `Dynamic`),
`unit` (standing creature here), `unit_grounded` (prone creature),
`item`, `edge_flow_in`, `moss`, `arrow_color` (4), `arrow_variant`,
`unhide_trigger`, `monster_lair`, `no_grow`,
`carve_track_north/south/east/west`, `spoor`, `eerie_light`,
`dig_marked`, `dig_auto`, `heavy_aquifer`, `vehicle`.

---

## 5. Common gotchas

* **Vector indexing is 0-based**, not 1-based, when iterating with
  `ipairs` over DFHack-wrapped `stl-vector`s. `ipairs` *does* start at
  key 0 for DFHack vectors — the wrapper supports it. `#vec` returns
  the count; `vec.size` is the underlying `std::vector::size`. They
  agree in practice; prefer `#vec` from Lua. Raw memory access via
  `vec[i]` with `i < 0 or i >= #vec` will crash the game.
* **`for _, x in ipairs(vec) do ... end`** iterates from index 0 to
  `#vec - 1` for DFHack vectors (this is special-cased by the binding —
  do NOT add `+1` adjustments you'd use in pure Lua tables).
* **`pairs` on a class instance** lists field names. Use `printall(obj)`
  (in the `lua` console) to dump fields and values quickly.
* **Pointer fields may be `nil`.** Examples:
  - `unit.job.current_job` is `nil` whenever the unit is idle.
  - `unit.health` is `nil` until `flags3.compute_health` runs.
  - `unit.current_soul` is `nil` for soulless creatures.
  - `building.room.extents` is `nil` unless the building defines a room.
  - `dfhack.maps.getTileBlock(...)` returns `nil` for unallocated blocks
    (very common at the world edges or unexplored z-levels in
    adventure mode).
  - `dfhack.units.getNoblePositions(u)` returns `nil`, not `{}`, when
    the unit holds no positions.
* **`flags1.dead` does not exist.** The XML field is `flags1.inactive`;
  always prefer `dfhack.units.isDead(u)` / `dfhack.units.isActive(u)`.
* **Item `subtype`/`mat_type`/`mat_index` are vmethods on the base
  `df.item`** — call `it:getSubtype()`, `it:getMaterial()`,
  `it:getMaterialIndex()` (and `getActualMaterial*` if you don't want
  creature-mat indirection). The plain fields exist only on subclasses
  and shift between DF versions.
* **`world.units.all` ≠ `world.units.active`.** `all` includes off-map
  / historical units and units in armies elsewhere; iterating it is
  expensive. Use `active` for "on the current map".
* **Buildings vs civzones.** A `building_civzonest` inherits from
  `building` but its `getType()` returns `Civzone`. Stockpiles and
  workshops live in the same `buildings.all` vector. Use the `other`
  sub-vectors (`buildings.other.STOCKPILE`, `.WORKSHOP_ANY`, etc.) to
  pre-filter.
* **Coords:** DF uses `(x, y, z)` with `z` increasing upward. Some
  APIs accept a `coord` table `{x=,y=,z=}` (`xyz2pos(x,y,z)` builds
  one).
* **Tile-local vs global.** In `block.tiletype[x][y]` etc., `x` and
  `y` must be in `0..15`. Use `(global_x % 16, global_y % 16)`.
* **`pos.z` of items / buildings.** `item.pos` is only valid if
  `item.flags.on_ground` (or you correlate via `flags.in_inventory` →
  `dfhack.items.getHolderUnit(item)`). For buildings use
  `(b.centerx, b.centery, b.z)`.
* **DF version drift.** Field renames and new flags between DF
  releases (and DFHack memory-bind updates) happen frequently. The
  *bit position* of `flags1.dead`/`inactive` has been stable for a
  decade, but new flags are inserted at the end. Anything with
  `since='vX.Y.Z'` in the XML may be missing on older DF builds. The
  current install at `/home/mikey/Games/DwarfFortress/symbols.xml`
  pins the offsets actually in use.
* **Don't write to flags you don't own.** Toggling `flags1.dead` or
  `flags2.killed` doesn't actually kill or unkill — DF's own
  bookkeeping won't catch up. Use proper functions
  (`dfhack.units.kill`, `dfhack.units.setNickname`, the `exterminate`
  script's helpers, etc.).
* **`status.labors`** is indexed by the `unit_labor` enum
  (`labors[df.unit_labor.MINE] = true`), not by string.

---

## 6. Runtime inspection helpers

You can verify any of the above at runtime by entering the DFHack
console (press `~` in-game, or run `dfhack-run` from a shell) and using:

* `lua` — open the interactive Lua REPL. `q` to leave.
* `lua "@<expr>"` — print the given expression. The `@` prints with
  `printall_recurse`. Most useful one-liners:

  ```text
  lua "@df.global.world.units.active[0]"
  lua "@df.global.world.units.active[0].flags1"
  lua "@df.global.world.units.active[0].job"
  lua "@df.global.world.items.all[0]"
  lua "@df.global.world.buildings.all[0]"
  lua "@df.building_type"
  lua "@df.item_type"
  lua "@dfhack.maps.getTileBlock(df.global.cursor.x, df.global.cursor.y, df.global.cursor.z)"
  ```

* `:lua expr` — same as `lua "@expr"` when typed into a script REPL.
* `devel/query` — recursive field walker. Examples:
  ```
  devel/query -unit -search flags1
  devel/query -unit -getfield job.current_job
  devel/query -item -search subtype
  devel/query -building -maxdepth 3
  devel/query -tile -getfield designation
  devel/query -block -search aquifer
  devel/query -script 'df.global.world.buildings.all[0]' -maxdepth 2
  ```
  Script lives at
  [scripts/devel/query.lua](file:///home/mikey/Games/DwarfFortress/hack/scripts/devel/query.lua).
* `devel/dump-offsets [name|all]` — prints the global address table and
  writes XML the `symbols.xml` loader uses. Script at
  [scripts/devel/dump-offsets.lua](file:///home/mikey/Games/DwarfFortress/hack/scripts/devel/dump-offsets.lua).
* `devel/visualize-structure <expr>` — dump raw bytes of any
  structure for alignment checks. Useful when a field name "doesn't
  exist": it might be at a different offset because the local
  `symbols.xml` is older. Script at
  [scripts/devel/visualize-structure.lua](file:///home/mikey/Games/DwarfFortress/hack/scripts/devel/visualize-structure.lua).
* `devel/find-primitive`, `devel/scan-vtables`, `devel/check-other-ids`
  — locate things in memory; mostly relevant for DFHack hackers, but
  `devel/check-other-ids` (in
  [scripts/devel/check-other-ids.lua](file:///home/mikey/Games/DwarfFortress/hack/scripts/devel/check-other-ids.lua))
  validates `items.other.*` and `buildings.other.*` indexing
  assumptions.
* `printall(x)` and `printall_recurse(x)` — print a structure's fields.
  Always available in the `lua` REPL.
* `df._displace`, `df.sizeof(x)`, `df.reinterpret_cast(type, addr)` —
  low-level memory tools when fields are suspect.
* `helpdb` — list all DFHack scripts/plugins; e.g.
  `lua "helpdb.search_entries({str='unit'})"`.
* For schema lookup without launching DF, grep the upstream XML:
  ```
  git clone https://github.com/DFHack/df-structures
  grep -n "flags2\|inactive\|merchant" df-structures/df.unit.xml
  ```
  The XML field `name='...'` attribute is exactly what becomes the
  Lua field name; `original-name` is the C++ source name and is only
  useful when cross-referencing Bay12 dumps.

### 6.1  Self-test snippet the AI can run before trusting a field

```lua
-- saved as scripts/dwarfmind/probe.lua
local target = ...                              -- e.g. "flags1.merchant"
local u = df.global.world.units.active[0]
local ok, val = pcall(function()
    local v = u
    for part in target:gmatch('[^.]+') do v = v[part] end
    return v
end)
if not ok then qerror('Missing field: ' .. target) end
print(target, '=', tostring(val))
```

Run with `dfhack-run dwarfmind/probe flags1.merchant`.

---

## 7. Quick-reference cheat-sheet

```
-- Iterate active units
for _, u in ipairs(df.global.world.units.active) do
    local citizen = dfhack.units.isCitizen(u)
    local pos     = xyz2pos(dfhack.units.getPosition(u))
    if u.job.current_job then
        print(u.id, df.job_type[u.job.current_job.job_type])
    end
end

-- Iterate edible food only
for _, it in ipairs(df.global.world.items.other.FOOD) do
    if it.flags.on_ground and not it.flags.rotten then
        print(it.id, it:getMaterial(), it:getMaterialIndex())
    end
end

-- Iterate workshops
for _, b in ipairs(df.global.world.buildings.all) do
    if b:getType() == df.building_type.Workshop then
        print(b.id, df.workshop_type[b:getSubtype()],
              b.centerx, b.centery, b.z)
    end
end

-- Read a tile
local b = dfhack.maps.ensureTileBlock(x, y, z)
local tt = b.tiletype[x%16][y%16]
local d  = b.designation[x%16][y%16]
local o  = b.occupancy[x%16][y%16]
print(df.tiletype[tt], df.tiletype.attrs[tt].shape,
      d.hidden, d.dig, o.building, o.unit)
```

---

## 8. Manager Orders & Workorders (`df.global.world.manager_orders`)

DwarfMind uses manager orders to queue manufacturing tasks dynamically.

### 8.1  `df.manager_order` Structure

The list of active orders is located in `df.global.world.manager_orders` (C++ vector of `df.manager_order` pointers).

| Field | Type | Description |
|---|---|---|
| `job_type` | `df.job_type` enum | Type of work to perform (e.g. `MakeBarrel`, `MakeLye`, `MakeSoap`, `MakeTool`). |
| `amount_total` | `int32_t` | Target production count. |
| `amount_left` | `int32_t` | Quantity remaining to be constructed. |
| `item_subtype` | `int16_t` | Tool/pot/item subtype index. Valid for jobs like `MakeTool`. |
| `material_category` | bitfield | Required material groups (e.g., `wood` or `stone`). |

### 8.2  Auditing Custom Subtypes
For generic job types like `MakeTool`, query the item definition raws to check the exact item subtype being produced:
```lua
local mgr_orders = df.global.world.manager_orders
for o = 0, #mgr_orders - 1 do
    local order = mgr_orders[o]
    if order.job_type == df.job_type.MakeTool and order.item_subtype >= 0 then
        local is_pot = false
        pcall(function()
            local tool_def = df.global.world.raws.itemdefs.tools[order.item_subtype]
            if tool_def and tool_def.id == 'ITEM_TOOL_LARGE_POT' then
                is_pot = true
            end
        end)
        if is_pot then
            local remaining = order.amount_left
        end
    end
end
```

## 9. Fortress Administration & UI Globals (`df.global.plotinfo`)

`df.global.plotinfo` (type `df.plotinfost`) contains coordinates, active civilization information, and various management sub-structures.

### 9.1  Burrows (`plotinfo.burrows`)
Burrow information is stored in the compound `df.global.plotinfo.burrows` (type `df.burrow_infost`).
*   **Active Burrows Vector**: `df.global.plotinfo.burrows.list` (stl-vector of `df.burrow*`).
*   **Next ID**: `df.global.plotinfo.burrows.next_id`.
*   **Burrow Struct (`df.burrow`)**:
    *   `id`: `int32_t` (stable local ID).
    *   `name`: `stl-string`.
    *   `units`: `stl-vector<int32_t>` (assigned unit IDs; binary vector).
    *   `flags`: `burrow_flag` bitfield:
        *   `limit_workshops`: workshops inside this burrow are restricted to assigned dwarves.
        *   `suspended`: burrow is temporarily disabled.
    *   *Note: For checking tile containment, do not manually parse the raw block coordinates (`block_x/y/z` vectors). Use `dfhack.burrows.isAssignedTile(burrow, x, y, z)`.*

### 9.2  Civilian Alerts (`plotinfo.alerts`)
Civilian alert states and safety burrows are managed under `df.global.plotinfo.alerts` (type `df.alert_state_infost`).
*   **Alert States Vector**: `df.global.plotinfo.alerts.list` (stl-vector of `df.alert_statest*`).
*   **Active Alert Index**: `df.global.plotinfo.alerts.civ_alert_idx` (`int32_t`). Set to `-1` if no civilian alert is active, or the index of the active alert in `list`.
*   **Alert State Struct (`df.alert_statest`)**:
    *   `id`: `int32_t`.
    *   `name`: `stl-string`.
    *   `burrows`: `stl-vector<int32_t>` (civilian safety burrow IDs. When the alert is active, civilians are restricted to these burrows).

### 9.3  Kitchen Exclusions (`plotinfo.kitchen`)
Kitchen settings (restrictions on cooking or brewing) are tracked via parallel vectors in `df.global.plotinfo.kitchen`.

> [!WARNING]
> **DF Version Drift / Naming Discrepancies**:
> Depending on your DFHack version, the kitchen exclusion vectors have two possible sets of names:
>
> 1. **Legacy/Local Names (used in the DwarfMind codebase)**:
>    * `kitchen.excl_item_type` (stl-vector of `df.item_type`)
>    * `kitchen.excl_mat_type` (stl-vector of `int16_t`)
>    * `kitchen.excl_mat_index` (stl-vector of `int32_t`)
>    * `kitchen.excl_type` (stl-vector of `int8_t` where `0` = Cook, `1` = Brew)
>
> 2. **Upstream/Newer DFHack Names**:
>    * `kitchen.item_types` (stl-vector of `df.item_type`)
>    * `kitchen.mat_types` (stl-vector of `int16_t`)
>    * `kitchen.mat_indices` (stl-vector of `int32_t`)
>    * `kitchen.exc_types` (stl-vector of `df.kitchen_exc_type` bitfield where `.Cook` and `.Brew` are flags)

*   **Manipulating Exclusions**: To ban/unban materials, search the vectors in parallel for a matching `item_type`, `mat_type`, and `mat_index`. Insert a new index with `:insert('#', value)` to ban, or remove with `:erase(index)` to unban.

### 9.4  Caravans & Visitors (`plotinfo.caravans`)
*   **Active Caravans Vector**: `df.global.plotinfo.caravans` (stl-vector of `df.caravan_state*`).
*   **Caravan State Struct (`df.caravan_state`)**:
    *   `trade_state`: `enum` (`None` = 0, `Approaching` = 1, `AtDepot` = 2, `Leaving` = 3, `Stuck` = 4).
    *   `time_remaining`: `int16_t` (ticks remaining before caravan departs).
    *   `entity`: `int32_t` (historical entity ID of the civilization).
    *   `mood`: `int32_t` (satisfaction with trading, init 50. Lower mood makes merchants refuse to trade).
    *   `goods`: `stl-vector<int32_t>` (item IDs already brought to/appraised at the depot).
    *   `depot_notified`: `int8_t` (warns if a depot is needed).

---

## 10. Military & Squads (`df.squad` and `df.global.world.squads`)

*   **Global Squads Vector**: `df.global.world.squads.all` (stl-vector of `df.squad*`).
*   **Squad Struct (`df.squad`)**:
    *   `id`: `int32_t` (unique squad ID).
    *   `name`: `language_name` compound.
    *   `alias`: `stl-string` (player nickname).
    *   `positions`: `stl-vector<df.squad_position*>` (squad slots/members).
        *   `occupant`: `int32_t` (historical figure ID of the dwarf in this position; `-1` if empty).
    *   `rooms`: `stl-vector<df.squad_barracks_infost*>` (assigned barracks).
        *   `building_id`: `int32_t` (associated barracks building ID).
        *   `mode`: `squad_use_flags` bitfield (controls sleep, train, equipment store).
    *   `ammo.ammunition`: `stl-vector<df.squad_ammo_spec*>` (ammunition specs).

---

## 11. Nobles, Mandates & Justice

### 11.1 Mandates (`df.global.world.mandates`)
Nobles issue mandates that restrict trade or require manufacturing.
*   **Active Mandates Vector**: `df.global.world.mandates.all` (stl-vector of `df.mandate*`).
*   **Mandate Struct (`df.mandate`)**:
    *   `unit`: pointer to `df.unit` (noble issuing the mandate).
    *   `mode`: `df.mandate_type` enum (`Export` = 0, `Make` = 1, `Guild` = 2).
    *   `item_type` / `item_subtype`: type and subtype index of the mandated item.
    *   `mat_type` / `mat_index`: material type and index.
    *   `amount_total`: total amount of items required.
    *   `amount_remaining`: amount left to make.
    *   `timeout_counter`: `int32_t` (increments once per 10 frames).
    *   `timeout_limit`: `int32_t` (once `timeout_counter >= timeout_limit`, mandate expires).

---

## 12. Game Time & Frame Counters

*   **`df.global.world.frame_counter`**: Raw number of frames elapsed since embark (1 frame = 1 tick).
*   **`df.global.cur_year_tick`**: Tick offset within the current year.
    *   `1,200` ticks = 1 day.
    *   `28` days = 1 month (`33,600` ticks).
    *   `12` months = 1 year (`403,200` ticks).
    *   *Calculation for current day of month*: `(df.global.cur_year_tick // 1200) % 28 + 1`.

---

## 13. DFHack Library Functions

When writing reflexes, prefer safe DFHack Lua wrappers over direct raw pointer traversal:

| Module / Function | Description |
|---|---|
| `dfhack.isMapLoaded()` | Returns `true` if a fort map is currently loaded and safe to query. |
| `dfhack.pcall(fn, ...)` | Safe call wrapper. Captures C++ exceptions and Lua crashes. **Must be used for all critical queries.** |
| `dfhack.units.getCitizens(true)` | Returns a 1-indexed Lua table of all citizens (ignores hostiles/visitors). |
| `dfhack.units.getNoblePositions(u)` | Returns noble titles/positions held by unit `u` (or `nil` if none). |
| `dfhack.units.getPosition(u)` | Safely retrieves the unit's coords (resolves cages, riders, etc.). |
| `dfhack.burrows.isAssignedUnit(burrow, u)` | Checks if unit `u` is assigned to `burrow`. |
| `dfhack.burrows.isAssignedTile(burrow, x, y, z)` | Checks if tile is part of `burrow`. |
| `dfhack.matinfo.decode(type, index)` | Decodes material code and index into a `matinfo` object. |
| `dfhack.matinfo.find(token)` | Finds a material by token string (e.g. `'PLANT_MAT:MUSHROOM_HELMET_PLUMP:STRUCTURAL'`). |
| `dfhack.maps.getTileBlock(x, y, z)` | Safely retrieves the `map_block` containing coordinate `(x,y,z)`. |

---

End of reference.
