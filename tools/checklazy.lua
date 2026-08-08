#!/usr/bin/env lua5.4
-- every module named through lib/lazy.lua exists.
--
-- A deferred require raises at first use, not at startup, so a name
-- with a typo in it, or a file that has moved, waits in whatever rare
-- branch first touches it. This puts that back at build time. It checks
-- the file is there; whether a platform embeds it is what the payload
-- lists decide, and test/boot/test_lazy.lua covers the mechanism.

local root = arg[1] or "."
local bad, n = {}, 0

local function pathof(name)
	local slashed = name:gsub("%.", "/")

	for _, p in ipairs({ "/lib/" .. name .. ".lua",
	    "/lib/" .. slashed .. ".lua" }) do
		local fh = io.open(root .. p)

		if fh then
			fh:close()
			return p
		end
	end
end

local scan = io.popen("find '" .. root .. "/lib' '" .. root ..
    "/task' '" .. root .. "/bin' -name '*.lua' 2>/dev/null")

for file in scan:lines() do
	local fh = io.open(file)
	local src = fh:read("a")

	fh:close()
	for name in src:gmatch('lazy%.%a+%s*%(?%s*"([%w%._]+)"') do
		n = n + 1
		if not pathof(name) then
			bad[#bad + 1] = file .. ": " .. name
		end
	end
	-- lazy.method takes the module name third, after the class
	for name in src:gmatch('lazy%.method%s*%([^,]+,[^,]+,%s*"([%w%._]+)"') do
		n = n + 1
		if not pathof(name) then
			bad[#bad + 1] = file .. ": " .. name
		end
	end
end
scan:close()

if #bad > 0 then
	for _, b in ipairs(bad) do
		io.stderr:write("checklazy: no such module -- " .. b .. "\n")
	end
	os.exit(1)
end
print(("checklazy: %d lazy references, all resolve"):format(n))
