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
-- ---- why this is an event loop and not straight-line code ----
--
-- lib/ssh/* is sans-io: every layer takes the transport as read/write
-- closures and its entropy as a rand closure, and knows nothing about
-- sockets, ports or procs. That is what lets the same protocol code run
-- here and on a posix host, and it is what makes this file small.
--
-- But it means the protocol is written as blocking code, and this proc
-- must wait on TWO things at once: bytes from the tcp task, and console
-- messages from the shell proc. So the protocol runs inside a coroutine
-- whose read() yields when it wants bytes it has not got, and this loop
-- alt()s over both ports and feeds it.
--
-- The invariant that makes that safe, and it is worth stating because
-- everything below depends on it: the protocol coroutine only ever
-- yields DELIBERATELY from inside read(), because write() never yields --
-- it appends to a queue this loop drains. So it is never parked halfway
-- through emitting a packet, and this loop may therefore call srv:data()
-- on its behalf while it is suspended without interleaving two packets
-- or desynchronising the sequence numbers.
--
-- ---- why the yield carries a reason ----
--
-- Because a deliberate yield is not the only way this coroutine stops.
-- The kernel preempts a proc every few thousand instructions
-- (preempt_hook, src/kernel.c) and that yields the INNERMOST coroutine
-- -- which is this one, not the proc's. So a resume() returning tells
-- you nothing on its own: the protocol may want bytes, or it may have
-- been interrupted halfway through a scalar multiplication.
--
-- Treating the second as the first is a trap with no visible symptom
-- and a spectacular cost. This loop used to do exactly that: it would
-- park in alt() after every preemption, so the handshake advanced by one
-- slice per console keystroke or network packet and took 52 SECONDS of
-- wall clock for 600ms of arithmetic. Nothing looked wrong -- the
-- machine was idle, the proc was alive, the packets were in order.
--
-- So read() yields the string "want", and only that reason makes this
-- loop wait for anything. Any other yield is the scheduler, and the
-- answer to the scheduler is to carry straight on.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local dev = require("dev")
local drbg = require("crypto.drbg")
local server = require("ssh.server")
local ed25519 = require("crypto.ed25519")
local keys = require("ssh.keys")

local a = ...

-- what conn.read yields when it genuinely wants more bytes, as opposed
-- to the kernel's preemption. see the header.
local WANT = "want"

-- args.trace = true logs every packet's message number in both
-- directions.
local TRACE = a.args and a.args.trace

-- TWO network ports, and the split is load-bearing.
--
-- netport carries replies to the ONE outstanding "recv" and nothing
-- else, because that is the reply this loop alt()s for. ctlport carries
-- every other request -- send, listen, accept, close -- which are
-- request/reply and wait for their own answer.
--
-- Sharing one port between them is the cross-delivery bug lib/caps.lua's
-- header warns about, and it is not theoretical: with a recv
-- outstanding, a flush's thread.recv() picks up the network data as if
-- it were the send's result, drops it, and leaves the send's actual
-- reply to be mistaken for network data by the next alt. The session
-- then stalls with both ends waiting, which is exactly how this
-- presented.
local netport = sys.newport()
local ctlport = sys.newport()
local consport = sys.newport()

local NET = a.tcp.__right
local PORT = (a.args and a.args.port) or 2222
local BANNER = (a.args and a.args.banner) or
    "lua-os -- an experimental os, and this is a shell inside it.\n" ..
    "type 'help' for commands.\n\n"

-- ---- entropy ----
--
-- a.seed is the machine's entropy, drawn by init from
-- los.platform.rng and handed over as data. No seed means no sshd:
-- there is nothing safe to do instead.
local rng = drbg.new(a.seed)

-- The host key is generated here, in memory, every boot. That is a
-- prototype's answer and it is visible as one: a client will report a
-- changed host key after a reboot. Persisting it means either a file on
-- the ESP -- which would mean handing this proc the esp right that
-- webterm deliberately does without -- or a build-time key baked into
-- the image, which is worse. Neither is worth it before the thing works.
local hostseed = rng.bytes(32)
local hostpub = ed25519.publickey(hostseed)

-- ---- tcp, with a port we can alt() on ----
--
-- lib/caps.lua's requester mints a fresh reply port per call, which is
-- right for request/reply but useless here: this loop has to wait on the
-- network AND the console at once, and alt() needs a port that outlives
-- the call.
local function netreq(extra)
	extra.reply = { __right = ctlport }
	sys.send(NET, extra)
	return thread.recv(ctlport)
end

local function netsend(connid, data)
	return netreq({ op = "send", connid = connid, data = data })
end

local nsdesc
do
	local site = {
		["README"] = "lua-os, over ssh. this shell is a proc of its " ..
		    "own,\nholding one right: the console you are typing " ..
		    "into.\n",
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
	-- Bytes from the network, and bytes bound for it. read() yields
	-- when the buffer is short; write() only ever appends, which is
	-- the invariant the header describes.
	local inbuf, inclosed = "", false
	local outq = {}

	local conn = {
		rand = rng.bytes,

		-- packet.lua calls this for every packet in either
		-- direction, when asked. The message NUMBER is what tells
		-- a stalled handshake apart from a slow one, and it is
		-- what found both bugs so far, so it stays.
		trace = TRACE and function(dir, t, n)
			print(("sshd: %s msg %s len %d"):format(dir,
			    tostring(t), n))
		end or nil,

		read = function(n)
			while #inbuf < n do
				if inclosed then return nil, "closed" end
				coroutine.yield(WANT)
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
				coroutine.yield(WANT)
			end
		end,

		write = function(s)
			outq[#outq + 1] = s
			return true
		end,
	}

	local srv = server.new(conn, {
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

	-- Shared with the loop below: the coroutine sets `chan` when the
	-- session gets a shell, and drains `toshell` / fills nothing else.
	local st = { chan = nil, done = false, shellpid = nil }
	local toshell = {}		-- lines typed by the client
	local waiting = nil		-- a readline reply the shell is parked on

	local co = coroutine.create(function()
		local ok, err = srv:handshake()

		if not ok then
			print("sshd: handshake: " .. tostring(err))
			st.done = true
			return
		end
		print("sshd: session for " .. tostring(srv.user))

		for ev in srv:events() do
			if ev.type == "shell" or ev.type == "exec" then
				st.chan = ev.chan
				-- exec is answered but not honoured: this
				-- serves one thing, the console, and
				-- pretending otherwise would fail later and
				-- less clearly.
				if ev.type == "exec" then
					srv:extended(ev.chan,
					    "this sshd serves a shell only\n")
					srv:exit(ev.chan, 1)
					srv:close(ev.chan)
					st.done = true
					break
				end

				local pid, h = sys.spawn(SHELL,
				    { name = "ssh-session" })

				if not pid then
					srv:extended(ev.chan,
					    "cannot spawn a shell\n")
					srv:exit(ev.chan, 1)
					srv:close(ev.chan)
					st.done = true
					break
				end
				st.shellpid = pid
				sys.send(h, {
					cons = { __right =
					    sys.sendright(consport) },
					nsdesc = nsdesc,
					banner = BANNER,
				})

			elseif ev.type == "data" then
				-- A terminal sends CR for the return key and
				-- expects an echo; dos wants lines. Both are
				-- this layer's job because there is no tty
				-- anywhere in this system to do it.
				local s = ev.data:gsub("\r", "\n")

				srv:data(ev.chan, (s:gsub("\n", "\r\n")))
				for line in s:gmatch("[^\n]*\n") do
					toshell[#toshell + 1] =
					    line:sub(1, -2)
				end

			elseif ev.type == "eof" or ev.type == "close" then
				st.done = true
				break
			end
		end
		st.done = true
	end)

	-- ---- the loop ----

	local pending_recv = false

	while not st.done do
		-- 1. let the protocol run as far as it can.
		local ok, why = coroutine.resume(co)

		if not ok then
			print("sshd: session error: " .. tostring(why))
			break
		end
		if coroutine.status(co) == "dead" then
			break
		end

		-- preempted mid-computation rather than waiting on us:
		-- hand the cpu straight back. Waiting here instead is the
		-- 52-second handshake described in the header.
		if why ~= WANT then
			goto continue
		end

		-- 2. hand the shell whatever it is waiting for. safe here
		-- and only here: the coroutine is parked in read().
		if waiting and #toshell > 0 then
			sys.send(waiting, table.remove(toshell, 1))
			waiting = nil
		end

		-- 3. flush anything the protocol produced.
		while #outq > 0 do
			local chunk = table.concat(outq)

			outq = {}
			if not netsend(connid, chunk) then
				st.done = true
				break
			end
		end
		if st.done then break end

		-- 4. wait for the network or the shell, whichever speaks
		-- first. this is the only place this proc blocks.
		if not pending_recv then
			sys.send(NET, { op = "recv", connid = connid,
			    maxlen = 4096, reply = { __right = netport } })
			pending_recv = true
		end

		local idx, val = thread.alt({ { port = netport },
		    { port = consport } })

		if idx == 1 then
			pending_recv = false
			if val == nil or val == false then
				inclosed = true
			else
				inbuf = inbuf .. val
			end
		else
			-- a console message from the shell proc.
			if val.op == "write" then
				if st.chan then
					srv:data(st.chan,
					    (tostring(val.data)
					        :gsub("\n", "\r\n")))
				end
			elseif val.op == "readline" then
				if val.prompt and st.chan then
					srv:data(st.chan, val.prompt)
				end
				waiting = val.reply and val.reply.__right
			end
		end

		::continue::
	end

	if st.shellpid then
		-- the shell is parked on a console nobody will answer again;
		-- dropping our end is what tells it so.
		sys.close(consport)
		consport = sys.newport()
	end
	netreq({ op = "close", connid = connid })
end

-- ---- accept ----

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

print(("sshd: listening on tcp/%d t=%dms"):format(PORT, sys.uptime_ms()))

while true do
	local conn = netreq({ op = "accept", connid = listener })

	if conn then
		-- one connection at a time, and a bad one must not take the
		-- listener down with it.
		local ok, err = pcall(session, conn)

		if not ok then
			print("sshd: " .. tostring(err))
			sys.send(NET, { op = "close", connid = conn })
		end
	end
end
