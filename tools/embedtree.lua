#!/usr/bin/env lua5.4
-- embedtree.lua -- the repo-relative paths a self-contained hosted
-- binary carries, one per line, for meson to hand gen_embedfs.lua.
--
-- This is the whole distribution rather than a bootstrap: with
-- --no-host-fs there is no directory to serve, so what is listed here
-- is what the machine has. A disk mounted over it adds the rest.

local DIRS = { "lib", "bin", "task" }
local FILES = { "init.lua" }

-- the root to look under, since a build system does not promise which
-- directory it runs this from. Paths printed stay repo-relative.
local root = ... or "."

local out = {}

for _, d in ipairs(FILES) do
	out[#out + 1] = d
end

for _, d in ipairs(DIRS) do
	local p = io.popen(("cd %s && find %s -name '*.lua' -type f")
	    :format(root, d))

	for line in p:lines() do
		out[#out + 1] = line
	end
	p:close()
end

table.sort(out)
print(table.concat(out, "\n"))
