#!/usr/bin/env lua5.4
-- nap(seconds) -- wait, without spawning a process to do it.
--
-- hostutil.sleep is nanosleep. It is found through HOSTUTIL_SO or the
-- build directory, both of which the test environment sets.
--
-- The fallback shells out, for a tool run by hand outside a build. It
-- is the case this exists to avoid, so it is the case that is loud
-- about being taken.

local sleeper = nil

local function find()
	local so = os.getenv("HOSTUTIL_SO")
	local build = os.getenv("LUAOS_BUILD")

	if not so and build then
		so = build .. "/hostutil.so"
	end
	if not so then
		return nil
	end

	local ok, hu = pcall(function()
		return assert(package.loadlib(so, "luaopen_hostutil"))()
	end)

	if ok and hu and hu.sleep then
		return hu.sleep
	end
	return nil
end

return function(seconds)
	if sleeper == nil then
		sleeper = find() or false
	end
	if sleeper then
		return sleeper(seconds)
	end
	return os.execute("sleep " .. tostring(seconds))
end
