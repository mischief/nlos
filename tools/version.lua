#!/usr/bin/env lua5.4
-- version.lua [OUT] -- the revision this tree builds, as one token.
--
--	lua5.4 tools/version.lua build/VERSION.app
--	lua5.4 tools/version.lua            # to stdout
--
-- Every build system here calls this, so the C symbol, the embedded
-- file and the filesystem images all carry the SAME string and can be
-- compared for equality. That comparison is the point: an app flashed
-- without its filesystem is the mistake this catches.
--
-- No timestamp. Two artifacts of one build are made moments apart, and
-- a clock in the string would make them differ and every check fail.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
local top = scriptdir .. "/.."

local function git(cmd)
	local p = io.popen(("git -C %q %s 2>/dev/null"):format(top, cmd), "r")

	if not p then
		return nil
	end

	local out = p:read("a")

	p:close()
	return out
end

-- FNV-1a over the uncommitted changes. A shorthash alone cannot tell
-- two dirty builds of one commit apart, which is exactly the pair a
-- half-flashed board leaves behind.
local function taint(s)
	local h = 2166136261

	for i = 1, #s do
		h = (h ~ s:byte(i)) * 16777619 % 4294967296
	end
	return ("%08x"):format(h)
end

local rev = (git("rev-parse --short=8 HEAD") or ""):gsub("%s+$", "")

if rev == "" then
	rev = "unknown"
end

-- tracked edits and untracked names both count: a new file that nothing
-- has committed still changes what the build produces.
local dirt = (git("diff HEAD") or "") .. (git("status --porcelain") or "")

if dirt:gsub("%s+", "") ~= "" then
	rev = rev .. "-" .. taint(dirt)
end

-- Rewritten only when it changed. The build runs this every time, on
-- purpose, because the answer depends on the tree rather than on any
-- file a build system could watch -- but touching the output when the
-- revision is the same would relink the kernel on every build.
if arg[1] then
	local old = io.open(arg[1], "r")

	if old then
		local was = old:read("l")

		old:close()
		if was == rev then
			return
		end
	end

	local f = assert(io.open(arg[1], "w"))

	f:write(rev .. "\n")
	f:close()
else
	io.write(rev .. "\n")
end
