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

-- /config is a flash partition of its own, so a key and the hosts it
-- trusts survive reflashing the filesystem.
local port, keyfile = 22, nil
local hostsfile = "/config/ssh/known_hosts"
local DEFAULTKEY = "/config/ssh/id_ed25519"
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

-- prog.net(), not ctx.net: the context carries the raw right, and the
-- wrapper is what has dial and recv on it.
local net = prog.net()

if not net then
	die("no network capability")
end

local rand = prog.rand()

if not rand then
	die("no entropy: this shell was given no seed")
end

local N = prog.ns()

local function slurp(path)
	if not N then
		return nil, "no namespace"
	end
	return N:readfile(path)
end

-- The key to authenticate with: the one named, else this machine's own,
-- which keygen writes. There is no generated fallback -- a key made on
-- the spot is in nobody's authorized_keys, so it can only produce
-- "server rejected our key" while looking like it tried.
local path = keyfile or DEFAULTKEY
local text, why = slurp(path)
local seed, pk

if text then
	local err

	seed, err = keys.parse_private(text)
	if not seed then
		die(path .. ": " .. tostring(err))
	end
	pk = ed25519.publickey(seed)
elseif keyfile then
	-- named, and not there: that is a mistake rather than a machine
	-- without a key.
	die(path .. ": " .. why)
end

-- ---- the transport ----

local connid = net.dial(tonumber(a), tonumber(b), tonumber(c),
    tonumber(d), port)

if not connid then
	die(host .. ":" .. port .. ": cannot connect")
end

local inbuf, closed = "", false

-- A command needs no scheduler: nothing but the wire has anything to
-- say, so the read is a plain call. A shell has to wait on the wire and
-- the keyboard at once, and channels and alt want a reactor turning --
-- which is what main() below starts.
local interactive = command == nil
local netchan = interactive and thread.chancreate(4) or nil
local keychan = interactive and thread.chancreate(4) or nil
local tty = interactive and prog.tty() or nil

if interactive and not tty then
	die("no terminal: give a command instead")
end

-- Set once the shell channel is open: a keystroke before that has
-- nowhere to go, and the protocol is mid-handshake.
local sendkey = nil
local termcols, termrows	-- measured before the readers start

-- Where keystrokes go while a prompt is up. Authentication happens with
-- the readers already running, so a password is typed at the same
-- keyboard the session will use, and only one of them may have it.
local keysink = nil

-- Wait for either source. Keystrokes go out from here rather than from
-- their own thread, so that every packet is written by one of them.
local function pump()
	if not interactive then
		local data = net.recv(connid, 4096)

		if data == nil or data == false then
			closed = true
		else
			inbuf = inbuf .. data
		end
		return
	end

	local i, v = thread.alt({ { c = netchan, op = "recv" },
	    { c = keychan, op = "recv" } })

	if i == 1 then
		if v == nil then
			closed = true
		else
			inbuf = inbuf .. v
		end
	elseif v ~= nil then
		if keysink then
			keysink(v)
		elseif sendkey then
			sendkey(v)
		end
	end
end

