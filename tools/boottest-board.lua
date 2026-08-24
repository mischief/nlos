#!/usr/bin/env lua5.4
-- boottest-board.lua TEST.lua -- run one boot test on a real esp32 and
-- emit the TAP it printed on the console.

--	ESPPORT=/dev/ttyACM3 meson devenv -C build \
--	    lua5.4 tools/boottest-board.lua test/boot/test_channel.lua

-- The counterpart of boottest.lua and boottest-esp32.lua, differing in
-- where the payload comes from: there is no fw_cfg here and rebuilding
-- the image per test would be a flash per test, so the tests ride the
-- luafs volume. Flash once with LUAOS_BOARD_TESTS=1 and they are at
-- /test.

-- A test ends by resetting: tap.done() takes the machine down and an
-- esp32 has no way down but esp_restart, so the board returns by itself
-- and the next test meets a fresh one. That is what the other harnesses
-- get from booting a guest, at the price of a boot rather than a build.

-- The port is ESPPORT, then LUAOS_ESPPORT, the precedence
-- tools/esp32.sh already uses: two boards of a kind are often plugged
-- in at once, so it is named per invocation.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/?.lua;" .. scriptdir .. "/../lib/?.lua;" ..
    package.path

local hostpanel = require("hostpanel")

local port = os.getenv("ESPPORT") or os.getenv("LUAOS_ESPPORT")
local payload = arg[1]
local limit = tonumber(os.getenv("TIMEOUT") or "") or 60

if not payload then
	io.stderr:write("usage: boottest-board.lua TEST.lua\n")
	os.exit(2)
end
if not port then
	io.stderr:write("boottest-board.lua: no port. " ..
	    "ESPPORT=/dev/ttyACM3 ...\n")
	os.exit(2)
end

local name = payload:match("([^/]+)%.lua$")

if not name then
	io.stderr:write("boottest-board.lua: not a lua file: " ..
	    payload .. "\n")
	os.exit(2)
end

-- ---- the board ----

local ok, panel = pcall(hostpanel.open, port)

if not ok or not panel then
	io.stderr:write(("boottest-board.lua: cannot open %s: %s\n")
	    :format(port, tostring(panel)))
	os.exit(2)
end

-- Opening the port is the reset: a carrier with a serial bridge wires
-- DTR and RTS to EN and IO0, so taking the line reboots the board. That
-- is a fresh machine per test, free. A board on the chip's own USB does
-- not, and would want a reboot typed instead.

-- The wait is for the whole boot, not the banner: services print after
-- it, and a command sent into that is one nobody reads.
-- BOARDDEBUG=1 prints both sides of the conversation. A harness that
-- talks to hardware over one wire is hard to reason about from its
-- result alone, and this is the difference between reading what
-- happened and guessing at it.
local debugging = os.getenv("BOARDDEBUG")

local function trace(what, s)
	if debugging then
		io.stderr:write(("---- %s (%d bytes)\n%s\n"):format(what,
		    #s, s))
	end
end

-- Short, because this is the case where taking the line already reset
-- the board: a boot reaches the banner in a few seconds or it was never
-- coming, and waiting out a long timeout to learn that is most of what
-- a test costs.
local BANNER = "programs live in"
local boot, up = panel:expect(BANNER, 7)

trace("after open", boot)

-- and if it did not, ask. Whether taking the line resets the board is
-- the carrier's business -- a serial bridge wires DTR and RTS to EN, the
-- chip's own USB does not -- so both are handled rather than one
-- assumed. A machine already at its prompt is one that has run a test.
if not up then
	panel.f:write("reboot\r\n")
	panel.f:flush()
	boot, up = panel:expect(BANNER, 20)
	trace("after reboot", boot)
end

-- and if it cannot be asked, made to. A test that wedges the machine
-- leaves a console reading nothing, and every test after it fails for
-- a reason of its own -- eight passes then seven identical failures.
-- esptool drives DTR and RTS itself, which is the way back into a
-- board that is not listening.
if not up then
	panel:close()
	os.execute(("esptool --port %s --before default-reset " ..
	    "--after hard-reset chip-id >/dev/null 2>&1"):format(port))
	panel = hostpanel.open(port)
	boot, up = panel:expect(BANNER, 40)
	trace("after hard reset", boot)
end

if not up then
	io.stderr:write(("boottest-board.lua: %s: no boot banner\n")
	    :format(name))
	io.stderr:write(boot:sub(-300) .. "\n")
	print("1..0")
	panel:close()
	os.exit(1)
end

-- The prompt after the banner, so the command is typed at a console
-- that is listening rather than into the tail of a boot.
panel:drain(4, 0.5)

-- What ends a run is what tap.done() prints, not a gap: a test that
-- pauses to wait for something is not a test that has finished.
panel.f:write(("lua /test/%s.lua\r\n"):format(name))
panel.f:flush()

local out, done = panel:expect("# test complete", limit)

trace("after run", out)
if not done then
	-- it may still have said everything it meant to
	out = out .. panel:ask("", 1.0, 5)
end

panel:close()

-- ---- what it said ----
--
-- The console carries the kernel's log as well as the test's output, so
-- TAP is picked out rather than passed through. A boot begins as soon
-- as the test resets, and its banner would otherwise land in the middle
-- of the plan.
local lines = {}
local seen = false

for line in (out .. "\n"):gmatch("(.-)\n") do
	local s = line:gsub("^%s+", ""):gsub("%s+$", "")

	if s:match("^1%.%.%d") or s:match("^ok %d") or
	    s:match("^not ok %d") or s:match("^Bail out!") then
		seen = true
		lines[#lines + 1] = s
	elseif seen and s:match("^#") then
		lines[#lines + 1] = s
	end
end

if not lines[1] then
	print("1..0")
	io.stderr:write(("boottest-board.lua: %s said no TAP in %ds\n")
	    :format(name, limit))
	io.stderr:write(out:sub(-400) .. "\n")
	os.exit(1)
end

print(table.concat(lines, "\n"))

-- A plan that never arrived is a machine that stopped: the test wedged,
-- or reset before it printed. Either is a failure and neither is a
-- passing run with nothing to say.
local planned = out:match("1%.%.(%d+)")

if not planned then
	os.exit(1)
end

local failed, last = 0, 0

for _, s in ipairs(lines) do
	local n = s:match("^ok (%d+)")

	if n then
		last = tonumber(n)
	elseif s:match("^not ok (%d+)") then
		failed = failed + 1
		last = tonumber(s:match("^not ok (%d+)"))
	end
end

-- A test that stopped short is a failure of its own: the machine went
-- down mid-run, and the assertions it never reached are not passes.
if tonumber(planned) > 0 and last < tonumber(planned) then
	io.stderr:write(("boottest-board.lua: %s stopped at %d of %s\n")
	    :format(name, last, planned))
	os.exit(1)
end
os.exit(failed > 0 and 1 or 0)
