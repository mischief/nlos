-- convenience wrappers over the wire/power/tcp/udp request/reply
-- protocols (see each task's own header comment for the wire format)
-- for interactive/repl use. these are NOT raw hardware access --
-- every call still goes through the one exclusive task that owns the
-- device, exactly like any other proc; this just hides the
-- send+reply boilerplate. cons isn't wrapped here: thread.readline()
-- already is that wrapper, and plain print()/io.write() reach the
-- console directly since console_write is ambient (unlike wire/tcp/
-- udp, there's no exclusive-task round trip to hide for console
-- output).
--
-- each wrapper is a FACTORY taking an explicit handle. there are no
-- well-known capability numbers to default to: the boot payload learns
-- its own from sys.granted(), and any other proc learns them from the
-- {__right=} message that granted them. either way the number is
-- whatever right_new's first-free search picked, so it has to be
-- passed in.
local sys = require("los.sys")
local thread = require("los.thread")
local buf = require("los.buf")

local M = {}

-- one reply port PER CALL, not shared across the capability object.
-- a single shared port was the original design, but http.serve hands
-- the same tcp/dns capability object to multiple coroutines running
-- concurrently (accept loop + one per connection) -- with a shared
-- port, whichever coroutine calls thread.recv() first can steal
-- another coroutine's reply (eg an accept's boolean landing where a
-- recv's string was expected). fresh port per call avoids that
-- cross-delivery entirely; close it right after use so it doesn't
-- leak (same close-both-sides pattern net.lua's server side uses).
-- send, applying backpressure. sys.send reports a full queue
-- (false, "full") rather than raising, because the kernel refuses to
-- decide between a pipe writer that should wait and a server reply that
-- must not -- so deciding is the caller's job, and for a request whose
-- reply you are about to wait for, the answer is always "wait".
--
-- Ignoring that return silently DROPS the message. For a requester that
-- is worse than a lost write: the request is gone and the caller then
-- blocks forever on a reply that nothing will send.
--
-- sys.sendblock's size argument is what makes this park instead of
-- spin. Without it sendblock only asks "is the queue non-full", which
-- stays true while a large message is still refused by a queue holding
-- another one -- so it returns at once, the send fails again, and the
-- loop eats the whole slice. That measured as 33ms per band on the
-- framebuffer path.

-- how big a queue slot this message needs, for sendblock. The payload
-- length is the size that matters; the table around it is small, and
-- the estimate only has to avoid under-asking. Named rather than
-- inlined because requester needs the same number.
local function needof(m)
	local d = type(m) == "table" and m.data

	-- {__buf = b} is a payload too. The bytes are not in the message
	-- but are charged to the queue, so asking for room for the table
	-- alone asks for nothing and spins.
	if type(d) == "table" then
		d = d.__buf
	end

	-- a buffer needs the room its bytes need. #d works for either.
	if type(d) == "string" or buf.is(d) then
		return #d + 256
	end
	return 0
end

-- thread.parksend, not sys.sendblock: parking is legal only for the
-- coroutine the kernel resumed, and callers here are as often inside a
-- thread as not. parksend picks the right wait for either.
local function sendwait(handle, m)
	local need = needof(m)

	while true do
		local ok, why = sys.send(handle, m)

		if ok then
			return true
		end
		if why ~= "full" then
			return nil, why
		end
		thread.parksend(handle, need)
	end
end

M.sendwait = sendwait

-- the canonical request/reply, and the most-travelled one in the tree:
-- caps.udp, caps.tcp, caps.dns, caps.fb and caps.wire all come through
-- here.
--
-- thread.call is the transport -- one kernel entry at the top level,
-- send plus the scheduler's own block inside a thread -- and
-- thread.replyport() supplies the port, so nothing is minted and
-- nothing has to be closed. That is the whole of what this used to get
-- wrong three times over in other files: a port or a right per request,
-- and a leak that surfaced somewhere else entirely.
--
-- ---- why the retry loop stays here ----
--
-- thread.call REPORTS a full queue rather than waiting it out, on
-- purpose: the kernel refuses to decide between a pipe writer that
-- should wait and a server reply that must not, and so does call. For a
-- request whose reply we are about to wait for, the answer is always
-- "wait" -- so the policy lives here, where that is known.
--
-- It could not move into thread.call anyway. What makes this park
-- instead of spin is the SIZE passed to sendblock, and the size lives
-- in m.data -- a convention of these messages, not a fact the scheduler
-- has any business knowing. Without it sendblock only asks "is the
-- queue non-full", which stays true while a large message is still
-- refused by a queue holding another one: 33ms per band, measured, on
-- the framebuffer path.
--
-- Only "full" retries. "dead" and "hungup" are answers, not conditions
-- to wait out.
local function requester(target)
	return function(extra)
		local reply, send = thread.replyport()

		extra.reply = { __right = send }

		while true do
			local result, why = thread.call(target, extra, reply)

			if why ~= "full" then
				-- includes the ordinary success case, where
				-- why is nil and result is the reply
				return result, why
			end
			-- parksend, for the reason sendwait above gives
			thread.parksend(target, needof(extra))
		end
	end
end

function M.wire(handle)
	local req = requester(handle)
	local w = { handle = handle }	-- for re-granting to a spawned child: {__right = w.handle}

	function w.write(data)
		sys.send(handle, { op = "write", data = data })
	end
	function w.read()
		return req({ op = "read" })
	end
	return w
end

function M.tcp(handle)
	local req = requester(handle)
	local n = { handle = handle }	-- for re-granting to a spawned child: {__right = n.handle}

	-- the NIC's own MAC, which a dhcp client needs for chaddr.
	function n.hwaddr()
		return req({ op = "hwaddr" })
	end

	-- install a static address: what a lua dhcp client calls once it has
	-- a lease, and what stops the firmware's own dhcp dead.
	function n.setaddr(a, b, c, d, ma, mb, mc, md, ga, gb, gc, gd)
		return req({ op = "setaddr", a = a, b = b, c = c, d = d,
		    ma = ma, mb = mb, mc = mc, md = md,
		    ga = ga, gb = gb, gc = gc, gd = gd })
	end
	function n.listen(port)
		return req({ op = "listen", port = port })
	end
	function n.dial(a, b, c, d, port)
		return req({ op = "dial", a = a, b = b, c = c, d = d,
		    port = port })
	end
	function n.accept(connid)
		return req({ op = "accept", connid = connid })
	end
	function n.send(connid, data)
		return req({ op = "send", connid = connid, data = data })
	end
	function n.recv(connid, maxlen)
		return req({ op = "recv", connid = connid,
		    maxlen = maxlen or 4096 })
	end
	function n.close(connid)
		-- fire-and-forget: tcp.lua's "close" op never replies (see
		-- its own header comment) -- going through req() here would
		-- deadlock forever waiting on a reply that never comes,
		-- exactly the bug fixed earlier this session.
		sys.send(handle, { op = "close", connid = connid })
	end
	return n
end

function M.udp(handle)
	local req = requester(handle)
	local u = { handle = handle }	-- for re-granting to a spawned child: {__right = u.handle}

	-- connectionless: no listen/accept/dial, every send names its
	-- destination, every recv reports the sender's.
	function u.open(port, raw)
		return req({ op = "open", port = port, raw = raw })
	end
	function u.send(connid, a, b, c, d, port, data)
		return req({ op = "send", connid = connid,
		    a = a, b = b, c = c, d = d, port = port, data = data })
	end
	function u.recv(connid, maxlen)
		return req({ op = "recv", connid = connid,
		    maxlen = maxlen or 4096 })
	end
	function u.close(connid)
		-- fire-and-forget, same reasoning as tcp's close above.
		sys.send(handle, { op = "close", connid = connid })
	end
	function u.cancel(connid)
		-- fire-and-forget: aborts an outstanding op on connid
		-- without closing it -- see lib/udp.lua's op table comment.
		sys.send(handle, { op = "cancel", connid = connid })
	end
	return u
end

-- dns is an ordinary spawned proc rather than a kernel-registered
-- exclusive task (see lib/dns.lua), so it never appears in
-- sys.granted() at all -- its handle is simply whatever sys.spawn
-- returned.
function M.dns(handle)
	local req = requester(handle)
	local d = { handle = handle }

	function d.resolve(name)
		return req({ op = "resolve", name = name })
	end
	return d
end

-- the framebuffer (task/fb.lua). unlike the wrappers above, every reply
-- there is a {ok=} / {err=} table -- sys.send carries one value, so a
-- bare nil would lose the reason -- and this is where that is unwrapped
-- into the nil-plus-message shape the rest of caps.lua returns.
--
-- fill, load and scroll can be sent WITHOUT waiting: they answer true
-- and nothing else, and a client redrawing a screen should not pay a
-- round trip per rectangle. pass wait=true when you need to know
-- whether one worked, or call sync() once at the end.
-- chunk is the largest payload one message may carry, and exists as an
-- argument only so a test can force the splitting paths below. no real
-- mode on any machine here has a row wide enough to need the horizontal
-- split, so without this that branch would ship having never run --
-- which for splitting code means it is wrong.
function M.fb(handle, chunk)
	local f = { handle = handle }	-- for re-granting to a spawned child: {__right = f.handle}

	-- pixels are where a dropped message bites first: MAXQUEUE is
	-- 64KiB, the same as MAXMSG, so at most one band of a banded load
	-- is ever in flight. A 320x320 smiley went out as seven bands, six
	-- of which vanished, and what came back was a tidy yellow arc -- a
	-- picture wrong in a way no readback assertion catches, since every
	-- pixel that did arrive was correct. sendwait above is why that
	-- cannot happen here or in requester(); see its comment.
	local function put(m)
		return sendwait(handle, m)
	end

	-- one reply port per call, for the reason requester() gives above.
	local function ask(m)
		local replyport = sys.newport()
		-- send only: {__right=} copies the recv flag, so publishing
		-- the port as created would let the server receive on it
		local sr = sys.sendright(replyport)

		m.reply = { __right = sr }

		local ok, why = put(m)

		if not ok then
			sys.close(sr)
			sys.close(replyport)
			return nil, why
		end

		local r = thread.recv(replyport)

		sys.close(sr)
		sys.close(replyport)
		if r.err then
			return nil, r.err
		end
		return r.ok
	end

	-- no reply port, so we do not pay a round trip per rectangle -- but
	-- still put(), so a full queue waits rather than losing the
	-- message. errors are deferred, not lost: the next call that does
	-- wait reports its own failure, and sync() exists to ask on
	-- purpose.
	local function tell(m, wait)
		if wait then
			return ask(m)
		end
		return put(m)
	end

	function f.mode()
		return ask({ op = "mode" })
	end
	function f.modes()
		return ask({ op = "modes" })
	end
	function f.setmode(n)
		return ask({ op = "setmode", n = n })
	end
	function f.fill(r, color, wait)
		return tell({ op = "fill", r = r, color = color }, wait)
	end
	-- pixels are the one thing here big enough to hit the serializer's
	-- ceiling: sys.MAXMSG is 64KiB, which is 16384 pixels, which is a
	-- 128x128 tile. a screen is two orders of magnitude past that, so
	-- "load the whole screen in one call" is not a thing that can
	-- exist, and pretending otherwise just moves the failure to
	-- whichever caller first draws something large.
	--
	-- so split, here, once, into bands of whole rows -- and split a row
	-- horizontally if even one will not fit.
	--
	-- this is plan 9's answer to the same problem, arrived at the same
	-- way. libdraw's loadimage takes `chunk = display->bufsize - 64`,
	-- sends `dy = chunk/bpl` whole rows at a time, and when dy comes
	-- out zero splits the row and recurses on the remainder;
	-- unloadimage is the mirror of it. their bufsize is `iounit(datafd)`
	-- -- asked for, not assumed, which is why sys.MAXMSG is reported to
	-- lua rather than being a constant every caller copies. the 64 (our
	-- 512) is room for the header the payload travels inside; splitting
	-- to exactly the limit fails on the message around the pixels.
	--
	-- this is also the honest argument for keeping pixels behind a port
	-- rather than reaching for shared memory: the copy is real, and the
	-- design that survives it is the one that only ever ships the
	-- rectangle that changed. plan 9 pays it too, down a 9P pipe.
	local CHUNK = chunk or (sys.MAXMSG - 512)

	-- one band of a payload, as bytes this can give away. Copied out
	-- once and handed over, rather than copied into the message and
	-- out of it again as a string.
	local function piece(data, from, to)
		local b = buf.new(to - from + 1)

		b:copy(1, data, from, to)
		return b
	end

	-- what a band travels as. Anything piece() made is ours alone, so
	-- this hands it over; a caller's own bytes passed straight through
	-- are not ours to give, and travel as bytes.
	local function given(b)
		if buf.is(b) and b:movable() then
			return { __buf = b }
		end
		return b
	end

	local function loadband(r, data, wait)
		local stride = r.w * 4
		local perband = stride > 0 and (CHUNK // stride) or 0

		-- the whole payload in one message. What the caller handed
		-- us is the caller's, so it travels as bytes rather than
		-- being taken away.
		if perband >= r.h then
			return tell({ op = "load", r = r, data = data }, wait)
		end

		-- not even one row fits, so split the ROW and recurse on what
		-- is left of it -- plan 9's loadimage does exactly this, and
		-- it is the case a first draft gets wrong by returning an
		-- error and telling the caller to draw narrower. a screen
		-- wider than a message is not the caller's mistake.
		--
		-- their `& ~7` on the split point is pixel alignment for
		-- sub-byte depths; every pixel here is four whole bytes, so
		-- there is nothing to align.
		if perband < 1 then
			local half = CHUNK // 4

			if half < 1 then
				return nil, "message limit below one pixel"
			end
			for y = 0, r.h - 1 do
				local row = piece(data, y * stride + 1,
				    (y + 1) * stride)
				local x = 0

				while x < r.w do
					local n = r.w - x

					if n > half then
						n = half
					end
					local last = wait and
					    y == r.h - 1 and x + n >= r.w
					local ok, err = tell({ op = "load",
					    r = { x = r.x + x, y = r.y + y,
					        w = n, h = 1 },
					    data = given(piece(row, x * 4 + 1,
					        (x + n) * 4)) }, last)

					if not ok then
						return nil, err
					end
					x = x + n
				end
			end
			return true
		end

		local y = 0

		while y < r.h do
			local n = r.h - y

			if n > perband then
				n = perband
			end
			local band = { x = r.x, y = r.y + y, w = r.w, h = n }
			local from = y * stride + 1
			local slice = piece(data, from, from + n * stride - 1)
			-- only the LAST band waits: the task handles messages
			-- in order, so its reply reports the whole sequence.
			local last = y + n >= r.h
			local ok, err = tell({ op = "load", r = band,
			    data = given(slice) }, wait and last)

			if not ok then
				return nil, err
			end
			y = y + n
		end
		return true
	end

	function f.load(r, data, wait)
		return loadband(r, data, wait)
	end
	-- the reply is a message too, so readback needs the same banding as
	-- load above -- the limit is on messages, not on direction. plan 9
	-- splits unloadimage identically, for identically this reason.
	function f.unload(r)
		local stride = r.w * 4
		local perband = stride > 0 and (CHUNK // stride) or 0

		if perband >= r.h then
			return ask({ op = "unload", r = r })
		end

		local out = {}

		-- a row wider than a message: read it in pieces and rejoin.
		-- the pieces have to be concatenated PER ROW, since the
		-- result is one contiguous run of rows.
		if perband < 1 then
			local half = CHUNK // 4

			if half < 1 then
				return nil, "message limit below one pixel"
			end
			for y = 0, r.h - 1 do
				local x = 0

				while x < r.w do
					local n = r.w - x

					if n > half then
						n = half
					end
					local piece, err = ask({ op = "unload",
					    r = { x = r.x + x, y = r.y + y,
					        w = n, h = 1 } })

					if not piece then
						return nil, err
					end
					out[#out + 1] = piece
					x = x + n
				end
			end
			return table.concat(out)
		end

		local y = 0

		while y < r.h do
			local n = r.h - y

			if n > perband then
				n = perband
			end
			local piece, err = ask({ op = "unload",
			    r = { x = r.x, y = r.y + y, w = r.w, h = n } })

			if not piece then
				return nil, err
			end
			out[#out + 1] = piece
			y = y + n
		end
		return table.concat(out)
	end
	function f.scroll(r, to, wait)
		return tell({ op = "scroll", r = r, to = to }, wait)
	end

	-- round-trip the cheapest op there is. one task handles its
	-- messages in order, so a reply to this one means every load sent
	-- before it has already reached the screen.
	function f.sync()
		return ask({ op = "mode" }) ~= nil
	end
	return f
end

-- the console as an interactive terminal, for a full-screen program
-- (bin/vi.lua). the handle is the same console mailbox every proc writes
-- to; a tty adds the raw side of it: rawon/rawoff to leave and re-enter
-- line-edited cooked mode, and getch for one un-echoed keystroke. cons,
-- the ssh session and (later) webterm each answer these, so a program
-- runs over any of them the way posix vi runs over a serial line, a pty
-- or an xterm -- one contract, several terminals.
--
-- getch is a plain request/reply, deliberately: the console owns the
-- timeout (it replies "" when `timeout` ms pass with no key), so this
-- side just blocks on the answer. that is what lets the same call work
-- whether the program is a proc of its own or a coroutine in a shell --
-- thread.recv adapts to either, where a client-side timer would need the
-- scheduler and would race the console over who consumed the byte.
function M.tty(handle)
	local t = { handle = handle }	-- for re-granting: {__right = t.handle}
	-- the port to wait on, and the send right to publish. minted
	-- together on first use: {__right=} copies the recv flag, so the
	-- port as created would hand the console the ability to receive
	-- our answers.
	local replyport, replyright

	local function reply()
		if not replyport then
			replyport = sys.newport()
			replyright = sys.sendright(replyport)
		end
		return replyright
	end

	function t.write(s)
		sys.send(handle, { op = "write", data = s })
	end
	-- fire and forget: messages to one port keep their order, so a rawon
	-- followed by a getch is seen in that order without a round trip.
	function t.rawon()
		sys.send(handle, { op = "rawon" })
	end
	function t.rawoff()
		sys.send(handle, { op = "rawoff" })
	end
	-- one keystroke, or "" once `timeout` ms pass with none. one reusable
	-- reply port: a full-screen editor reads one key at a time, never
	-- concurrently, so there is nothing to cross-deliver.
	function t.getch(timeout)
		sys.send(handle, { op = "getch", timeout = timeout,
		    reply = { __right = reply() } })
		return thread.recv(replyport)
	end
	-- how wide and how tall, or nil when the far end does not know.
	-- A program that lays out columns asks once and falls back to its
	-- own default; nil means a serial line, not an error.
	function t.size()
		sys.send(handle, { op = "size",
		    reply = { __right = reply() } })

		-- Bounded, because "the far end does not know" and "the far
		-- end does not answer" are the same thing to a caller and
		-- only one of them is survivable by waiting. A console that
		-- has never heard of this op drops the message, and an
		-- unbounded recv here parks the program on a port nothing
		-- will ever write -- no cpu, no wakeup, nothing in ps but a
		-- pid sitting on a port. Half a second is far longer than a
		-- console on the same machine needs.
		local m = thread.recvtimeout(replyport, 500)

		return m and m.cols, m and m.rows
	end
	function t.close()
		if replyport then
			sys.close(replyport)
			replyport = nil
		end
	end
	return t
end

function M.power(handle)
	local p = { handle = handle }	-- for re-granting to a spawned child: {__right = p.handle}

	function p.reset(mode)
		sys.send(handle, { op = "reset", mode = mode or "shutdown" })
	end
	function p.stall(us)
		sys.send(handle, { op = "stall", us = us })
	end
	return p
end

return M
