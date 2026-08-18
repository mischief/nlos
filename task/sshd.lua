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

local consport = sys.newport("sshd.consport")

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
	local rp, send = thread.replyport()

	extra.reply = { __right = send }
	sys.send(NET, extra)
	return thread.recv(rp)
end

-- What a session's namespace contains: a private mem tree for the root
-- and for /tmp, so writes are scratch that die with the connection, and
-- this machine's own /lib and /bin mounted as subtrees.
--
-- Mounted rather than copied. A session runs a shell, the shell loads
-- lib/dos.lua, dos loads lib/prog.lua, and a program loads whatever it
-- was written against -- so copying means keeping a list of modules by
-- hand and finding out it is short when a session dies at a require.
-- The subtree is a mount's root (lib/dev.lua's subtree, applied by
-- ns:mount), so a session sees /lib and /bin and not /etc.
--
-- What that is worth is tidiness, not confinement: the description
-- carries the right each mount was built from, so a session determined
-- to reach the rest of the server can. Attenuating that needs a proxy
-- proc between them.
local nsdesc
do
	local N = ns.current()
	local site = {
		["README"] = "lua-os, over ssh. this shell is a proc of its " ..
		    "own,\nholding one right: the console you are typing " ..
		    "into.\n",
		["tmp"] = {},
	}
	local V = ns.new()

	assert(V:mount("/", require("devtree").mem(site), "mem", { tree = site }))

	-- one subtree mount per mount this proc has at "/", in the order
	-- it has them: a union of an image under a filesystem must stay a
	-- union, or a session on a board whose flash shadows the image
	-- gets whichever half was listed first.
	for _, m in ipairs(N and N:describe() or {}) do
		if m.prefix == "/" and m.kind ~= "mem" then
			for _, dir in ipairs({ "/lib", "/bin" }) do
				local args = { root = dir }

				for k, v in pairs(m.args or {}) do
					if k ~= "root" then
						args[k] = v
					end
				end

				local build = ns.kinds[m.kind]
				local ok, b = false, nil

				if build then
					ok, b = pcall(build, args)
				end

				-- attached here rather than at first use: a
				-- backend with no such directory -- the esp32
				-- image has no /bin -- is left out, instead
				-- of raising inside a walk that the next
				-- mount in the union would have answered.
				if ok and pcall(require("devtree").subtree(b, dir).attach) then
					V:mount(dir, b, m.kind, args, "after")
				end
			end
		end
	end
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

	local m = thread.recv(sys.SELF)
	local cons = m.cons.__right
	local N, err = ns.restore(m.nsdesc)

	if not N then
		sys.send(cons, { op = "write",
		    data = "namespace: " .. tostring(err) .. "\n" })
		return
	end
	-- current first, then require: lib/dos.lua comes out of the
	-- session's own /lib. On a platform whose image stops at the
	-- filesystem it is not anywhere else.
	ns.setcurrent(N)

	local dos = require("dos")
	local sh = dos.start({ ns = N, cons = cons, coro = true }, m.banner)

	-- what the session exited with, so the client is told rather than
	-- left to time out. The console right is the only one this proc
	-- has, and the daemon is listening on it either way.
	sys.send(cons, { op = "exit", code = sh and sh.status or 0 })
]]

-- `ssh host 'command'`: the same namespace and the same launcher, one
-- line of it. dos.once drives its own reactor, so redirections, pipes
-- and argument splitting work here exactly as they do at the prompt.
local EXEC = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local ns = require("ns")

	local m = thread.recv(sys.SELF)
	local cons = m.cons.__right
	local N, err = ns.restore(m.nsdesc)

	if not N then
		sys.send(cons, { op = "write",
		    data = "namespace: " .. tostring(err) .. "\n" })
		sys.send(cons, { op = "exit", code = 1 })
		return
	end
	ns.setcurrent(N)

	local dos = require("dos")
	local sh = dos.new({ ns = N, cons = cons, coro = true })
	local st, why = dos.once(sh, m.command)

	if why then
		sys.send(cons, { op = "write",
		    data = tostring(why) .. "\n" })
	end
	sys.send(cons, { op = "exit", code = st or 0 })
]]

-- ---- one connection ----

