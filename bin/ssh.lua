-- ssh: a shell, or one command, on another machine.
--
--	ssh 10.0.2.2                        a login shell
--	ssh 10.0.2.2 uname -a               one command
--	ssh -p 2200 -i /tmp/id_ed25519 me@10.0.2.2 ls /

-- With no command it asks for a pty and a shell, which means waiting on
-- the wire and the keyboard at once: a thread per source feeding one
-- channel, as task/sshd.lua does for the other direction. Only the main
-- thread touches the protocol, so packets cannot interleave.

-- The protocol is lib/ssh, sans-io, riding the tcp capability the shell
-- lent this program: a shell given no network hands out none.

local unistd = require("posix.unistd")
local thread = require("los.thread")
local prog = require("prog")
local client = require("ssh.client")
local keys = require("ssh.keys")
local ed25519 = require("crypto.ed25519")

local function die(s)
	unistd.write(2, "ssh: " .. s .. "\n")
	os.exit(1)
end

local function usage()
	unistd.write(2, "usage: ssh [-p port] [-i key] [-k file] " ..
	    "[user@]host command...\n")
	os.exit(2)
end

local port, keyfile, hostsfile = 22, nil, "/etc/ssh/known_hosts"
local i = 1

while arg[i] and arg[i]:sub(1, 1) == "-" and #arg[i] > 1 do
	local o = arg[i]

	i = i + 1
	if o == "-p" then
		port = tonumber(arg[i]) or usage()
	elseif o == "-i" then
		keyfile = arg[i]
	elseif o == "-k" then
		hostsfile = arg[i]
	else
		usage()
	end
	i = i + 1
end

local target = arg[i]

if not target then
	usage()
end
i = i + 1

local command = table.concat(arg, " ", i)

if command == "" then
	command = nil
end

local user, host = target:match("^(.-)@(.+)$")

if not user then
	user, host = "anyone", target
end

local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

if not a then
	die(host .. ": a dotted quad, please -- no resolver here yet")
end

-- ---- what the program was lent ----

local net = prog.ctx and prog.ctx.net

if not net then
	die("no network capability")
end

local rand = prog.rand()

if not rand then
	die("no entropy: this shell was given no seed")
end

local N = prog.ns()

local function slurp(path)
	local fd = N and N:open(path, "r")

	if not fd then
		return nil
	end

	local s = fd:read("a")

	fd:close()
	return s
end

-- The key to authenticate with. A fresh one where none was named: our
-- own sshd accepts any key, so `ssh host cmd` works with no setup, and
-- a server that checks will refuse it and say so.
local seed, pk

if keyfile then
	local text = slurp(keyfile) or die(keyfile .. ": cannot read")
	local err

	seed, err = keys.parse_private(text)
	if not seed then
		die(keyfile .. ": " .. tostring(err))
	end
	pk = ed25519.publickey(seed)
else
	seed = rand(32)
	pk = ed25519.publickey(seed)
end

-- ---- the transport ----

local connid = net.dial(tonumber(a), tonumber(b), tonumber(c),
    tonumber(d), port)

if not connid then
	die(host .. ":" .. port .. ": cannot connect")
end

local inbuf, closed = "", false
local netchan = thread.chancreate(4)
local keychan = command and nil or thread.chancreate(4)

-- One thread per source, because both of them answer on a reply port of
-- their own and neither can be waited on directly. Whichever speaks
-- first wakes the reader below.
thread.spawn(function()
	while not closed do
		local data = net.recv(connid, 4096)

		if data == nil or data == false then
			netchan:close()
			return
		end
		netchan:send(data)
	end
end)

-- Keystrokes, where there is a shell to type at. The terminal is raw
-- for the whole session: the far end has the line editor, and echoing
-- here as well would double every character.
local tty = keychan and prog.tty()

if keychan and not tty then
	die("no terminal: use the command form")
end
if keychan then
	tty.rawon()
	thread.spawn(function()
		while not closed do
			local k = tty.getch()

			if k == nil then
				keychan:close()
				return
			end
			if #k > 0 then
				keychan:send(k)
			end
		end
	end)
end

-- Set once the shell channel is open: a keystroke before that has
-- nowhere to go, and the protocol is mid-handshake.
local sendkey = nil

-- Wait for either source. Keystrokes go out from here rather than from
-- their own thread, so that every packet is written by this one.
local function pump()
	local cases = { { c = netchan, op = "recv" } }

	if keychan then
		cases[2] = { c = keychan, op = "recv" }
	end

	local i, v = thread.alt(cases)

	if i == 1 then
		if v == nil then
			closed = true
		else
			inbuf = inbuf .. v
		end
	elseif v ~= nil and sendkey then
		sendkey(v)
	end
end

local conn = {
	rand = rand,

	read = function(n)
		while #inbuf < n do
			if closed then
				return nil, "connection closed"
			end
			pump()
		end

		local s = inbuf:sub(1, n)

		inbuf = inbuf:sub(n + 1)
		return s
	end,

	readline = function()
		while true do
			local at = inbuf:find("\n", 1, true)

			if at then
				local line = inbuf:sub(1, at - 1)

				inbuf = inbuf:sub(at + 1)
				return line
			end
			if closed then
				return nil, "connection closed"
			end
			pump()
		end
	end,

	write = function(s)
		return net.send(connid, s)
	end,
}

-- ---- the session ----

local C = client.new(conn)

-- What we do about the host key. known_hosts if there is one, and
-- otherwise trust on first use with the fingerprint said out loud --
-- the same stance as this system's sshd, which generates a host key per
-- boot. A key that is known and differs is refused, always.
C.verify_host = function(hk)
	local known = slurp(hostsfile)
	local fp = keys.fingerprint(keys.blob(hk))
	local verdict = known and keys.check_known_hosts(known, host, hk) or
	    "unknown"

	if verdict == "changed" then
		return nil, "host key for " .. host .. " has changed: " .. fp
	end
	if verdict == "unknown" then
		unistd.write(2, ("ssh: %s is unknown, trusting %s\n")
		    :format(host, fp))
	end
	return true
end

local ok, err = C:banner()

if not ok then
	die(tostring(err))
end

ok, err = C:kex()
if not ok then
	die(tostring(err))
end

ok, err = C:service("ssh-userauth")
if not ok then
	die(tostring(err))
end

ok, err = C:auth_publickey(user, seed, pk)
if not ok then
	die(tostring(err))
end

local ch

ch, err = C:session()
if not ch then
	die(tostring(err))
end

if command then
	ok, err = C:exec(ch, command)
else
	local cols, rows = tty.size()

	-- ansi, not xterm: eight colors, bold and reverse, and cursor
	-- addressing are what lib/fbcons.lua renders. Claiming xterm
	-- promises an alternate screen and 256 colors it drops, and a
	-- full-screen program would leave its wreckage on the shell.
	ok, err = C:pty(ch, cols or 80, rows or 24,
	    os.getenv("TERM") or "ansi")
	if ok then
		ok, err = C:shell(ch)
	end
	-- Only now: a keystroke before this has no channel to ride.
	sendkey = function(k) return C:data(ch, k) end
end
if not ok then
	die(tostring(err))
end

local status

status, err = C:pump(ch, function(data, which)
	unistd.write(which == "stderr" and 2 or 1, data)
end)

closed = true
if tty then
	tty.rawoff()
end
C:disconnect_now("done")
net.close(connid)

if not status then
	die(tostring(err))
end
os.exit(status)
