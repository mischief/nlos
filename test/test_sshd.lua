#!/usr/bin/env lua5.4
-- sshd test, host-driven: boots lua-os with a payload that starts
-- task/sshd.lua on guest tcp/2222, forwards that to a host port, and
-- drives it with a real ssh client. emits TAP.
--
-- this is the only test that exercises the tcp path end to end --
-- listen, accept, recv, send, close -- against a client that isn't
-- itself. the guest cannot test this alone: qemu's usermode network
-- does not hairpin, so a guest dialing its own address just times out.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. package.path
-- tools/ too: fwcfg.lua is shared with the boot harnesses.
local toolsdir = scriptdir .. "/../tools"
package.path = toolsdir .. "/?.lua;" .. package.path
local qemuarch = require("qemuarch")
local hostutil = qemuarch.hostutil

local img = arg[1]
local payload = arg[2]

local count, failed = 0, 0

-- a TAP description is one line by construction, so guest text quoted
-- into one has to be escaped rather than passed through. the python
-- these tests came from got that free from %r; without it a terminal
-- session's carriage returns reach the harness raw, and since meson
-- breaks lines on \r as well as \n every segment after the first
-- arrives unprefixed and fails the whole run on "Unknown TAP output"
-- -- even when every assertion passed.
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

-- the normalisation tools/boottest.lua applies to a serial log, for
-- the same reason: strip ansi and fold carriage returns into newlines
-- so that every line of a guest dump carries its own "# ".
local function diag(s)
	local t = tostring(s):gsub("\27%[[%d;=]*%a", ""):gsub("\r\n", "\n")

	t = t:gsub("\r", "\n")
	for line in (t .. "\n"):gmatch("([^\n]*)\n") do
		print("# " .. line)
	end
end

local function quote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function readfile(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local d = f:read("a")
	f:close()
	return d
end

local tmp = assert(io.popen("mktemp -d")):read("l")
local vars_path = tmp .. "/vars.fd"
local serial_log = tmp .. "/serial.log"

os.execute("cp " .. quote(qemuarch.FW_VARS) .. " " .. quote(vars_path))

local port = hostutil.free_port()

local argv = {}
local function extend(more)
	for _, v in ipairs(more) do
		argv[#argv + 1] = v
	end
end

extend(qemuarch.qemu())
extend(qemuarch.machine())
extend(qemuarch.rng())
extend({ "-display", "none", "-monitor", "none" })
extend({ "-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:" .. port .. "-:2222" })
extend({ "-device", "virtio-net-pci,netdev=n0" })
extend({ "-no-reboot", "-snapshot" })
extend({ "-serial", "file:" .. serial_log })
extend(qemuarch.wire())
extend(require("fwcfg").args(payload,
    { services = true, dir = tmp, tools = toolsdir }))
extend({ "-drive", "if=pflash,format=raw,readonly=on,file=" .. qemuarch.FW_CODE })
extend({ "-drive", "if=pflash,format=raw,file=" .. vars_path })
extend(qemuarch.disk(img))

local qemu_pid = hostutil.spawn(argv)
local reaped = false

local function cleanup()
	if not reaped then
		hostutil.kill(qemu_pid)
		hostutil.wait(qemu_pid)
	end
	if failed > 0 then
		local log = readfile(serial_log)
		if log then
			diag("guest serial log:")
			diag(log)
		end
	end
	os.execute("rm -rf " .. quote(tmp))
end

print("1..6")

local function main()
	-- the guest says this once sshd is listening, which is after dhcp
	-- has handed it a lease.
	local deadline = os.time() + 60
	local up = false

	while os.time() < deadline do
		local content = readfile(serial_log)

		if content and content:find("listening on tcp/2222", 1, true) then
			up = true
			break
		end
		if hostutil.poll(qemu_pid) ~= nil then
			reaped = true
			break
		end
		os.execute("sleep 0.5")
	end
	if not ok(up, "the guest sshd came up") then
		return 1
	end

	-- a key of our own: this sshd accepts any, so what it proves is
	-- that the exchange and the signature agree, not who we are.
	os.execute(("ssh-keygen -q -t ed25519 -N %s -f %s/id 2>/dev/null")
	    :format(quote(""), quote(tmp)))

	local function ssh(input, command, secs)
		local cmd = ("printf %s | timeout %d ssh -T -p %d " ..
		    "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null " ..
		    "-o IdentitiesOnly=yes -i %s/id anyone@127.0.0.1 %s 2>&1")
		    :format(quote(input), secs or 60, port, quote(tmp),
		    command and quote(command) or "")
		local t0 = os.time()
		local p = io.popen(cmd)
		local out = p:read("a")
		local okrun, _, code = p:close()

		return out, code or 0, os.time() - t0
	end

	-- ---- a session that ends when the shell does ----
	--
	-- The whole point of the exercise: `exit` used to leave the client
	-- waiting on a channel nobody closed, so every login looked like a
	-- 60-second one.
	local out, code, secs = ssh("exit\n", nil, 60)

	ok(out:find("a shell inside it", 1, true) ~= nil,
	    "the shell greeted us: " .. oneline(out:sub(1, 48)))
	ok(secs < 30, "and the session ended promptly (" .. secs .. "s)")
	ok(code == 0, "with the status the shell exited on -> " .. tostring(code))

	-- ---- and the command form, which runs one line and reports it ----
	out, code = ssh("", "ls /", 60)
	ok(out:find("bin", 1, true) ~= nil and code == 0,
	    ("a command runs and exits 0 (%s): %s"):format(tostring(code),
	    oneline(out:sub(-60))))

	-- a program that is not there is the status a caller scripts on,
	-- which is the whole reason the exit is reported at all.
	out, code = ssh("", "nosuchprogram", 60)
	ok(code == 127, "a missing program exits 127 -> " .. tostring(code))

	return 0
end

local runok, runerr = pcall(main)
local rc = 0

if not runok then
	diag("exception: " .. tostring(runerr))
	rc = 1
else
	rc = runerr
end
if failed > 0 then
	rc = 1
end

cleanup()
os.exit(rc)
