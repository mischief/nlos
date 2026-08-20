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

local function boot(input, flags)
	local p = io.popen(("printf %s | %s %s %s %s 2>&1")
	    :format(q(input), q(node), q(runner), q(module), flags or ""))
	local out = p:read("a")

	return out, p:close()
end

local out, ok = boot("reboot\\n")

-- the same machine with a screen, which is what starts the panel. The
-- keyboard has the input there, so `reboot` is typed at the terminal
-- dio boots rather than at the console.
local gout = boot("reboot\\r", "--fb 320x240 --shot /dev/null 6000")

local checks = {
	{ "boots", "boot: lua%-os starting %(wasm%)" },
	{ "mounts its tree", "init: svc: srv started" },
	{ "reaches the shell", "programs live in /bin" },
	{ "takes what is typed", "rebooting" },
}

local gchecks = {
	{ "opens a screen", "fb: 320x240 bgrx" },
	{ "starts the panel", "init: svc: dio started" },
	{ "runs a program in it", "term: %d+x%d+" },
}

local n = 0

local function report(text, list)
	for _, c in ipairs(list) do
		n = n + 1
		print((text:match(c[2]) and "ok " or "not ok ") .. n ..
		    " - " .. c[1])
	end
end

print("1.." .. (#checks + #gchecks + 1))
report(out, checks)
report(gout, gchecks)
n = n + 1
print((ok and "ok " or "not ok ") .. n .. " - exits cleanly")

if not ok or not out:match("rebooting") then
	io.stderr:write(out)
end
