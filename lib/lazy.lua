-- require, deferred.
--
-- A module required at the top of a file is loaded whether or not the
-- proc ever uses it, and its Protos stay resident for the life of the
-- proc. An aggregator makes that worse: lib/fat.lua sets M.check and
-- M.ram from require, so opening a volume loads the checker and a ram
-- backend nothing on a board touches.
--
-- Three forms, for three shapes of use:
--
--	lazy.mod(name)		 loads when a field is read
--	lazy.fn(name, field)	 loads when the result is called
--	lazy.method(cls, m, name) loads when cls:m() is called
--
-- mod is the general one and fn is the sharper tool: reading a field of
-- a mod proxy loads the module, so passing mod("romfs").new to a
-- registry defeats it, and fn does not.
--
-- What this costs, and it is not free:
--
--	* A load error, or a module missing from the build, is raised at
--	  first use rather than at startup. test/boot/test_lazy.lua walks
--	  every name used here and requires it, so the build still fails
--	  on a name that cannot resolve.
--	* A proxy is not the module. It compares unequal, has a different
--	  type, and must not be used as a table key.
--	* A module with load-time side effects runs them later. Do not
--	  wrap one.

local M = {}

-- the module, loaded when something is read from it.
function M.mod(name)
	local real

	local function get()
		if not real then
			real = require(name)
		end
		return real
	end

	return setmetatable({}, {
		__index = function(_, k) return get()[k] end,
		__newindex = function(_, k, v) get()[k] = v end,
		__call = function(_, ...) return get()(...) end,
		__len = function() return #get() end,
		__pairs = function() return pairs(get()) end,
	})
end

-- one function of a module, loaded when it is called. Reading it does
-- not load, which is what lets a mount kind or a codec be registered by
-- name without pulling in the code behind it.
function M.fn(name, field)
	return function(...)
		local m = require(name)

		return (field and m[field] or m)(...)
	end
end

-- a method a mixin installs. The stub loads the module, which overwrites
-- it, and dispatches to what replaced it.
--
-- The identity test is the guard: a module that does not install the
-- method leaves the stub in place, and calling it again would recurse
-- forever.
function M.method(cls, name, modname)
	local stub

	stub = function(self, ...)
		require(modname)
		if rawequal(cls[name], stub) then
			error(modname .. " installs no " .. name, 2)
		end
		return cls[name](self, ...)
	end
	cls[name] = stub
end

return M
