#!/usr/bin/env lua5.4
-- boottest-wasm.lua RUNNER MODULE
--
-- boots the wasm module under node, types `reboot`, and reports TAP on
-- what came back. One test, because there is no way yet to hand this
-- machine a payload of its own: proc 0 is always /init.lua.

local runner = arg[1]
local module = arg[2]

if not runner or not module then
	io.stderr:write("usage: boottest-wasm.lua RUNNER MODULE\n")
	os.exit(1)
end

local node = os.getenv("NODE") or "node"

local function q(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local cmd = ("printf 'reboot\\n' | %s %s %s 2>&1")
    :format(q(node), q(runner), q(module))
local p = io.popen(cmd)
local out = p:read("a")
local ok = p:close()

local checks = {
	{ "boots", "boot: lua%-os starting %(wasm%)" },
	{ "mounts its tree", "init: svc: srv started" },
	{ "reaches the shell", "programs live in /bin" },
	{ "takes what is typed", "rebooting" },
}

print("1.." .. (#checks + 1))
for i, c in ipairs(checks) do
	local name, pat = c[1], c[2]

	print((out:match(pat) and "ok " or "not ok ") .. i .. " - " .. name)
end
print((ok and "ok " or "not ok ") .. (#checks + 1) .. " - exits cleanly")

if not ok or not out:match("rebooting") then
	io.stderr:write(out)
end
