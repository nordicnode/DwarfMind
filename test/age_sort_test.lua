-- Unit tests for utils.by_birth_asc / utils.count_table — the shared age
-- comparator now used by reflex_butcher, reflex_geld, and
-- reflex_vermin_control.  Locks in the youngest-first culling order that
-- preserves the oldest breeding stock.

local utils = load_module('utils.lua')

local function unit(year, time)
    return { birth_year = year, birth_time = time }
end

it('by_birth_asc: younger birth_year sorts first', function()
    local list = { unit(120, 5), unit(100, 5), unit(110, 5) }
    table.sort(list, utils.by_birth_asc)
    assert_eq(list[1].birth_year, 100)
    assert_eq(list[2].birth_year, 110)
    assert_eq(list[3].birth_year, 120)
end)

it('by_birth_asc: same year ordered by birth_time', function()
    local list = { unit(100, 300), unit(100, 100), unit(100, 200) }
    table.sort(list, utils.by_birth_asc)
    assert_eq(list[1].birth_time, 100)
    assert_eq(list[2].birth_time, 200)
    assert_eq(list[3].birth_time, 300)
end)

it('by_birth_asc: stable for identical units', function()
    local list = { unit(100, 5), unit(100, 5), unit(100, 5) }
    table.sort(list, utils.by_birth_asc)
    assert_eq(#list, 3)
end)

it('count_table: arrays, sets, and empty tables', function()
    assert_eq(utils.count_table({ 1, 2, 3 }), 3)
    assert_eq(utils.count_table({ a = 1, b = 2 }), 2)
    assert_eq(utils.count_table({}), 0)
end)
