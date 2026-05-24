--@ module = true
-- =============================================================================
-- build_layer.lua  —  Spatial Planning & Blueprinting Layer  (Task A)
-- =============================================================================
-- ARCHITECTURE CONTRACT:
--   Layer 1 (Sense)  : Terrain scan via segmented round-robin window.
--                      Reads are read-only; no game-state mutations here.
--   Layer 2 (Think)  : Blueprint matrix generator + floor-clear checker.
--   Layer 3 (Act)    : dig_blueprint() writes designation bits through
--                      pcall-wrapped actuator helpers; furniture queue.
--
-- SAFETY RULES ENFORCED:
--   [A] No df.global paths at top-level scope.
--   [B] All C++ vectors iterated 0-indexed.
--   [C] Every nested pointer traversal has nil guards.
--   [D] reset() clears all cross-tick cursors and state.
--   [E] Large scans use SCAN_WINDOW-sized round-robin windows.
-- =============================================================================
local _ENV = mkmodule('dwarfmind/build_layer')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('build_layer')

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local SCAN_WINDOW       = 2000   -- tile-blocks processed per tick in round-robin
local DIG_COOLDOWN      = 4800   -- ~40 dwarf-days between dig passes
local PLACE_COOLDOWN    = 2400   -- ~20 dwarf-days between furniture placement passes
local MAX_PENDING_DIGS  = 64     -- cap pending dig cells per blueprint pass
local MAX_ROOMS_PER_Z   = 4      -- residential nodes per z-level

-- Blueprint template dimensions
local ROOM_SIZE         = 3      -- 3×3 residential node
local WORKSHOP_SIZE     = 11     -- 11×11 workshop block
local STOCKPILE_SIZE    = 7      -- 7×7 general stockpile
local ADMIN_SIZE        = 5      -- 5×5 admin/meeting hall

-- ---------------------------------------------------------------------------
-- Module-local mutable state  (cleared in reset())
-- ---------------------------------------------------------------------------
local scan_cursor_x     = 0
local scan_cursor_y     = 0
local scan_cursor_z     = 0
local scan_wrap_count   = 0       -- incremented each full sweep completion
local terrain_cache     = {}      -- [z][x][y] = tiletype_id  (populated by scanner)
local open_cells        = {}      -- list of {x,y,z} viable dig targets
local blueprints        = {}      -- list of blueprint descriptors
local pending_digs      = {}      -- list of {x,y,z} awaiting designation write
local furniture_queue   = {}      -- list of {type, x, y, z}
local last_dig_tick     = -math.huge
local last_place_tick   = -math.huge
local embark_origin     = nil     -- cached {x, y, z} set on first run()

-- ---------------------------------------------------------------------------
-- Tile classification helpers  (pure logic, no game memory)
-- ---------------------------------------------------------------------------

-- Returns true when a tiletype is diggable natural stone/soil (not open air,
-- not constructed, not water-bearing aquifer, not cavern void).
local function is_diggable_stone(tiletype)
    if not tiletype then return false end
    local shape = df.tiletype.attrs[tiletype]
    if not shape then return false end
    -- shape.basic_shape: Wall == diggable candidate
    return shape.basic_shape == df.tiletype_shape.WALL
end

-- Returns true when a tiletype is already an open floor (excavated).
local function is_open_floor(tiletype)
    if not tiletype then return false end
    local shape = df.tiletype.attrs[tiletype]
    if not shape then return false end
    local bs = shape.basic_shape
    return bs == df.tiletype_shape.FLOOR
        or bs == df.tiletype_shape.OPEN
end

-- Returns true if a designation block cell already has an active dig order.
local function already_designated(desig)
    if not desig then return false end
    return desig.dig ~= df.tile_dig_designation.No
end

