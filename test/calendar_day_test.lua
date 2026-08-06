-- Unit tests for sensors.calendar_day() — the 28-day month / 1200-tick-day
-- arithmetic that reflex_quarantine's full-moon window depends on.
-- The df.global.cur_year_tick read is mocked; this regression-locks the
-- floor-division math (DFHack's Lua 5.3 supports the `//` operator).

_G.df = { global = { cur_year_tick = 0 } }
_G.dfhack = { pcall = function(f, ...) return pcall(f, ...) end }

local sensors = load_module('sensors.lua')

local function with_tick(tick, fn)
    _G.df.global.cur_year_tick = tick
    fn()
end

it('calendar: day 1 at tick 0', function()
    with_tick(0, function()
        assert_eq(sensors.calendar_day(), 1)
    end)
end)

it('calendar: day 28 at tick 27*1200 (last day of month)', function()
    with_tick(27 * 1200, function()
        assert_eq(sensors.calendar_day(), 28)
    end)
end)

it('calendar: wraps to day 1 at tick 28*1200 (new month)', function()
    with_tick(28 * 1200, function()
        assert_eq(sensors.calendar_day(), 1)
    end)
end)

it('calendar: mid-month arithmetic', function()
    with_tick(13 * 1200 + 500, function()
        assert_eq(sensors.calendar_day(), 14)
    end)
end)

it('calendar: multi-month offset', function()
    with_tick(2 * 28 * 1200 + 5 * 1200, function()
        assert_eq(sensors.calendar_day(), 6)
    end)
end)
