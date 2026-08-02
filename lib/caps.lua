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
-- framebuffer path. The payload length is the size that matters; the
-- table around it is small, and the estimate only has to avoid
-- under-asking.
local function sendwait(handle, m)
	local need = 0

	if type(m) == "table" and type(m.data) == "string" then
		need = #m.data + 256
	end

	while true do
		local ok, why = sys.send(handle, m)

		if ok then
			return true
		end
		if why ~= "full" then
			return nil, why
		end
		sys.sendblock(handle, need)
	end
end

M.sendwait = sendwait

local function requester(target)
	return function(extra)
		local replyport = sys.newport()

		extra.reply = { __right = replyport }

		local ok, why = sendwait(target, extra)

		if not ok then
			-- never wait for a reply to a request that did not go:
			-- thread.recv here would block forever.
			sys.close(replyport)
			return nil, why
		end

		local result = thread.recv(replyport)

		sys.close(replyport)
		return result
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

		m.reply = { __right = replyport }

		local ok, why = put(m)

		if not ok then
			sys.close(replyport)
			return nil, why
		end

		local r = thread.recv(replyport)

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
	local function loadband(r, data, wait)
		local stride = r.w * 4
		local perband = stride > 0 and (CHUNK // stride) or 0

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
				local row = data:sub(y * stride + 1,
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
					    data = row:sub(x * 4 + 1,
					        (x + n) * 4) }, last)

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
			local slice = data:sub(from, from + n * stride - 1)
			-- only the LAST band waits: the task handles messages
			-- in order, so its reply reports the whole sequence.
			local last = y + n >= r.h
			local ok, err = tell({ op = "load", r = band,
			    data = slice }, wait and last)

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
