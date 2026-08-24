#!/usr/bin/env lua5.4
-- nap(seconds) -- wait, without spawning a process to do it.
--
-- hostutil.sleep is nanosleep, reached over LUA_CPATH. The fallback
-- shells out, for a tool run by hand outside a build environment.

local sleeper = nil

local function find()
	local ok, hu = pcall(require, "hostutil")

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
