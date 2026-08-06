-- Unit tests for sensors.should_refresh_cache() — the pure gate behind the
-- Phase-5 two-tier cache.  Locks in: full-snapshot rebuilds happen at most
-- once per SLOW_CACHE_PERIOD, on invalidation (last_tick == -1), and on
-- frame-counter rollback; a failed frame read (now < 0) never rebuilds.

local sensors = load_module('sensors.lua')
local s = sensors.should_refresh_cache

it('gate: never built (last == -1) → refresh', function()
    assert_true(s(-1, 500, 1200))
end)

it('gate: within window → no refresh', function()
    assert_true(not s(100, 500, 1200))
    assert_true(not s(100, 1199, 1200))
    -- built at tick 100 → only 1100 ticks elapsed at now=1200
    assert_true(not s(100, 1200, 1200))
end)

it('gate: window elapsed (>= period) → refresh', function()
    assert_true(s(100, 1300, 1200))   -- exactly one full period elapsed
    assert_true(s(100, 2400, 1200))   -- well past the period
end)

it('gate: frame-counter rollback (fresh world) → refresh', function()
    assert_true(s(500, 100, 1200))
end)

it('gate: failed frame read (now < 0) → keep last snapshot', function()
    assert_true(not s(100, -1, 1200))
    assert_true(not s(-1, -1, 1200))
end)
