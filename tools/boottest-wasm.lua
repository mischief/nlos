#!/usr/bin/env lua5.4
-- boottest-wasm.lua RUNNER MODULE BROWSERTEST WORKER SCRIPT
--
-- boots the module three ways -- console, screen, and the browser page
-- driven by a script -- and reports TAP on what came back. Nothing
-- emits TAP from inside the guest: proc 0 is always /init.lua, so the
-- console and the pixels are what is read.

local runner, module, browser, worker, script =
    arg[1], arg[2], arg[3], arg[4], arg[5]

if not runner or not module then
	io.stderr:write("usage: boottest-wasm.lua RUNNER MODULE " ..
	    "[BROWSERTEST WORKER SCRIPT]\n")
	os.exit(1)
end

local node = os.getenv("NODE") or "node"

local function q(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function run(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")

	return out, p:close()
end

local function boot(input, flags)
	return run(("printf %s | %s %s %s %s")
	    :format(q(input), q(node), q(runner), q(module), flags or ""))
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
	-- the network this machine has, which is websockets and nothing
	-- under them. Whether a relay answers is not this test's business.
	{ "has a websocket task", "wssrv: pid %d+" },
	{ "lends it to the panel", "init: granted:.* ws" },
}

local n = 0

local function tap(good, name)
	n = n + 1
	print((good and "ok " or "not ok ") .. n .. " - " .. name)
end

local function report(text, list)
	for _, c in ipairs(list) do
		tap(text:match(c[2]), c[1])
	end
end

-- the page, driven through the same worker a browser loads. Four
-- claims, and each one is a bug that shipped: the panel paints at all,
-- an app started from the tray survives the arrow keys (an arrow is
-- ESC [ A, and a program reading a bare ESC quits), and the wheel
-- reaches a program that reads it.
local bchecks = 4
local bout = ""

if browser then
	bout = run(("%s %s %s %s /dev/null 16000 %s")
	    :format(q(node), q(browser), q(module), q(worker), q(script)))
end

local function px(name)
	return bout:match("px " .. name .. " (%x+)")
end

print("1.." .. (#checks + #gchecks + bchecks + 1))
report(out, checks)
report(gout, gchecks)

if browser then
	local before, after = px("2048%-in%-tray"), px("2048%-after%-arrows")
	local pen1, pen2 = px("pen%-before%-wheel"), px("pen%-after%-wheel")

	tap(bout:match("term: %d+x%d+"), "the page paints the panel")
	tap(before == "edc22e", "an app starts from the tray")
	tap(after == before, "the arrow keys do not kill it")
	tap(pen1 and pen2 and pen1 ~= pen2, "the wheel changes the pen")
else
	for _, name in ipairs({ "the page paints the panel",
	    "an app starts from the tray", "the arrow keys do not kill it",
	    "the wheel changes the pen" }) do
		n = n + 1
		print("ok " .. n .. " - " .. name .. " # skip no script given")
	end
end

tap(ok, "exits cleanly")

if not ok or not out:match("rebooting") then
	io.stderr:write(out)
end