local function session(connid)
	local inchan = thread.chancreate(4)
	local inbuf, inclosed = "", false
	local done = false

	local srv			-- set below; read() closes over it
	local chan = nil		-- the session channel, once open
	local toshell = {}		-- completed lines typed by the client
	local partial = ""		-- the line being typed, so far
	local waiting = nil		-- a readline the shell is parked on

	-- Answer a parked readline as soon as there is a line for it.
	local function feed_shell()
		if waiting and #toshell > 0 then
			sys.send(waiting, table.remove(toshell, 1))
			waiting = nil
		end
	end

	-- the raw side, for a full-screen program (vi) run over this session.
	-- in raw mode the line discipline is off: client bytes queue in rawin
	-- and go to getch one at a time, unedited and unechoed, and the
	-- program draws its own screen.
	local rawmode = false
	local execing = false		-- a command, not a shell: see from_shell
	local rawin = ""		-- keystrokes not yet handed to a getch
	local getwait = nil		-- reply port of a parked getch
	local gettimer = nil		-- its timeout, so a lone Esc resolves

	-- the client's terminal, from pty-req and kept current by
	-- window-change. A program that lays out columns asks the console
	-- for this (lib/caps.lua's size), and over ssh the client is the
	-- only thing that knows -- so an unanswered size is a program
	-- guessing 80 columns at a window that is not 80 wide.
	local ptycols, ptyrows = nil, nil

	-- answer a parked getch and drop its timeout timer.
	local function reply_getch(byte)
		if getwait then
			sys.send(getwait, byte)
			getwait = nil
		end
		if gettimer then
			sys.close(gettimer)
			gettimer = nil
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
				-- cooked writes get \n -> \r\n so a shell that prints
				-- lines lands right on a terminal; a raw-mode program
				-- places every byte itself, so leave those alone.
				local data = tostring(m.data)

				-- Not for a command's output: `ssh host cmd`
				-- is a pipe, and a caller reading it wants
				-- the bytes the program wrote. A shell is
				-- talking to a terminal and wants the
				-- carriage return, as a raw-mode program
				-- placing its own bytes does not.
				if not rawmode and not execing then
					data = data:gsub("\n", "\r\n")
				end
				srv:data(chan, data)
			end
		elseif m.op == "rawon" then
			rawmode = true
		elseif m.op == "rawoff" then
			rawmode = false
			rawin = ""
		elseif m.op == "getch" then
			local rp = m.reply and m.reply.__right

			-- a byte already queued answers at once; otherwise park the
			-- getch for the next keystroke or its timeout (see pump).
			if #rawin > 0 then
				local b = rawin:sub(1, 1)

				rawin = rawin:sub(2)
				if rp then
					sys.send(rp, b)
				end
			else
				getwait = rp
				gettimer = m.timeout and sys.timer(m.timeout) or nil
			end
		elseif m.op == "size" then
			-- Answered even when this session never asked for a
			-- pty: the reply is what a caller waits on, and a
			-- console that stays silent parks the program
			-- forever. nil cols is "I do not know", which is
			-- what lib/caps.lua documents and what a serial
			-- line says.
			local rp = m.reply and m.reply.__right

			if rp then
				sys.send(rp, { cols = ptycols, rows = ptyrows })
			end
		elseif m.op == "exit" then
			-- The program or the shell is done. Its status is
			-- what `ssh host cmd` reports to its caller, and a
			-- session that closes without one leaves the client
			-- guessing -- OpenSSH says "Exit status -1".
			if chan then
				srv:exit(chan, tonumber(m.code) or 0)
				srv:close(chan)
				chan = nil
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
	--
	-- Refreshed rather than frozen, unlike the other hoisted alt case
	-- tables: a session reset closes consport and makes a new one (see
	-- below), so a captured handle would go stale and pump would wait
	-- on a dead port.
	local pumpcases = { { c = inchan, op = "recv" }, { port = false } }

	local function pump()
		pumpcases[2].port = consport

		-- a getch waiting with a timeout waits on its timer too, so a
		-- lone Escape resolves instead of hanging until the next key.
		local cases = pumpcases

		if gettimer then
			cases = { pumpcases[1], pumpcases[2], { port = gettimer } }
		end

		local i, v, alive = thread.alt(cases)

		if i == 1 then
			if v == nil then
				inclosed = true
			else
				inbuf = inbuf .. v
			end
		elseif i == 2 then
			-- The console right was given away rather than
			-- copied, so the shell holds the only one: it
			-- hanging up is that proc gone. A shell that ends
			-- properly says so first and this finds the channel
			-- already closed, which leaves the crash.
			if alive == false then
				if chan then
					srv:exit(chan, 1)
					srv:close(chan)
					chan = nil
				end
			else
				from_shell(v)
			end
		else
			-- the parked getch timed out: "" means "no key".
			reply_getch("")
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
			-- pty-req arrives before the shell request, so the
			-- size is known by the time a program can ask for it.
			if ev.type == "pty" then
				ptycols, ptyrows = ev.cols, ev.rows
			elseif ev.type == "winch" then
				-- the window as it is now. A program asks
				-- the console for the size when it draws,
				-- so the next screen uses this one.
				ptycols, ptyrows = ev.cols, ev.rows
			elseif ev.type == "shell" then
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
				-- giveright, not a bare sendright: the send
				-- copies, and this daemon outlives every
				-- session it starts. One right per shell,
				-- never closed, is a server that stops
				-- accepting after MAXRIGHTS logins.
				sys.send(h, {
					cons = thread.giveright(consport),
					nsdesc = nsdesc,
					banner = BANNER,
				})

			elseif ev.type == "exec" then
				chan = ev.chan
				execing = true

				local pid, h = sys.spawn(EXEC,
				    { name = "ssh-exec" })

				if not pid then
					srv:extended(ev.chan,
					    "cannot spawn a program\r\n")
					srv:exit(ev.chan, 1)
					srv:close(ev.chan)
					break
				end
				shellpid = pid
				-- giveright for the reason the shell path
				-- gives: this daemon outlives the session.
				sys.send(h, {
					cons = thread.giveright(consport),
					nsdesc = nsdesc,
					command = ev.command,
				})

			elseif ev.type == "data" and rawmode then
				-- a full-screen program is reading raw keys:
				-- queue the bytes and hand the waiting getch its
				-- next one, with no echo and no line editing --
				-- the program draws its own screen. the rest wait
				-- in rawin for the getch after this.
				rawin = rawin .. ev.data
				if getwait and #rawin > 0 then
					local b = rawin:sub(1, 1)

					rawin = rawin:sub(2)
					reply_getch(b)
				end

			elseif ev.type == "data" then
				-- The line discipline, byte by byte, because
				-- there is no tty anywhere in this system to
				-- provide one and dos wants whole lines.
				--
				-- Byte by byte is not fastidiousness. A real
				-- terminal in raw mode sends ONE KEYSTROKE
				-- PER PACKET, so a handler that looks for a
				-- newline within a single packet sees "h",
				-- "e", "l", "p" and then a bare "\r" -- no
				-- line, then an empty one. The shell dutifully
				-- runs nothing and prints a fresh prompt, and
				-- the session looks alive and completely
				-- deaf. Feeding ssh from a pipe hides this
				-- perfectly: the whole line arrives at once
				-- and every test passes.
				--
				-- lib/cons.lua does the same job for com1,
				-- down to the "\8 \8" erase.
				for i = 1, #ev.data do
					local c = ev.data:sub(i, i)

					if c == "\4" and partial == "" then
						-- ^D on an empty line ends the
						-- session, as a shell would.
						srv:data(ev.chan, "\r\n")
						srv:exit(ev.chan, 0)
						srv:close(ev.chan)
						goto closed
					elseif c == "\r" or c == "\n" then
						srv:data(ev.chan, "\r\n")
						toshell[#toshell + 1] = partial
						partial = ""
					elseif c == "\127" or c == "\8" then
						if #partial > 0 then
							partial = partial:sub(1, -2)
							srv:data(ev.chan, "\8 \8")
						end
					elseif c >= " " then
						partial = partial .. c
						srv:data(ev.chan, c)
					end
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
		::closed::
		if srv.error then
			print("sshd: " .. tostring(srv.error))
		end
	end

	done = true
	if shellpid then
		-- Ending a session is two things, and doing only the second
		-- leaks the shell proc until reboot.
		--
		-- Closing our end of the console is what thread.readline
		-- calls EOF: its sendwait fails on a dead port and it
		-- returns nil, which dos's repl treats as "session over".
		-- But that only catches a shell BETWEEN readlines. A shell
		-- that has already asked is parked in recv() on its own
		-- reply port -- which we still hold a right to, and which is
		-- perfectly alive -- so closing the console tells it
		-- nothing at all and it waits forever.
		--
		-- So answer the outstanding readline with nil first. That is
		-- the same EOF by the same route: readline returns what recv
		-- gave it, dos sees nil, and the proc ends on its own.
		if waiting then
			sys.send(waiting, nil)
			waiting = nil
		end
		-- same for a program parked in getch when the connection drops:
		-- answer it "" (its eof) and drop our right to its reply port, or
		-- the daemon leaks one right per abruptly-closed full-screen
		-- session -- the getch analogue of the readline case above.
		if getwait then
			sys.send(getwait, "")
			getwait = nil
		end
		if gettimer then
			sys.close(gettimer)
			gettimer = nil
		end
		sys.close(consport)
		consport = sys.newport("sshd.consport")
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
