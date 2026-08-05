#!/usr/bin/env lua5.4
-- boottest-esp32.lua TEST.lua -- build the esp32 image with TEST.lua as
-- proc 0, boot it under Espressif's qemu, and emit the TAP the guest
-- printed on the console uart.
--
-- The counterpart of tools/boottest.lua (efi) and boottest-microvm.lua,
-- and it differs from both in one structural way: **the payload is
-- chosen at build time, not at boot.** There is no fw_cfg on this
-- machine, so a test cannot be injected into a finished image -- the
-- image is rebuilt for each one, with LUAOS_PAYLOAD pointing at the
-- test. That is why these tests are not parallel: they share one build
-- directory, and two of them building at once would race over it.
--
-- Two things the emulator cannot do, both of which shape what is worth
-- running here:
--
--   * **no PSRAM, in either mode.** qemu-esp32s3 emulates neither octal
--     nor quad, so the guest has only ~210KB of internal SRAM and runs
--     out during the third proc's requires. Tests that spawn procs
--     belong on real hardware; what belongs here is the arch-blind
--     logic -- threads, channels, the scheduler, the serializer.
--   * **no USB-Serial-JTAG**, so the console has to be on UART0. That
--     is what sdkconfig.qemu is for; the board's own build has it the
--     other way round and an image built for the board boot-loops here
--     with no output at all, not even from the bootloader.
--
-- Wants idf.py on PATH (source $IDF_PATH/export.sh) and Espressif's
-- qemu, which is NOT upstream qemu -- upstream has no esp32 machine at
-- all. Install it with
-- `python3 $IDF_PATH/tools/idf_tools.py install qemu-xtensa`; this
-- finds it under ~/.espressif unless QEMU_XTENSA names it.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
local root = scriptdir .. "/.."
local proj = root .. "/esp32"  -- made absolute below

local TIMEOUT = os.getenv("TIMEOUT") or "60"
local payload = arg[1]

