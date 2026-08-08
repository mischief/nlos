-- lib/lazy.lua: the three forms defer until something wants the module.
--
-- That every name used with lazy resolves is checked by
-- tools/checklazy.lua, on the host: which modules a platform embeds
-- differs, so a guest cannot ask the question for all of them.

local lazy = require("lazy")
local tap = require("tap")

tap.plan(7)

local function loaded(n)
	return package.loaded[n] ~= nil
end

-- ---- mod: loads when a field is read ----
package.loaded["json"] = nil

local json = lazy.mod("json")

tap.ok(not loaded("json"), "mod does not load on its own")
tap.ok(type(json.encode) == "function", "a field reads through")
tap.ok(loaded("json"), "and reading it loaded the module")

-- ---- fn: loads when called, not when read ----
package.loaded["json"] = nil

local enc = lazy.fn("json", "encode")

tap.ok(not loaded("json"), "fn does not load when it is read")
tap.is(enc({ 1, 2 }), "[1,2]", "and forwards its arguments when called")
tap.ok(loaded("json"), "having loaded the module to do it")

-- ---- method: a mixin's method, installed on demand ----
package.loaded["json"] = nil

local Cls = {}

Cls.__index = Cls
lazy.method(Cls, "encode", "json")

tap.ok(not loaded("json"), "method leaves the module unloaded")

tap.done()
os.exit(0)
