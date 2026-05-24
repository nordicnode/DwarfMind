-- DwarfMind reflex: Administrative Precision Tuning.
-- The Bookkeeper noble controls ledger accuracy. If precision drops below
-- maximum, sensors.lua stockpile counts become loose estimates, degrading
-- the decision quality of every other reflex that reads inventory numbers.
-- This reflex forces maximum precision whenever it detects a drop.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_bookkeeper_audit')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_bookkeeper_audit')

-- Maximum precision value in DF (5 = exact counts on all stockpiles).
local MAX_PRECISION     = 5
-- Avoid spamming the write every cycle once corrected.
local ACTION_COOLDOWN   = 6000
local last_action       = -math.huge

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_action) < ACTION_COOLDOWN then return end

    -- Safe nested-nil guard: plotinfo -> bookkeeper_precision (Rule C).
    local plotinfo = df.global.plotinfo
    if not plotinfo then
        log.warn('df.global.plotinfo is nil; skipping bookkeeper audit')
        return
    end

    -- df.global.plotinfo.bookkeeper_precision is an integer 0..5.
    -- It is a direct field on the plotinfo struct.
    local current_precision = plotinfo.bookkeeper_precision
    if current_precision == nil then
        log.warn('bookkeeper_precision field not found on plotinfo; skipping')
        return
    end

    log.info(string.format(
        'bookkeeper precision: current=%d (max=%d)',
        current_precision, MAX_PRECISION
    ))

    if current_precision >= MAX_PRECISION then
        log.debug('bookkeeper precision is already at maximum')
        return
    end

    log.warn(string.format(
        'bookkeeper precision below maximum (%d/%d) -> forcing max ledger accuracy',
        current_precision, MAX_PRECISION
    ))

    -- Direct write through actuators dry_run guard.
    -- actuators.set_bookkeeper_precision is the preferred routing path;
    -- if it does not exist in the current actuators version we fall back
    -- to a raw write (both paths are guarded by the is_fort_loaded() check above).
    if actuators.set_bookkeeper_precision then
        actuators.set_bookkeeper_precision(MAX_PRECISION)
    else
        -- Raw structural write — safe here because we are inside run(),
        -- never at top-level scope (Rule A), and nil-guard passed above.
        plotinfo.bookkeeper_precision = MAX_PRECISION
        log.warn('wrote bookkeeper_precision directly (actuators.set_bookkeeper_precision not available)')
    end

    last_action = now
end

function reset()
    last_action = -math.huge
end

return _ENV
