-- the embedded boot payload, driven from the host as a user would.
--
-- The payload src/platform/microvm/main.c falls back to when no fw_cfg
-- one was injected is a console repl (boot/microvm.lua). That is the
-- only thing that can run under OpenBSD vmd, whose fw_cfg cannot be
-- handed a host file, so it is worth more than a smoke test: this types
-- at it and reads what comes back.
--
-- Which means the serial has to work in both directions, so this is a
-- socket like test/microvm_serial.lua rather than the write-only file
-- scripts/boottest-microvm.lua uses. It also means this test covers the
-- console input path itself -- pump_keyboard, efi_shim's ReadKeyStroke,
-- and the claim that hands com1 to the console instead of the wire.
--
-- No fw_cfg payload is passed. That absence is the point.

local hostutil = require("hostutil")

local elf = arg[1]

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

print("1..5")

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

local pid = hostutil.spawn({
	"qemu-system-x86_64",
	"-M", "microvm,pit=off,pic=off,rtc=off,ioapic2=off,acpi=on",
	"-enable-kvm", "-cpu", "host", "-m", "256",
	"-kernel", elf,
	"-nodefaults", "-no-user-config", "-no-reboot", "-display", "none",
	"-chardev", "socket,id=s0,path=" .. sock .. ",server=on,wait=off",
	"-serial", "chardev:s0",
})

if not ok(pid ~= nil, "qemu started") then
	cleanup(nil)
	os.exit(1)
end

local fd
local deadline = os.time() + 15

while os.time() < deadline do
	fd = hostutil.connect_unix(sock)
	if fd then
		break
	end
	hostutil.sleep(0.05)
end

if not ok(fd ~= nil, "connected to the guest's serial") then
	cleanup(pid)
	os.exit(1)
end

local seen = ""

-- read until `pat` shows up or time runs out, accumulating everything.
local function await(pat, secs)
	local stop = os.time() + secs

	while os.time() < stop do
		if seen:match(pat) then
			return true
		end

		local chunk = hostutil.recv(fd, 4096, 0.5)

		if chunk and #chunk > 0 then
			seen = seen .. chunk
		end
	end
	return seen:match(pat) ~= nil
end

-- Nothing printed before the client attached survives -- a socket
-- server drops output with nobody connected -- and this guest boots in
-- about a tenth of a second, so the banner and the first prompt are
-- long gone by the time we are here. Poke it with an empty line and
-- wait for the prompt that answers: that is also a stronger statement
-- than the banner would be, since it means the console read our bytes.
local function poke_for_prompt(secs)
	local stop = os.time() + secs

	while os.time() < stop do
		hostutil.send(fd, "\n")

		local chunk = hostutil.recv(fd, 4096, 0.5)

		if chunk and #chunk > 0 then
			seen = seen .. chunk
		end
		if seen:match("> ") then
			return true
		end
	end
	return false
end

if not ok(poke_for_prompt(30), "the embedded payload reached its prompt") then
	diag("guest transcript follows")
	diag(seen)
	cleanup(pid)
	os.exit(1)
end

-- ps is the real question: a proc table means the console read a line,
-- the repl evaluated it, and the answer came back out the same port.
-- The cons task is always pid 0, so its row is what to look for.
seen = ""
hostutil.send(fd, "ps\n")

if not ok(await("cons", 30), "typing ps at it lists the procs") then
	diag("guest transcript follows")
	diag(seen)
	cleanup(pid)
	os.exit(1)
end

diag("guest answered:")
diag(seen)

-- and the machine's own power words are bound. Typed BARE on purpose:
-- reboot() would restart the guest and end the test, while the word by
-- itself only explains itself -- which is the property lib/ps.lua goes
-- out of its way to keep, and therefore worth testing.
seen = ""
hostutil.send(fd, "reboot\n")

if not ok(await("type reboot%(%)", 30), "reboot is bound at the prompt") then
	diag("guest transcript follows")
	diag(seen)
	cleanup(pid)
	os.exit(1)
end

cleanup(pid)
os.exit(failed > 0 and 1 or 0)
