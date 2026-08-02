-- Reading an unbound global raises instead of answering nil.
--
-- _G already had an __index -- src/linit.c's lazy library loader, which
-- runs only on a miss -- so this is that function's other half rather
-- than a second metatable. That is also why it is free: a global that
-- is bound never reaches a metamethod, so the check costs nothing
-- except on the path that was already a mistake.
--
-- What it buys: `prit("x")` names `prit` at the line that read it,
-- rather than "attempt to call a nil value" one frame later, or a nil
-- travelling somewhere else entirely before anything notices.

local tap = require("tap")

tap.plan(12)

-- ---- the miss raises, and says which name ----

local ok, err = pcall(function() return anUndefinedName end)

tap.ok(not ok, "reading an unbound global raises")
tap.ok(tostring(err):find("undefined global 'anUndefinedName'") ~= nil,
    "and names it: " .. tostring(err))

-- the error is raised where the read is, so a traceback points at the
-- mistake rather than into the C. The chunk here is "init" -- a boot
-- payload replaces init.lua -- so what is checked is that some chunk
-- and line are attributed at all, which is what luaL_error's level 1
-- gives and what a bare lua_error would not.
tap.ok(tostring(err):find("^%a[%w_]*:%d+: undefined global") ~= nil,
    "reported against the chunk and line that read it: " .. tostring(err))

-- ---- bound globals are untouched ----

tap.ok(type(print) == "function", "an eager global still reads")
tap.ok(type(string) == "table", "so does an eager library")

-- the lazy libraries are the reason this hook exists; they must still
-- load on first reference rather than being called undefined
tap.ok(type(table) == "table", "a lazy library still loads on a miss")
tap.ok(type(math) == "table", "and another")

-- ---- a global bound at runtime ----

_G.boundLater = 42
tap.is(boundLater, 42, "a global bound at runtime reads back")

_G.boundLater = nil
tap.ok(not pcall(function() return boundLater end),
    "and unbinding it makes it undefined again")

-- ---- the escape hatch ----
--
-- rawget does not run metamethods, so code that legitimately asks
-- whether a name is present still can. This is what the absence checks
-- in test_drivers/test_nsio/test_escape use.

tap.is(rawget(_G, "stillNotDefined"), nil,
    "rawget answers nil rather than raising")

-- ---- a non-string key is not a variable name ----
--
-- _G[1] is a table access that happens to land on the globals table;
-- no compiler emitted it for an identifier, so it keeps the old nil.
-- Worth pinning because lua_tostring converts a number key to a string
-- in place, which makes the type test order-sensitive in the C.

tap.is(_G[1], nil, "a numeric key answers nil rather than raising")
tap.is(_G[{}], nil, "so does a table key")

tap.done()
