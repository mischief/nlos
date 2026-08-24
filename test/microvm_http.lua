#!/usr/bin/env lua5.4
-- http over the lua tcp stack, driven from the host.
--
-- This is the test listen and accept exist for, and the one that says
-- whether the whole thing was worth doing: the guest runs lib/http.lua
-- unmodified, over lib/caps.lua's tcp wrapper unmodified, and the far
-- side is a real client on another machine's network stack. Nothing in
-- the guest payload knows that underneath it is lib/tcb.lua rather than
-- the UEFI firmware -- test/test_http.lua runs the same handler through
-- EFI_TCP4 and asks the same questions.
--
-- It has to be host-driven. A guest cannot open a connection to itself
-- (slirp does not hairpin), and until now nothing in the tree could
-- reach a guest at all: hostfwd is what gives the host a door in, and
-- hostutil is what walks through it.
--
-- The client is test/hosthttp.lua, deliberately not lib/http.lua -- for
-- the reason its own header gives, a test whose client and server are
-- the same code cannot see a bug they share.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

-- tools/ too: fwcfg.lua is shared with the boot harnesses.
local toolsdir = scriptdir .. "/../tools"
package.path = scriptdir .. "/?.lua;" .. package.path .. ";" .. toolsdir .. "/?.lua"

local http = require("hosthttp")
local hostutil = require("hostutil")

local elf = arg[1]
local payload = arg[2]

local count, failed = 0, 0

local function oneline(s)
	return (tostring(s):gsub("%c", function(c)
		if c == "\n" then return "\\n" end
		if c == "\r" then return "\\r" end
		if c == "\t" then return "\\t" end
		return string.format("\\%03d", c:byte())
	end))
end

local function ok(cond, name)
	count = count + 1
	if not cond then
		failed = failed + 1
	end
	print((cond and "ok" or "not ok") .. " " .. count .. " - " ..
	    oneline(name))
	return cond
end

local function is(got, want, name)
	if got ~= want then
		print("# " .. oneline(name) .. ": got " .. oneline(got) ..
		    ", want " .. oneline(want))
	end
	return ok(got == want, name)
end

local function diag(s)
	for line in (tostring(s):gsub("\r", "\n") .. "\n"):gmatch("([^\n]*)\n") do
		print("# " .. line)
	end
end

local function popen_line(cmd)
	local f = io.popen(cmd)

	if not f then
		return nil
	end

	local l = f:read("l")

	f:close()
	return l
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

print("1..11")

local tmp = assert(popen_line("mktemp -d"), "mktemp -d failed")
local serial = tmp .. "/serial.log"
local port = hostutil.free_port()

local function cleanup(pid)
	if pid then
		hostutil.kill(pid)
		hostutil.wait(pid)
	end
	os.execute("rm -rf '" .. tmp .. "'")
end

-- hostfwd is the whole reason this file exists: it binds a host port and
-- forwards connections to the guest's 7777, which is the only way
-- anything outside can reach a listener in there under user networking.
--
-- pit=on and ioapic2=off match every other launcher here; see
-- tools/boottest-microvm.lua for what each one pins and why.
-- the fw_cfg keys come from tools/fwcfg.lua, which the boot harnesses
-- share: a list rather than table.unpack, which mid-constructor would
-- expand to one argument.
local argv = {
	"qemu-system-x86_64",
	"-M", "microvm,pit=on,pic=off,rtc=off,ioapic2=off,acpi=on",
	"-enable-kvm", "-cpu", "host", "-m", "256",
	"-kernel", elf,
}
for _, a in ipairs(require("fwcfg").args(payload,
    { services = true, dir = tmp, tools = toolsdir })) do
	argv[#argv + 1] = a
end
for _, a in ipairs({
	"-device", "virtio-rng-device,bus=virtio-mmio-bus.1",
	"-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:" .. port .. "-:7777",
	"-device", "virtio-net-device,netdev=n0,bus=virtio-mmio-bus.2",
	"-nodefaults", "-no-user-config", "-no-reboot", "-display", "none",
	"-serial", "file:" .. serial,}) do
	argv[#argv + 1] = a
end

local pid = hostutil.spawn(argv)

if not ok(pid ~= nil, "qemu started") then
	cleanup(nil)
	os.exit(1)
end

-- wait for the guest to say it is listening. Gating on the banner rather
-- than on a fixed sleep matters here: the machine has to take a dhcp
-- lease first, and how long that takes is the firmware's business.
local ready = false
local deadline = os.time() + 30

while os.time() < deadline do
	if readfile(serial):find("http test server ready", 1, true) then
		ready = true
		break
	end
	hostutil.sleep(0.05)
end

if not ok(ready, "the guest listened and said so") then
	diag("serial transcript:")
	diag(readfile(serial))
	cleanup(pid)
	os.exit(1)
end

local HOST = "127.0.0.1"

-- ---- one request ----

local res, err = http.get(hostutil, HOST, port, "/hello")

if not ok(res ~= nil, "a request gets a response") then
	diag("error: " .. tostring(err))
	diag(readfile(serial))
	cleanup(pid)
	os.exit(1)
end

is(res.status, 200, "with the status the handler chose")
is(res.body, "you asked for /hello", "and the body it built")

-- ---- a second connection ----
--
-- Each request here is its own connection, so this is accept running
-- twice. A listener that hands out one connection and then stops is a
-- plausible bug and would pass every test above.
local res2 = http.get(hostutil, HOST, port, "/again")

is(res2 and res2.body, "you asked for /again", "a second connection is accepted")

-- ---- a body the stack has to break up ----
--
-- 200000 bytes is over MAXMSG, so it cannot cross to the tcp task in one
-- message, and it is well over a hundred segments on the wire. Every one
-- of them has to arrive, in order, through a window that closes and
-- reopens as the client reads.
local big = http.get(hostutil, HOST, port, "/big")

is(big and #big.body, 200000, "a 200KB body arrives whole")
ok(big and big.body == string.rep("x", 200000), "and is what was sent")

-- ---- a request with a body ----
--
-- Data in the other direction, through the same connection, which is
-- where a stack that only ever sends or only ever receives comes apart.
local posted = http.post(hostutil, HOST, port, "/echolen",
    string.rep("z", 5000))

is(posted and posted.body, "5000", "a request body of 5000 bytes arrives whole")

-- ---- static files, and traversal ----

local hello = http.get(hostutil, HOST, port, "/files/hello.txt")

is(hello and hello.body, "static file contents\n", "a static file is served")

local escape = http.get(hostutil, HOST, port, "/files/../secret")

ok(escape and escape.status ~= 200,
    "and a path climbing out of the root is refused")

cleanup(pid)
os.exit(failed == 0 and 0 or 1)