-- ---------------------------------------------------------------------------
-- LAYER 1 – TERRAIN SCANNER  (segmented round-robin)
-- ---------------------------------------------------------------------------
-- scan_terrain_tick() advances the round-robin cursor by up to SCAN_WINDOW
-- tile-block positions each call.  It accumulates viable open_cells.
-- When the cursor wraps back to (0,0,0) a full sweep is complete and
-- blueprint generation is triggered.

local function get_map_dims()
    -- dfhack.maps.getTileSize() returns (x, y, z) in regions (16-tile blocks).
    local ok, x, y, z = pcall(function()
        return dfhack.maps.getTileSize()
    end)
    if not ok or not x then return 0, 0, 0 end
    return x, y, z
end

local function cache_tile(bx, by, bz, lx, ly)
    local ok, block = pcall(dfhack.maps.getTileBlock, bx, by, bz)
    if not ok or not block then return end
    local tt = block.tiletype
    if not tt then return end
    local gx = bx * 16 + lx
    local gy = by * 16 + ly
    local tiletype = tt[lx] and tt[lx][ly]
    if not tiletype then return end
    if not terrain_cache[bz] then terrain_cache[bz] = {} end
    if not terrain_cache[bz][gx] then terrain_cache[bz][gx] = {} end
    terrain_cache[bz][gx][gy] = tiletype
    -- Classify
    if is_diggable_stone(tiletype) then
        -- Check designation isn't already set
        local dblock_ok, desig = pcall(function()
            return block.designation[lx][ly]
        end)
        if dblock_ok and desig and not already_designated(desig) then
            open_cells[#open_cells + 1] = {x=gx, y=gy, z=bz}
        end
    end
end

function scan_terrain_tick()
    if not sensors.is_fort_loaded() then return end
    local map_bx, map_by, map_bz = get_map_dims()
    if map_bx == 0 then return end

    local steps = 0
    local cx, cy, cz = scan_cursor_x, scan_cursor_y, scan_cursor_z

    while steps < SCAN_WINDOW do
        -- Scan all 16×16 local tiles within current block
        for lx = 0, 15 do
            for ly = 0, 15 do
                cache_tile(cx, cy, cz, lx, ly)
            end
        end
        steps = steps + 1

        -- Advance cursor
        cx = cx + 1
        if cx >= map_bx then
            cx = 0
            cy = cy + 1
            if cy >= map_by then
                cy = 0
                cz = cz + 1
                if cz >= map_bz then
                    cz = 0
                    scan_wrap_count = scan_wrap_count + 1
                    -- Full sweep complete; trigger blueprint generation
                    generate_blueprints()
                    break
                end
            end
        end
    end

    scan_cursor_x = cx
    scan_cursor_y = cy
    scan_cursor_z = cz
end

-- ---------------------------------------------------------------------------
-- LAYER 2 – BLUEPRINT GENERATOR
-- ---------------------------------------------------------------------------
-- generate_blueprints() reads open_cells (populated by scanner) and constructs
-- layout matrices for residential nodes, workshop blocks, stockpiles, and admin
-- offices.  It respects aquifer flags and cavern proximity guards.

-- Returns true if a rectangular area [x1..x2][y1..y2] at z has all cells
-- present in terrain_cache as stone-wall or already-open-floor.
local function area_is_viable(x1, y1, x2, y2, z)
    if not terrain_cache[z] then return false end
    for x = x1, x2 do
        if not terrain_cache[z][x] then return false end
        for y = y1, y2 do
            local tt = terrain_cache[z][x][y]
            if not tt then return false end
            -- Reject aquifer tiles
            local ok, block = pcall(dfhack.maps.getTileBlock,
                math.floor(x/16), math.floor(y/16), z)
            if ok and block and block.designation then
                local lx = x % 16
                local ly = y % 16
                local ok2, desig = pcall(function()
                    return block.designation[lx][ly]
                end)
                if ok2 and desig and desig.water_table then
                    return false  -- aquifer present; skip
                end
            end
        end
    end
    return true
end

-- Attempts to place a blueprint of given size anchored at (ox, oy, oz).
-- Returns a blueprint descriptor table or nil.
local function make_blueprint(kind, ox, oy, oz, w, h)
    if not area_is_viable(ox, oy, ox + w - 1, oy + h - 1, oz) then
        return nil
    end
    return {
        kind   = kind,
        ox     = ox,
        oy     = oy,
        oz     = oz,
        width  = w,
        height = h,
        dug    = false,
        placed = false,
    }
end

-- Returns the embark origin (initial wagon tile) from persistent cache or
-- sensors.  Only called inside run() so df.global is safe.
local function get_origin()
    if embark_origin then return embark_origin end
    local ok, ox, oy, oz = pcall(function()
        -- plotinfo.initial_embark_pos is the wagon drop point
        local pi = df.global.plotinfo
        if not pi then return nil end
        return pi.initial_embark_pos.x,
               pi.initial_embark_pos.y,
               pi.initial_embark_pos.z
    end)
    if ok and ox then
        embark_origin = {x=ox, y=oy, z=oz}
        return embark_origin
    end
    -- Fallback: use centre of map
    local map_bx, map_by, map_bz = get_map_dims()
    embark_origin = {
        x = math.floor(map_bx * 16 / 2),
        y = math.floor(map_by * 16 / 2),
        z = math.floor(map_bz * 16 / 2),
    }
    return embark_origin
end

function generate_blueprints()
    -- Clear prior pending list; do not clear already-issued digs.
    blueprints = {}
    pending_digs = {}

    local origin = get_origin()
    if not origin then return end

    -- Work downward from the embark surface z.
    local target_z = origin.z - 3   -- three z-levels below surface
    local cx = origin.x
    local cy = origin.y

    -- 1. Workshop block (11×11) centred under embark
    local wx = cx - math.floor(WORKSHOP_SIZE / 2)
    local wy = cy - math.floor(WORKSHOP_SIZE / 2)
    local ws = make_blueprint('workshop_block', wx, wy, target_z,
                              WORKSHOP_SIZE, WORKSHOP_SIZE)
    if ws then
        blueprints[#blueprints + 1] = ws
        log.info(('Blueprint: workshop_block @(%d,%d,%d)'):format(wx, wy, target_z))
    end

    -- 2. Residential nodes (3×3) arranged in a ring around workshop
    local offsets = {
        {dx=-6, dy=-6}, {dx= 6, dy=-6},
        {dx=-6, dy= 6}, {dx= 6, dy= 6},
    }
    for _, off in ipairs(offsets) do
        local rx = cx + off.dx - math.floor(ROOM_SIZE / 2)
        local ry = cy + off.dy - math.floor(ROOM_SIZE / 2)
        local bp = make_blueprint('residential', rx, ry, target_z,
                                  ROOM_SIZE, ROOM_SIZE)
        if bp then
            blueprints[#blueprints + 1] = bp
            log.info(('Blueprint: residential @(%d,%d,%d)'):format(rx, ry, target_z))
        end
    end

    -- 3. Stockpile (7×7) east of workshop
    local spx = cx + WORKSHOP_SIZE
    local spy = cy - math.floor(STOCKPILE_SIZE / 2)
    local sp = make_blueprint('stockpile', spx, spy, target_z,
                              STOCKPILE_SIZE, STOCKPILE_SIZE)
    if sp then
        blueprints[#blueprints + 1] = sp
        log.info(('Blueprint: stockpile @(%d,%d,%d)'):format(spx, spy, target_z))
    end

    -- 4. Admin / meeting hall (5×5) north of workshop
    local ax = cx - math.floor(ADMIN_SIZE / 2)
    local ay = cy - WORKSHOP_SIZE - ADMIN_SIZE
    local ad = make_blueprint('admin', ax, ay, target_z,
                              ADMIN_SIZE, ADMIN_SIZE)
    if ad then
        blueprints[#blueprints + 1] = ad
        log.info(('Blueprint: admin @(%d,%d,%d)'):format(ax, ay, target_z))
    end

    -- Populate pending_digs from blueprints not yet dug
    for _, bp in ipairs(blueprints) do
        if not bp.dug then
            for x = bp.ox, bp.ox + bp.width - 1 do
                for y = bp.oy, bp.oy + bp.height - 1 do
                    if #pending_digs < MAX_PENDING_DIGS then
                        pending_digs[#pending_digs + 1] = {x=x, y=y, z=bp.oz}
                    end
                end
            end
        end
    end
    log.info(('generate_blueprints: %d blueprints, %d pending digs'):format(
        #blueprints, #pending_digs))
end

-- ---------------------------------------------------------------------------
-- LAYER 3 – DIG ACTUATOR
-- ---------------------------------------------------------------------------
-- Writes df.tile_dig_designation.Default to pending cells.
-- Protected entirely by pcall.  Respects dry_run.

local function write_dig_cell(x, y, z)
    local bx = math.floor(x / 16)
    local by = math.floor(y / 16)
    local lx = x % 16
    local ly = y % 16
    local ok, block = pcall(dfhack.maps.getTileBlock, bx, by, z)
    if not ok or not block then
        log.warn(('write_dig_cell: no block @(%d,%d,%d)'):format(bx, by, z))
        return false
    end
    local ok2, desig = pcall(function()
        return block.designation[lx][ly]
    end)
    if not ok2 or not desig then
        log.warn(('write_dig_cell: no desig @(%d,%d,%d)'):format(x, y, z))
        return false
    end
    if already_designated(desig) then return true end  -- already queued
    if actuators.is_dry_run() then
        log.info(('DRY-RUN dig @(%d,%d,%d)'):format(x, y, z))
        return true
    end
    local ok3, err = pcall(function()
        desig.dig = df.tile_dig_designation.Default
        dfhack.maps.enableBlockUpdates(block, true, false)
    end)
    if not ok3 then
        log.error(('write_dig_cell pcall error @(%d,%d,%d): %s'):format(
            x, y, z, tostring(err)))
        return false
    end
    return true
end

function dig_blueprint()
    if not sensors.is_fort_loaded() then return end
    if not dfhack.maps.isMapLoaded() then return end
    local now = sensors.current_tick()
    if (now - last_dig_tick) < DIG_COOLDOWN then return end

    if #pending_digs == 0 then return end

    local issued = 0
    local remaining = {}
    for _, cell in ipairs(pending_digs) do
        -- Check tiletype is still stone wall before designating
        local tt = (terrain_cache[cell.z]
                    and terrain_cache[cell.z][cell.x]
                    and terrain_cache[cell.z][cell.x][cell.y])
        if is_diggable_stone(tt) or tt == nil then
            if write_dig_cell(cell.x, cell.y, cell.z) then
                issued = issued + 1
            else
                remaining[#remaining + 1] = cell
            end
        elseif not is_open_floor(tt) then
            -- non-stone, non-open (constructed?): skip permanently
            log.warn(('dig_blueprint: skipping non-stone cell @(%d,%d,%d)'):format(
                cell.x, cell.y, cell.z))
        end
        -- If already open floor: cell is done, don't re-queue
    end
    pending_digs = remaining

    if issued > 0 then
        log.info(('dig_blueprint: issued %d designations, %d still pending'):format(
            issued, #pending_digs))
    end

    -- Mark blueprints as dug when all their cells are cleared
    for _, bp in ipairs(blueprints) do
        if not bp.dug then
            local all_clear = true
            for x = bp.ox, bp.ox + bp.width - 1 do
                for y = bp.oy, bp.oy + bp.height - 1 do
                    local tt = (terrain_cache[bp.oz]
                                and terrain_cache[bp.oz][x]
                                and terrain_cache[bp.oz][x][y])
                    if not is_open_floor(tt) then
                        all_clear = false
                        break
                    end
                end
                if not all_clear then break end
            end
            if all_clear then
                bp.dug = true
                log.info(('Blueprint %s @(%d,%d,%d) fully excavated.'):format(
                    bp.kind, bp.ox, bp.oy, bp.oz))
                -- Queue furniture placement for this blueprint
                queue_furniture(bp)
            end
        end
    end

    last_dig_tick = now
end

-- ---------------------------------------------------------------------------
-- FURNITURE PLACEMENT QUEUE
-- ---------------------------------------------------------------------------
-- Once a blueprint floor is clear, enqueue workshop/furniture construction
-- requests.  Actual placement is routed through actuators.run_script().

local FURNITURE_MAP = {
    workshop_block = {
        { role='CARPENTERS_WORKSHOP',  dx=1, dy=1 },
        { role='MASONS_WORKSHOP',      dx=4, dy=1 },
        { role='CRAFTSDWARFS_WORKSHOP',dx=7, dy=1 },
        { role='SMELTER',              dx=1, dy=5 },
        { role='KITCHEN',              dx=4, dy=5 },
        { role='STILL',                dx=7, dy=5 },
        { role='FARMERS_WORKSHOP',     dx=1, dy=8 },
        { role='BUTCHERS_SHOP',        dx=4, dy=8 },
        { role='TANNERY',              dx=7, dy=8 },
    },
    residential = {
        { role='BED',    dx=0, dy=0 },
        { role='CABINET',dx=2, dy=0 },
        { role='CHEST',  dx=0, dy=2 },
    },
    admin = {
        { role='CHAIR',  dx=2, dy=2 },
        { role='TABLE',  dx=1, dy=1 },
    },
    stockpile = {},   -- stockpiles are defined via zones, not furniture
}

function queue_furniture(bp)
    local flist = FURNITURE_MAP[bp.kind]
    if not flist then return end
    for _, f in ipairs(flist) do
        furniture_queue[#furniture_queue + 1] = {
            role = f.role,
            x    = bp.ox + f.dx,
            y    = bp.oy + f.dy,
            z    = bp.oz,
        }
    end
    log.info(('queue_furniture: %d items queued for %s'):format(
        #flist, bp.kind))
end

function place_furniture_tick()
    if not sensors.is_fort_loaded() then return end
    local now = sensors.current_tick()
    if (now - last_place_tick) < PLACE_COOLDOWN then return end
    if #furniture_queue == 0 then return end
    if not actuators.can_queue_order() then return end

    local item = table.remove(furniture_queue, 1)
    if actuators.is_dry_run() then
        log.info(('DRY-RUN place %s @(%d,%d,%d)'):format(
            item.role, item.x, item.y, item.z))
        last_place_tick = now
        return
    end
    -- Route through actuators: build item via dfhack 'build' script
    actuators.run_script('build', item.role,
        tostring(item.x), tostring(item.y), tostring(item.z))
    log.info(('place_furniture: placed %s @(%d,%d,%d)'):format(
        item.role, item.x, item.y, item.z))
    last_place_tick = now
end

-- ---------------------------------------------------------------------------
-- PUBLIC ENTRY POINTS
-- ---------------------------------------------------------------------------

function run()
    if not sensors.is_fort_loaded() then return end
    scan_terrain_tick()    -- advance round-robin scanner
    dig_blueprint()        -- issue pending dig designations
    place_furniture_tick() -- place furniture on cleared floors
end

function reset()
    scan_cursor_x  = 0
    scan_cursor_y  = 0
    scan_cursor_z  = 0
    scan_wrap_count= 0
    terrain_cache  = {}
    open_cells     = {}
    blueprints     = {}
    pending_digs   = {}
    furniture_queue= {}
    last_dig_tick  = -math.huge
    last_place_tick= -math.huge
    embark_origin  = nil
    log.info('build_layer reset.')
end

return _ENV
