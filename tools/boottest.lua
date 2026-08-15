#!/usr/bin/env lua5.4
-- boottest.lua IMG TEST.lua -- boot the image with the test payload
-- injected via fw_cfg, wait for the guest to power off, and emit the
-- TAP the guest printed on com1. everything else on the serial line
-- is passed through as TAP diagnostics on failure.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. package.path
local arch = require("arch")
local q = arch.quote

local TIMEOUT = os.getenv("TIMEOUT") or "60"
local img, payload = arg[1], arg[2]

-- --services: start the payload as the last entry of an injected
-- service list, under the real init.lua, instead of in place of it. A
-- test that wants a network needs this -- the stack is services now --
-- and a test of the kernel alone wants the bare machine it gets
-- without it. See tools/boottest-svc.lua.
local as_service = false

for i = 3, #arg do
	if arg[i] == "--services" then
		as_service = true
	end
end

-- NET=1 gives the guest a real NIC on qemu's usermode (slirp) network:
-- gateway 10.0.2.2, dns 10.0.2.3, guest 10.0.2.15 via slirp's built-in
-- dhcp. without it the guest sees no tcp4/udp4 service binding at all
-- and the net tasks are never spawned -- which is the right default
-- for tests that don't care, since dhcp costs real boot seconds.
local netargs
if os.getenv("NET") == "1" then
	netargs = "-netdev user,id=n0 -device " .. arch.NIC .. ",netdev=n0"
else
	netargs = "-net none"
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

local function have(cmd)
	return os.execute("command -v " .. cmd .. " >/dev/null 2>&1") == true
end

-- $$ under Lua: /proc/self/stat's first field, linux-only -- same as
-- everything else here that assumes a linux host (kvm, /dev/kvm
-- checks in arch.lua).
local function getpid()
	local f = io.open("/proc/self/stat", "r")
	if not f then
		return nil
	end
	local line = f:read("l")
	f:close()
	return tonumber(line:match("^(%d+)"))
end

local tmp = assert(popen_line("mktemp -d"), "mktemp -d failed")

-- what the guest is told to run, from tools/fwcfg.lua so the harnesses
-- and the host-driven tests all say it once.
local fwcfg = ""

for _, a in ipairs(require("fwcfg").args(payload,
    { services = as_service, dir = tmp, tools = scriptdir })) do
	fwcfg = fwcfg .. " " .. (a:sub(1, 1) == "-" and a or q(a))
end

local function cleanup()
	os.execute("rm -rf " .. q(tmp))
end

os.execute("cp " .. q(arch.FW_VARS) .. " " .. q(tmp .. "/vars.fd"))

-- pin the guest to ONE host cpu.
--
-- an unpinned vcpu thread that migrates between host cores can wedge
-- OVMF in boot device selection -- spinning at ~100% until the
-- timeout, with the serial log stopping right before "BdsDxe: loading
-- Boot0002", so before our binary is ever loaded. it looks exactly
-- like a guest hang and is not one.
--
-- measured: 32 guests unpinned lose 12, 64 guests unpinned lose 19,
-- and 64 guests PINNED TWO TO A CORE lose none. so the trigger is
-- migration, not contention -- oversubscribing a pinned core is fine.
--
-- it is also specific to the KVM path: 96 unpinned TCG boots stalled
-- none, against 10 of 96 under kvm, which matches the arm and risc-v
-- suites never seeing this in ~150 unpinned cross-tcg boots. that is
-- consistent with host tsc skew across cores, since kvm passes the
-- host tsc through with a per-vcpu offset while tcg synthesises a
-- clock that cannot skew -- but the loop inside OVMF has not been
-- identified, so this is a correlation and not a diagnosis. note
-- -invtsc and -tsc-deadline change nothing, which is NOT evidence
-- against the tsc story: those are guest-visible cpuid bits and do
-- not affect whether the host tsc is passed through at all.
--
-- pinning by pid spreads parallel invocations with no coordination,
-- and collisions are harmless per the above. it is applied only when
-- arch.lua actually selected kvm -- which it does only for a native
-- guest -- since under tcg there is nothing to fix.
local pin = ""

if arch.MACHINE:find("kvm", 1, true) and have("taskset") and have("nproc") then
	local nproc = tonumber(popen_line("nproc"))
	local pid = getpid()

	if nproc and nproc > 0 and pid then
		pin = "taskset -c " .. (pid % nproc)
	end
end

-- -snapshot: the (possibly shared, parallel) image is never written.
-- the guest powers off via ResetSystem(shutdown) when the test is
-- done; -no-reboot turns any triple-fault into an exit instead of a
-- hang.
local cmd = table.concat({
	"timeout", TIMEOUT, pin, arch.QEMU,
	arch.MACHINE, "-display none", netargs, arch.VIDEO, arch.RNG,
	"-monitor none",
	"-no-reboot -snapshot",
	"-serial file:" .. q(tmp .. "/serial.log"),
	arch.wire_args("null"),
	fwcfg,
	"-drive if=pflash,format=raw,readonly=on,file=" .. q(arch.FW_CODE),
	"-drive if=pflash,format=raw,file=" .. q(tmp .. "/vars.fd"),
	"-drive " .. arch.BLK .. ",file=" .. q(img),
	">/dev/null 2>&1",
}, " ")

local execok, how, code = os.execute(cmd)
local rc = execok and 0 or (code or 1)

local function readfile(path)
	local f = io.open(path, "rb")
	if not f then
		return ""
	end
	local d = f:read("a")
	f:close()
	return d
end

-- strip cr + ansi
local raw = readfile(tmp .. "/serial.log")
local clean = raw:gsub("\r", "")
clean = clean:gsub("\27%[[%d;=]*%a", "")

local lines = {}
for line in (clean .. "\n"):gmatch("([^\n]*)\n") do
	lines[#lines + 1] = line
end

local function is_tap_line(line)
	return line:match("^1%.%.") ~= nil or line:match("^ok ") ~= nil or
	    line:match("^not ok ") ~= nil or line:match("^# ") ~= nil
end

local saw_plan = false

-- keep TAP lines
for _, line in ipairs(lines) do
	if is_tap_line(line) then
		print(line)
		if line:match("^1%.%.") then
			saw_plan = true
		end
	end
end

if rc ~= 0 then
	print("# qemu exited with " .. rc .. " (124 = timeout); full serial trace:")
	for _, line in ipairs(lines) do
		print("# " .. line)
	end
	print("not ok - boottest harness (qemu rc=" .. rc .. ")")
	cleanup()
	os.exit(1)
end

if not saw_plan then
	print("# no TAP plan seen; full serial trace:")
	for _, line in ipairs(lines) do
		print("# " .. line)
	end
	print("not ok - boottest harness (no TAP output)")
	cleanup()
	os.exit(1)
end

cleanup()
os.exit(0)
