-- sshd: a real SSH server, putting you at the same lua console the
-- serial port does.
--
-- 	ssh -p 2222 -o StrictHostKeyChecking=no anyone@<guest>
--
-- ---- what a visitor gets ----
--
-- exactly what svc/webterm.lua gives a browser, for the same reason and
-- by the same route: an unprivileged dos(1) proc of its own, holding one
-- right -- the send end of a console port this proc receives on. dos
-- does not know what its console IS. it writes {op="write", data=} and
-- asks {op="readline", reply=} against a port right, and lib/cons.lua
-- answers exactly that for com1. so an ssh session is a third console
-- implementation beside cons and webterm, and the shell needed no
-- changes at all to be served over it.
--
-- deliberately NOT handed to a session: the esp right, tcp, or any other
-- proc's port. the namespace is a private mem tree, so writes are
-- scratch that die with the connection.
--
-- ---- one scheduler, not three ----
--
-- lib/ssh/* is sans-io: every layer takes the transport as read/write
-- closures and its entropy as a rand closure, and knows nothing about
-- sockets, ports or procs. That is what lets the same protocol code run
-- here and on a posix host. But it means the protocol is written as
-- blocking code, and this proc must wait on two things at once: bytes
-- from the tcp task, and console messages from the shell proc.
--
-- The first version of this file drove that with a hand-rolled event
-- loop around a bare coroutine. It was wrong in a way worth recording,
-- because nothing about it looked wrong.
--
-- The kernel preempts a proc every few thousand instructions
-- (preempt_hook, src/kernel.c), and lua_yield from that hook yields the
-- INNERMOST coroutine -- the protocol's. So "resume returned" meant
-- either "it wants bytes" or "it was interrupted halfway through a
-- scalar multiplication", with no way to tell, and that loop waited for
-- I/O on both. The handshake then advanced one slice per arriving packet
-- or keystroke: 52 seconds of wall clock for 600ms of arithmetic, on an
-- idle machine, with every packet in order.
--
-- lib/thread already solves this, so this file now just uses it.
-- thread._park is what marks a coroutine as waiting, so thread.run()
-- treats a yield it did not expect as "still runnable, resume it" --
-- exactly right for a preemption, and needing no reasoning from us. The
-- ambiguity stops existing rather than being handled.
--
-- So: two threads, one channel, no bespoke loop.
--
--   reader    asks the tcp task for bytes and pushes them into `inchan`.
--   protocol  runs the SSH server. Its read() alt()s over inchan and the
--             console port, so waiting for the network and waiting for
--             the shell are the same wait.
--
-- The one invariant left is now structural rather than promised: the
-- protocol thread is the ONLY thread that touches `srv`. Sends therefore
-- cannot interleave and the packet sequence numbers cannot
-- desynchronise, with no lock to remember to take.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local dev = require("dev")
local drbg = require("crypto.drbg")
local server = require("ssh.server")
local ed25519 = require("crypto.ed25519")
local keys = require("ssh.keys")

local a = ...

-- args.trace = true logs every packet's message number in both
-- directions. It found both of this file's bugs, so it stays.
local TRACE = a.args and a.args.trace

local consport = sys.newport()

local NET = a.tcp.__right
local PORT = (a.args and a.args.port) or 2222
local BANNER = (a.args and a.args.banner) or
    "lua-os -- an experimental os, and this is a shell inside it.\n" ..
    "type 'help' for commands.\n\n"

-- ---- entropy ----
--
-- a.seed is the machine's entropy, drawn by init from los.platform.rng
-- and handed over as data. No seed means no sshd: there is nothing safe
-- to do instead.
local rng = drbg.new(a.seed)

-- The host key is generated here, in memory, every boot. That is a
-- prototype's answer and it is visible as one: a client reports a
-- changed host key after a reboot. Persisting it means either a file on
-- the ESP -- which would mean handing this proc the esp right that
-- webterm deliberately does without -- or a key baked into the image,
-- which is worse.
local hostseed = rng.bytes(32)
local hostpub = ed25519.publickey(hostseed)

-- ---- talking to the tcp task ----
--
-- thread.replyport() is per-thread and cached, which is exactly what is
-- wanted here: the reader thread and the protocol thread each get their
-- own, so a reply to one can never be delivered to the other. Sharing
-- one port between them is the cross-delivery bug lib/caps.lua's header
-- warns about, and it is not theoretical -- an earlier version of this
-- file had a flush stealing the network data and leaving the send's
-- reply to be mistaken for it.
local function netreq(extra)
	local rp = thread.replyport()

	extra.reply = { __right = rp }
	sys.send(NET, extra)
	return thread.recv(rp)
end

-- What a session's namespace contains. A private mem tree, so writes are
-- scratch that die with the connection, and /bin is COPIED in the same
-- way svc/webterm.lua copies it -- for the same reason and with the same
-- reservation. The honest fix for both is a read-only ESP server mounted
-- at /lib and /bin, shared by every session rather than copied into each;
-- see the note at the top of lib/webterm.lua.
local nsdesc
do
	local N = ns.current()

	local function slurp(path)
		local src = N and N:readfile(path)

		return src or ("-- missing: " .. path .. "\n")
	end

	local site = {
		["README"] = "lua-os, over ssh. this shell is a proc of its " ..
		    "own,\nholding one right: the console you are typing " ..
		    "into.\n",
		["bin"] = {
			["ls.lua"] = slurp("/bin/ls.lua"),
			["cat.lua"] = slurp("/bin/cat.lua"),
			["seq.lua"] = slurp("/bin/seq.lua"),
		},
		["tmp"] = {},
	}
	local V = ns.new()

	assert(V:mount("/", dev.mem(site), "mem", { tree = site }))
	nsdesc = V:describe()
end

-- The shell proc. A plain string because rights arrive at handle numbers
-- it cannot know until the message lands. Same shape as webterm's
-- VISITOR, and coro=true for the same reason: a session is ONE proc
-- however many programs it runs, so MAXPROCS stops bounding how many
-- sessions there can be.
local SHELL = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local ns = require("ns")
	local dos = require("dos")

	local m = thread.recv(sys.SELF)
	local cons = m.cons.__right
	local N, err = ns.restore(m.nsdesc)

	if not N then
		sys.send(cons, { op = "write",
		    data = "namespace: " .. tostring(err) .. "\n" })
		return
	end
	dos.start({ ns = N, cons = cons, coro = true }, m.banner)
]]

-- ---- one connection ----

local function session(connid)
	local inchan = thread.chancreate(4)
	local inbuf, inclosed = "", false
	local done = false

	local srv			-- set below; read() closes over it
	local chan = nil		-- the session channel, once open
	local toshell = {}		-- lines typed by the client
	local waiting = nil		-- a readline the shell is parked on

	-- Answer a parked readline as soon as there is a line for it.
	local function feed_shell()
		if waiting and #toshell > 0 then
			sys.send(waiting, table.remove(toshell, 1))
			waiting = nil
		end
	end

	-- A console message from the shell proc. Reached only from the
	-- protocol thread, from inside read() -- which is between packets,
	-- never during one, so writing here cannot interleave with a send
	-- in progress.
	local function from_shell(m)
		if type(m) ~= "table" then
			return
		end
		if m.op == "write" then
			if chan then
				srv:data(chan,
				    (tostring(m.data):gsub("\n", "\r\n")))
			end
		elseif m.op == "readline" then
			if m.prompt and chan then
				srv:data(chan, tostring(m.prompt))
			end
			waiting = m.reply and m.reply.__right
			feed_shell()
		end
	end

	-- Wait for whichever speaks first. The only place the protocol
	-- thread blocks, and it blocks on both things at once.
	local function pump()
		local i, v = thread.alt({ { c = inchan, op = "recv" },
		    { port = consport } })

		if i == 1 then
			if v == nil then
				inclosed = true
			else
				inbuf = inbuf .. v
			end
		else
			from_shell(v)
		end
	end

	local conn = {
		rand = rng.bytes,

		trace = TRACE and function(dir, t, n)
			print(("sshd: %s msg %s len %d"):format(dir,
			    tostring(t), n))
		end or nil,

		read = function(n)
			while #inbuf < n do
				if inclosed then return nil, "closed" end
				pump()
			end
			local s = inbuf:sub(1, n)

			inbuf = inbuf:sub(n + 1)
			return s
		end,

		readline = function()
			while true do
				local i = inbuf:find("\n", 1, true)

				if i then
					local line = inbuf:sub(1, i - 1)

					inbuf = inbuf:sub(i + 1)
					return line
				end
				if inclosed then return nil, "closed" end
				pump()
			end
		end,

		-- Blocking, and that is fine: only this thread writes, so
		-- the order packets are built in is the order they leave
		-- in, which is what the sequence numbers require.
		write = function(s)
			return netreq({ op = "send", connid = connid,
			    data = s })
		end,
	}

	srv = server.new(conn, {
		hostkey_seed = hostseed,
		hostkey_pub = hostpub,
		-- Any key, for now. This is the line that becomes a real
		-- authorized_keys check, and it is deliberately one line so
		-- that it is obvious it has not been written yet.
		authorized = function(user, pk)
			print(("sshd: %s offered %s"):format(user,
			    keys.fingerprint(keys.blob(pk))))
			return true
		end,
	})

	-- the reader: the only thread that asks the tcp task for bytes.
	thread.spawn(function()
		while not done do
			local data = netreq({ op = "recv", connid = connid,
			    maxlen = 4096 })

			if data == nil or data == false then
				inchan:close()
				return
			end
			inchan:send(data)
		end
	end)

	local shellpid
	local noinput = false		-- client sent EOF; see the events loop

	local ok, err = srv:handshake()

	if not ok then
		print("sshd: handshake: " .. tostring(err))
	else
		print("sshd: session for " .. tostring(srv.user))

		for ev in srv:events() do
			if ev.type == "shell" then
				chan = ev.chan

				local pid, h = sys.spawn(SHELL,
				    { name = "ssh-session" })

				if not pid then
					srv:extended(ev.chan,
					    "cannot spawn a shell\r\n")
					srv:exit(ev.chan, 1)
					srv:close(ev.chan)
					break
				end
				shellpid = pid
				sys.send(h, {
					cons = { __right =
					    sys.sendright(consport) },
					nsdesc = nsdesc,
					banner = BANNER,
				})

			elseif ev.type == "exec" then
				-- Answered, not honoured: this serves one
				-- thing, and pretending otherwise would fail
				-- later and less clearly.
				chan = ev.chan
				srv:extended(ev.chan,
				    "this sshd serves a shell only\r\n")
				srv:exit(ev.chan, 1)
				srv:close(ev.chan)
				break

			elseif ev.type == "data" then
				-- ^D ends the session. There is no tty in
				-- this system to turn it into an EOF, so the
				-- byte arrives as data and this is the only
				-- layer that can mean anything by it --
				-- without which the way out is ssh's ~.
				-- escape.
				if ev.data:find("\4", 1, true) then
					srv:data(ev.chan, "\r\n")
					srv:exit(ev.chan, 0)
					srv:close(ev.chan)
					break
				end

				-- A terminal sends CR for the return key and
				-- expects an echo; dos wants lines. Both are
				-- this layer's job, because there is no tty
				-- anywhere in this system to do either.
				local s = ev.data:gsub("\r", "\n")

				srv:data(ev.chan, (s:gsub("\n", "\r\n")))
				for line in s:gmatch("[^\n]*\n") do
					toshell[#toshell + 1] = line:sub(1, -2)
				end
				feed_shell()

			elseif ev.type == "eof" then
				-- The client will send no more input. That
				-- is not a hangup and must not end the
				-- session: output the shell has not produced
				-- yet still has to get out. Only "close"
				-- ends it.
				noinput = true

			elseif ev.type == "close" then
				break
			end
		end
		if srv.error then
			print("sshd: " .. tostring(srv.error))
		end
	end

	done = true
	if shellpid then
		-- the shell is parked on a console nobody will answer
		-- again; dropping our end is what tells it so.
		sys.close(consport)
		consport = sys.newport()
	end

	-- Fire and forget, and this is NOT a style choice: tcp.lua's
	-- "close" handler never replies (see its own header). Sending it
	-- through netreq() parks this thread forever on an answer that is
	-- never coming -- so the session never returns, main() never gets
	-- back to accept(), and every connection after the first is
	-- greeted with silence. lib/caps.lua warns about exactly this and
	-- it still took a second connection to notice.
	sys.send(NET, { op = "close", connid = connid })
end

-- ---- accept ----

local function main()
	print(("sshd: host key %s"):format(keys.fingerprint(keys.blob(hostpub))))

	local listener

	for _ = 1, 20 do
		listener = netreq({ op = "listen", port = PORT })
		if listener then
			break
		end
		thread.sleep(50)
	end

	if not listener then
		print("sshd: cannot listen on " .. PORT)
		return
	end

	print(("sshd: listening on tcp/%d t=%dms"):format(PORT,
	    sys.uptime_ms()))

	while true do
		local conn = netreq({ op = "accept", connid = listener })

		if conn then
			-- one connection at a time, and a bad one must not
			-- take the listener down with it.
			local ok, err = pcall(session, conn)

			if not ok then
				print("sshd: " .. tostring(err))
				sys.send(NET, { op = "close", connid = conn })
			end
		end
	end
end

thread.spawn(main)
thread.run()
