-- Unit tests for sensors.matches_keywords() — the shared whole-word lever /
-- squad name matcher used by reflex_defense, reflex_access_security,
-- reflex_squad_alert, and reflex_orchestrator.  Regression-locks the
-- Phase-3 fix that killed substring false positives ('floodgate' must not
-- match 'gate').

local sensors = load_module('sensors.lua')
local mk = sensors.matches_keywords

local DEFENSE = { 'gate', 'bridge', 'panic', 'entrance', 'defense' }

it('matches a lone whole word', function()
    assert_true(mk('gate', DEFENSE))
    assert_true(mk('Gate', DEFENSE))            -- case-insensitive
    assert_true(mk('MAIN GATE', DEFENSE))
end)

it('matches underscore / hyphen separated words', function()
    assert_true(mk('main_gate', DEFENSE))
    assert_true(mk('gate-east', DEFENSE))
    -- 'entrance' is a defense keyword; a lever literally named for the
    -- entrance is a defense lever and must match as a whole word.
    assert_true(mk('entrance_to_tavern', { 'entrance' }))
end)

it('rejects substring false positives', function()
    assert_true(not mk('floodgate', DEFENSE))   -- 'gate' inside 'floodgate'
    assert_true(not mk('delegate', DEFENSE))
    assert_true(not mk('gatesman', DEFENSE))
    assert_true(not mk('3defend4', { 'defend' }))
    assert_true(not mk('watchman', { 'watch' }))
end)

it('handles nil and empty names', function()
    assert_true(not mk(nil, DEFENSE))
    assert_true(not mk('', DEFENSE))
end)

it('returns false for an empty keyword list', function()
    assert_true(not mk('gate', {}))
end)
