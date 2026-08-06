-- DwarfMind test runner — dependency-free, runs on plain Lua 5.3+.
-- (DFHack embeds Lua 5.3; CI runs Lua 5.4; both work.)
-- Usage:  lua test/run.lua [filter]
--   filter  optional substring; only tests whose name contains it run.
-- Exit code 0 = all green, 1 = test failures, 2 = harness error.

-- ─── Repo root resolution ────────────────────────────────────────────────
local here = arg[0]:match('^(.*)[/\\][^/\\]*$') or 'test'
local repo = (here == 'test') and '.' or (here .. '/..')

-- ─── DFHack-shaped mock environment ──────────────────────────────────────
-- Modules are loaded with a per-module environment whose __index is _G, so
-- pure functions are callable while any accidental df/dfhack/persistent use
-- at module-load time surfaces as a load error (the AGENTS.md
-- "top-level require check" rule, codified as an automated test).
local logfns = {
    debug = function() end, info = function() end,
    warn  = function() end, err  = function() end,
}

_G.mkmodule = function()
    return setmetatable({}, { __index = _G })
end

_G.reqscript = function(name)
    if name == 'dwarfmind/logger' then
        return { for_module = function() return logfns end }
    end
    return {}
end

_G.require = function()
    return {}
end

-- Load a DwarfMind module file (path relative to the repo root) under the
-- mock and return its exported environment table.
function load_module(path)
    local fn = assert(loadfile(repo .. '/' .. path), 'cannot load ' .. path)
    local ok, mod = pcall(fn)
    if not ok then
        error(('module %s failed at top level: %s'):format(path, tostring(mod)))
    end
    return mod
end

-- ─── Mini test framework ─────────────────────────────────────────────────
local tests = {}
local failures = 0
local total = 0

function it(name, fn)
    tests[#tests + 1] = { name = name, fn = fn }
end

function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or 'assert_eq') .. (': got %s, want %s'):format(tostring(a), tostring(b)))
    end
end

function assert_true(v, msg)
    if not v then error((msg or 'assert_true') .. (': got ' .. tostring(v))) end
end

-- ─── Test discovery ──────────────────────────────────────────────────────
local TEST_FILES = {
    'load_check_test.lua',
    'matches_keywords_test.lua',
    'calendar_day_test.lua',
    'cache_gate_test.lua',
    'age_sort_test.lua',
}

for _, tf in ipairs(TEST_FILES) do
    local path = here .. '/' .. tf
    local chunk, err = loadfile(path)
    if not chunk then
        io.stderr:write(('FATAL: cannot load %s: %s\n'):format(path, tostring(err)))
        os.exit(2)
    end
    local ok, ferr = pcall(chunk)
    if not ok then
        io.stderr:write(('FATAL: %s threw at load: %s\n'):format(path, tostring(ferr)))
        os.exit(2)
    end
end

-- ─── Run ─────────────────────────────────────────────────────────────────
local filter = arg[1]

for _, t in ipairs(tests) do
    if not filter or t.name:find(filter, 1, true) then
        local ok, err = pcall(t.fn)
        if ok then
            io.write(('PASS  %s\n'):format(t.name))
        else
            failures = failures + 1
            io.write(('FAIL  %s\n      %s\n'):format(t.name, tostring(err)))
        end
        total = total + 1
    end
end

io.write(('\n%d/%d tests passed%s\n'):format(total - failures, total,
    failures == 0 and '' or (', ' .. failures .. ' FAILED')))
if failures > 0 then os.exit(1) end
os.exit(0)
