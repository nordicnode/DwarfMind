-- DwarfMind shared pure helpers.
-- Contains ONLY dependency-free logic (no DFHack / df / df.global access),
-- so it is safe to require at any time and unit-testable without the game.
--@ module = true

local _ENV = mkmodule('dwarfmind/utils')

-- Sort ascending by birth date (youngest first).  Culling then takes the
-- YOUNGEST animals first and preserves the oldest breeding stock — the
-- population-control policy shared by reflex_butcher, reflex_geld, and
-- reflex_vermin_control (previously each file carried its own copy of this
-- comparator; kept here so the ordering logic has exactly one definition).
function by_birth_asc(a, b)
    if a.birth_year ~= b.birth_year then
        return a.birth_year < b.birth_year
    end
    return a.birth_time < b.birth_time
end

-- Count entries in a table.  Works for both 1-indexed arrays and
-- keyed sets (table.sort-compatible, so it mirrors #array semantics for
-- contiguous arrays).
function count_table(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

return _ENV
