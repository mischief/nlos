#!/usr/bin/env lua5.4
-- sshclienttest.lua IMG PAYLOAD -- drive lib/ssh/client.lua against a
-- real OpenSSH server.
--
--	lua5.4 tools/sshclienttest.lua build/luaos.img \
--	    test/boot/net_sshclient.lua

-- The server is the point: a second implementation agreeing about the
-- exchange, the signature and the channel, rather than our own halves
-- agreeing with each other. It gets a port, a host key and an
-- authorized key of its own, and touches nothing of this machine's.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/?.lua;" .. scriptdir .. "/../test/?.lua;" ..
    package.path

local nap = require("nap")
local img, payload = arg[1], arg[2]
local tmp = os.getenv("TMPDIR") or "/tmp"
local dir = ("%s/luaos-sshtest-%d"):format(tmp, os.time())

local function run(cmd)
	local p = io.popen(cmd .. " 2>&1")
	local out = p:read("a")
	local ok = p:close()

	return ok, out
end

local function slurp(path)
	local f = io.open(path, "rb")

	if not f then return nil end

	local s = f:read("a")

	f:close()
	return s
end

local function bail(why)
	print("1..0 # SKIP " .. why)
	os.exit(0)
end

-- A port nobody else has. Asking the kernel for one and closing it
-- races, so this is the pid, which is unique among what is running.
local PORT = 20000 + (os.time() % 10000)
local USER = os.getenv("USER") or os.getenv("LOGNAME")

if not USER then
	bail("no USER in the environment to authenticate as")
end

run(("mkdir -p %q"):format(dir))

local ok = run(("ssh-keygen -q -t ed25519 -N '' -f %q/host"):format(dir))

if not ok then
	bail("ssh-keygen would not make a host key")
end
run(("ssh-keygen -q -t ed25519 -N '' -f %q/user"):format(dir))

local key = slurp(dir .. "/user")
local pub = slurp(dir .. "/user.pub")

if not key or not pub then
	bail("no keys were generated")
end

-- authorized_keys and a config of its own: nothing here reads or writes
-- anything belonging to the machine this runs on.
local f = assert(io.open(dir .. "/authorized", "w"))

f:write(pub)
f:close()
run(("chmod 600 %q/authorized"):format(dir))

f = assert(io.open(dir .. "/sshd_config", "w"))
f:write(([[
Port %d
ListenAddress 127.0.0.1
HostKey %s/host
AuthorizedKeysFile %s/authorized
StrictModes no
UsePAM no
PidFile none
PasswordAuthentication no
LogLevel ERROR
]]):format(PORT, dir, dir))
f:close()

-- The payload, with the key and the port written into it.
local src = slurp(payload)

if not src then
	bail("cannot read " .. tostring(payload))
end
src = src:gsub("@@KEY@@", (key:gsub("%%", "%%%%")))
src = src:gsub("@@PORT@@", tostring(PORT))
src = src:gsub("@@USER@@", USER)

local guestsrc = dir .. "/payload.lua"

f = assert(io.open(guestsrc, "w"))
f:write(src)
f:close()

-- sshd in the background, and killed by pid: a pattern match over the
-- process table would find somebody's real one.
local sshd = "/usr/sbin/sshd"

if not slurp(sshd) then
	sshd = "/usr/bin/sshd"
end
if not slurp(sshd) then
	bail("no sshd on this machine")
end

local pidf = dir .. "/sshd.pid"

os.execute(("%s -D -e -f %q/sshd_config >%q/sshd.log 2>&1 & echo $! > %q")
    :format(sshd, dir, dir, pidf))

local function stop()
	local pid = slurp(pidf)

	if pid then
		os.execute(("kill %d 2>/dev/null"):format(tonumber(pid) or 0))
	end
	os.execute(("rm -rf %q"):format(dir))
end

-- It is listening or it is not: a fixed wait is what tells a slow start
-- from a refusal to start at all.
nap(1)

local up = run(("%s -q -o ConnectTimeout=2 -o StrictHostKeyChecking=no " ..
    "-o UserKnownHostsFile=/dev/null -o BatchMode=yes -i %q/user " ..
    "-p %d %s@127.0.0.1 true"):format("ssh", dir, PORT, USER))

if not up then
	local why = slurp(dir .. "/sshd.log") or ""

	stop()
	bail("the test sshd would not serve this user: " ..
	    why:gsub("%s+", " "):sub(1, 120))
end

-- and now the guest, whose TAP is this test's TAP.
local boottest = scriptdir .. "/boottest.lua"
local cmd = ("NET=1 TIMEOUT=%s %s %q %q %q --services")
    :format(os.getenv("TIMEOUT") or "60", arg[-1] or "lua5.4", boottest,
    img, guestsrc)

local p = io.popen(cmd)
local tap = p:read("a")

p:close()
stop()
io.write(tap)
