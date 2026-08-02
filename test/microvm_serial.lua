-- serial receive on microvm, driven from the host.
--
-- Unlike scripts/boottest-microvm.lua, which points the guest's serial
-- at a file and only reads, this needs the port in both directions: it
-- writes bytes in and checks the guest reports them back. So the serial
-- is a unix socket and this speaks to it, the same shape test_9p.lua
-- uses for com2 on the efi platform.
--
-- This test exists because its absence was expensive. Serial receive
-- worked throughout a long investigation that concluded it was broken,
-- because the throwaway payload used to check it looked for msg.data on
-- a message lib/wire.lua delivers as a bare string. Nothing exercised
-- the real path, so a false negative looked exactly like a dead driver.

local hostutil = assert(package.loadlib(os.getenv("HOSTUTIL_SO") or
    "./hostutil.so", "luaopen_hostutil"))()

local elf = arg[1]
local payload = arg[2]

local count, failed = 0, 0

local function oneline(s)
	return (tostring(s):gsub("%c", function(c)
		if c == "\n" then return "\\n" end
		if c == "\r" then return "\\r" end
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

local function diag(s)
	for line in (tostring(s):gsub("\r", "\n") .. "\n"):gmatch("([^\n]*)\n") do
		print("# " .. line)
	end
end

print("1..4")

local function popen_line(cmd)
	local f = io.popen(cmd)

	if not f then
		return nil
	end

	local l = f:read("l")

	f:close()
	return l
end

local tmp = assert(popen_line("mktemp -d"), "mktemp -d failed")
local sock = tmp .. "/ser.sock"

local function cleanup(pid)
	if pid then
		hostutil.kill(pid)
		hostutil.wait(pid)
	end
	os.execute("rm -rf '" .. tmp .. "'")
end

-- ioapic2=off pins virtio-mmio to the documented slot layout; see
-- scripts/boottest-microvm.lua for why every launcher passes it.
local pid = hostutil.spawn({
	"qemu-system-x86_64",
	"-M", "microvm,pit=off,pic=off,rtc=off,ioapic2=off,acpi=on",
	"-enable-kvm", "-cpu", "host", "-m", "256",
	"-kernel", elf,
	"-fw_cfg", "name=opt/org.luaos.test,file=" .. payload,
	"-nodefaults", "-no-user-config", "-no-reboot", "-display", "none",
	"-chardev", "socket,id=s0,path=" .. sock .. ",server=on,wait=off",
	"-serial", "chardev:s0",
})

if not ok(pid ~= nil, "qemu started") then
	cleanup(nil)
	os.exit(1)
end

-- the socket appears when qemu binds it, which is not instant
local fd
local deadline = os.time() + 15

while os.time() < deadline do
	fd = hostutil.connect_unix(sock)
	if fd then
		break
	end
	os.execute("sleep 0.2")
end

if not ok(fd ~= nil, "connected to the guest's serial") then
	cleanup(pid)
	os.exit(1)
end

-- Anything the guest printed before this client attached is gone -- a
-- socket server drops output with nobody connected -- so do not gate on
-- a banner. Send repeatedly instead and watch for the echo; the guest
-- reads for 15 seconds, and a resend costs nothing.
local SENT = "hello"
local seen = ""
local echoed = false
local deadline = os.time() + 25

while os.time() < deadline do
	hostutil.send(fd, SENT)

	local chunk = hostutil.recv(fd, 4096, 0.5)

	if chunk and #chunk > 0 then
		seen = seen .. chunk
	end
	-- wait for the whole line, not just the marker: the bytes may
	-- land in a later chunk, and matching early would capture an
	-- empty string and assert nothing.
	if seen:match("SERIALRX got:[^\r\n]+[\r\n]") then
		echoed = true
		break
	end
end

if not ok(echoed, "the guest received bytes written to its serial") then
	diag("sent " .. SENT .. " repeatedly; guest transcript follows")
	diag(seen)
	cleanup(pid)
	os.exit(1)
end

-- and they must be the bytes sent.
--
-- Checked as "what arrived contains what was sent", not the reverse. A
-- stray NUL turns up on this wire now and then -- a line-condition
-- artifact, seen as got:hello\000 -- and asserting that the arrival is
-- a substring of SENT fails on any extra byte, which made this flake
-- about one run in four. Since SENT is written repeatedly, the useful
-- question is whether it ever came through intact.
local heard = {}

for line in seen:gmatch("SERIALRX got:([^\r\n]*)") do
	heard[#heard + 1] = line
end

local joined = table.concat(heard):gsub("%z", "")

if not ok(joined:find(SENT, 1, true) ~= nil,
    "and they were the bytes sent: heard " .. oneline(joined)) then
	diag(seen)
end

cleanup(pid)
os.exit(failed > 0 and 1 or 0)