local function q(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function popen_line(cmd)
	local f = io.popen(cmd)

	if not f then
		return nil
	end

	local line = f:read("l")

	f:close()
	return line
end

local function readfile(path)
	local f = io.open(path, "rb")

	if not f then
		return ""
	end

	local d = f:read("a")

	f:close()
	return d
end

-- Everything below runs after a `cd`, so every path has to be absolute
-- before the first one happens -- including the payload, which cmake
-- would otherwise resolve against esp32/ and quietly embed nothing.
local cwd = assert(popen_line("pwd"))

local function abs(p)
	return p:match("^/") and p or (cwd .. "/" .. p)
end

if payload then
	payload = abs(payload)
end
proj = abs(proj)

-- Set once the serial log exists; before that a failure has no trace to
-- give, and says so rather than printing an empty one.
local serial = nil

local function dump(why)
	local text = serial and readfile(serial) or ""

	-- readfile answers "" for a missing file as well as an empty one,
	-- which is the same thing to us: nothing was captured.
	if text == "" then
		print("# " .. why .. "; no serial trace (qemu printed nothing)")
		return
	end
	print("# " .. why .. "; full serial trace:")
	for line in (text:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
		print("# " .. line)
	end
end

local function bail(why)
	dump(why)
	print("not ok - boottest-esp32 harness (" .. why .. ")")
	os.exit(1)
end

-- Espressif's qemu. Their fork is the only one with -machine esp32s3;
-- upstream's xtensa target has kc705/lx200/lx60/ml605/sim/virt and
-- nothing else, so finding a qemu-system-xtensa on PATH proves nothing.
local function find_qemu()
	local env = os.getenv("QEMU_XTENSA")

	if env and env ~= "" then
		return env
	end

	local home = os.getenv("HOME") or ""
	local glob = home ..
	    "/.espressif/tools/qemu-xtensa/*/qemu/bin/qemu-system-xtensa"

	return popen_line("ls -1 " .. glob .. " 2>/dev/null | tail -1")
end

local qemu = find_qemu()

if not qemu or qemu == "" then
	bail("no espressif qemu-system-xtensa found (idf_tools.py install " ..
	    "qemu-xtensa)")
end

local tmp = assert(popen_line("mktemp -d"), "mktemp -d failed")

local function cleanup()
	os.execute("rm -rf " .. q(tmp))
end

-- Build with this payload, in a build directory and against a
-- sdkconfig of its own.
--
-- Both are load-bearing. SDKCONFIG_DEFAULTS is consulted only when
-- generating a fresh sdkconfig, so sharing the board's build directory
-- silently reuses the board's console setting -- and the resulting
-- image boot-loops here with no output at all, which reads as the app
-- crashing when the config never changed. Separate dirs also mean a
-- test run does not invalidate whatever is flashed on the board.
local bdir = proj .. "/build-qemu"
local build = table.concat({
	"cd " .. q(proj), "&&",
	"idf.py",
	"-B " .. q(bdir),
	"-DSDKCONFIG=" .. q(bdir .. ".sdkconfig"),
	"-DLUAOS_PAYLOAD=" .. q(payload),
	q("-DSDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.qemu"),
	"build",
	">" .. q(tmp .. "/build.log"), "2>&1",
}, " ")

if os.execute(build) ~= true then
	print("# idf.py build failed:")
	for line in (readfile(tmp .. "/build.log")):gmatch("([^\n]*)\n") do
		print("# " .. line)
	end
	print("not ok - boottest-esp32 harness (build failed)")
	cleanup()
	os.exit(1)
end

-- One flat image at the flash's real size. Padding to less than the
-- size in the image header aborts in spi_flash ("Detected size smaller
-- than the size in the binary image header") and boot-loops before
-- anything of ours runs.
local flash = tmp .. "/flash.bin"
local merge = table.concat({
	"cd " .. q(bdir), "&&",
	"python -m esptool --chip esp32s3 merge-bin --format raw",
	"--pad-to-size 16MB -o " .. q(flash), "@flash_args",
	">/dev/null 2>&1",
}, " ")

if os.execute(merge) ~= true then
	print("not ok - boottest-esp32 harness (merge-bin failed)")
	cleanup()
	os.exit(1)
end

local function is_tap_line(line)
	return line:match("^1%.%.") ~= nil or line:match("^ok ") ~= nil or
	    line:match("^not ok ") ~= nil or line:match("^# ") ~= nil
end

-- Find exactly one complete run in the log, or nil.
--
-- lib/tap.lua emits the plan FIRST and the results after it, so a run
-- is "1..N" followed by N results. Counting them is what says a copy
-- arrived whole rather than trusting the plan: a bare "1..N" with no
-- results is what a payload that died in tap.plan() looks like, and
-- reading it as a pass is how three of these tests were once reported
-- green while dying of "not enough memory".
--
-- -no-reboot means the log normally holds one copy, but the counting
-- and the ESP-ROM reset below stay: a guest that reboots for any reason
-- other than tap.done still must not be reported half-run.
local function extract(text)
	local clean = text:gsub("\r", ""):gsub("\27%[[%d;=]*%a", "")
	local run, want, got = {}, nil, 0

	for line in (clean .. "\n"):gmatch("([^\n]*)\n") do
		local plan = line:match("^1%.%.(%d+)")

		if plan then
			run, want, got = { line }, tonumber(plan), 0
		elseif line:match("^ESP%-ROM:") then
			run, want, got = {}, nil, 0	-- rebooted mid-run
		elseif want and is_tap_line(line) then
			run[#run + 1] = line
			if line:match("^ok ") or line:match("^not ok ") then
				got = got + 1
			end
			if got >= want then
				return run
			end
		end
	end
	return nil
end

-- -no-reboot is what ends the run, and it is worth a word.
--
-- tap.done asks power for mode="shutdown", but this platform has no
-- shutdown: power_reset is esp_restart, because a chip cannot turn
-- itself off. So the guest finishes its TAP and starts over, and
-- without this qemu was still running when TIMEOUT killed it -- 60s per
-- test, pass or fail, against a 5s rebuild. Nearly all of a run was the
-- harness waiting for a clock rather than for the work.
--
-- -no-reboot makes qemu exit on the guest reset instead of restarting
-- it, which turns that same reset into the ordinary end of a run: 1.8s,
-- rc 0, and exactly one copy of the TAP in the log. TIMEOUT stays as
-- the backstop for a guest that never reaches tap.done at all.
serial = tmp .. "/serial.log"

local cmd = table.concat({
	"timeout", TIMEOUT,
	q(qemu),
	"-nographic -machine esp32s3 -no-reboot",
	"-drive file=" .. q(flash) .. ",if=mtd,format=raw",
	"-serial file:" .. q(serial),
	"</dev/null >/dev/null 2>&1",
}, " ")

local execok, _, code = os.execute(cmd)
local rc = execok and 0 or (code or 1)

local run = extract(readfile(serial) or "")
local sawplan = run ~= nil

for _, line in ipairs(run or {}) do
	print(line)
end

-- A guest that finishes its TAP and then sits at a repl is a pass, not
-- a hang: unlike the other platforms there is no ResetSystem and no
-- triple fault to end on, so the timeout is the ordinary way a run
-- stops. Only a run with no plan in it is a failure.
if not sawplan then
	if rc ~= 0 then
		bail("qemu exited with " .. rc .. " (124 = timeout) and " ..
		    "printed no TAP plan")
	end
	bail("no TAP plan seen")
end

cleanup()
os.exit(0)