-- One typed line, for a prompt the server put up. The echo is ours to
-- do: the terminal is raw for the session, and a password prompt says
-- echo false precisely so the answer never reaches the screen.
local function promptline(text, echo)
	local acc = {}
	local done = false

	unistd.write(1, text)
	keysink = function(k)
		for i = 1, #k do
			local c = k:sub(i, i)

			if c == "\r" or c == "\n" then
				done = true
			elseif c == "\127" or c == "\8" then
				if #acc > 0 then
					acc[#acc] = nil
					if echo then
						unistd.write(1, "\8 \8")
					end
				end
			elseif c >= " " then
				acc[#acc + 1] = c
				if echo then
					unistd.write(1, c)
				end
			end
		end
	end

	while not done and not closed do
		pump()
	end
	keysink = nil
	unistd.write(1, "\r\n")
	return table.concat(acc)
end

-- One thread per source, started only where there is a reactor to run
-- them: both answer on a reply port of their own, so neither can be
-- waited on directly.
local function readers()
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

	-- getch with a timeout, so the end of the session reaches this
	-- thread: a bare one parks on a reply port only a keystroke
	-- answers, and nobody types at a session that has already failed,
	-- which leaves the reactor turning and the proc alive.
	thread.spawn(function()
		while not closed do
			local k = tty.getch(200)

			if k == nil then
				keychan:close()
				return
			end
			if #k > 0 then
				keychan:send(k)
			end
		end
		keychan:close()
	end)
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

local status = 0

-- Every failure is a returned string, never an exit. Exiting from
-- inside the reactor unwinds one coroutine and leaves the others
-- parked, which is a proc that never dies and a terminal left raw.
local function session()
	local ok, err = C:banner()

	if not ok then return "banner: " .. tostring(err) end

	ok, err = C:kex()
	if not ok then return tostring(err) end

	ok, err = C:service("ssh-userauth")
	if not ok then return tostring(err) end

	local keyerr

	if seed then
		ok, err = C:auth_publickey(user, seed, pk)
		keyerr = err
	else
		ok, err = false, DEFAULTKEY .. ": no key (keygen makes one)"
		keyerr = err
	end

	-- The key first, and the questions only where there is somebody to
	-- answer them: a command form has no terminal, and a prompt with
	-- nothing to type at it is a session that hangs rather than fails.
	if not ok and interactive then
		ok, err = C:auth_keyboard(user, function(name, instr, prompts)
			local out = {}

			if name ~= "" then unistd.write(1, name .. "\r\n") end
			if instr ~= "" then unistd.write(1, instr .. "\r\n") end
			for i, p in ipairs(prompts) do
				out[i] = promptline(p.text, p.echo)
			end
			return out
		end)
		if not ok then
			err = tostring(keyerr) .. "; " .. tostring(err)
		end
	end
	if not ok then return tostring(err) end

	local ch

	ch, err = C:session()
	if not ch then return tostring(err) end

	if command then
		ok, err = C:exec(ch, command)
	else
		-- ansi, not xterm: eight colors, bold and reverse, and
		-- cursor addressing are what lib/fbcons.lua renders.
		-- xterm would promise an alternate screen and 256 colors
		-- it drops, and a full-screen program would leave its
		-- wreckage behind on the shell.
		ok, err = C:pty(ch, termcols or 80, termrows or 24,
		    os.getenv("TERM") or "ansi")
		if ok then
			ok, err = C:shell(ch)
		end
		-- Only now: a keystroke before this has no channel to ride.
		sendkey = function(k) return C:data(ch, k) end
	end
	if not ok then return tostring(err) end

	status, err = C:pump(ch, function(data, which)
		unistd.write(which == "stderr" and 2 or 1, data)
	end)
	if not status then return tostring(err) end
	return nil
end

-- Whatever happened, the connection goes and `closed` is set: that is
-- what ends both readers, and what lets thread.run() return so this
-- proc can exit at all.
local function finish(why)
	closed = true
	pcall(function() C:disconnect_now("done") end)
	net.close(connid)
	if tty then
		tty.rawoff()
	end
	return why
end

-- A shell needs the reactor its two readers run under; a command is
-- plain calls and must not start one, since a session that already has
-- a reactor turning cannot nest a second.
local why

if interactive then
	-- Measured here, before the keystroke reader exists: asking a
	-- terminal its size is a query whose answer arrives as input, and
	-- two readers would race for it. Raw mode has to be on for the
	-- answer to come back unedited.
	tty.rawon()
	termcols, termrows = tty.detectsize()

	thread.spawn(function()
		readers()
		why = finish(session())
	end)
	thread.run()
else
	why = finish(session())
end

if why then
	die(why)
end
os.exit(status)
