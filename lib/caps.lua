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
local function requester(target)
	return function(extra)
		local replyport = sys.newport()

		extra.reply = { __right = replyport }
		sys.send(target, extra)
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

-- the framebuffer (lib/fb.lua). unlike the wrappers above, every reply
-- there is a {ok=} / {err=} table -- sys.send carries one value, so a
-- bare nil would lose the reason -- and this is where that is unwrapped
-- into the nil-plus-message shape the rest of caps.lua returns.
--
-- fill, load and scroll can be sent WITHOUT waiting: they answer true
-- and nothing else, and a client redrawing a screen should not pay a
-- round trip per rectangle. pass wait=true when you need to know
-- whether one worked, or call sync() once at the end.
function M.fb(handle)
	local req = requester(handle)
	local f = { handle = handle }	-- for re-granting to a spawned child: {__right = f.handle}

	local function ask(m)
		local r = req(m)

		if r.err then
			return nil, r.err
		end
		return r.ok
	end

	-- send with no reply port, so nothing blocks. errors are not lost,
	-- only deferred: the next call that does wait reports its own
	-- failure, and sync() exists to ask on purpose.
	local function tell(m, wait)
		if wait then
			return ask(m)
		end
		sys.send(handle, m)
		return true
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
	-- so split, here, once, into bands of whole rows. rows rather than
	-- tiles because a band is a contiguous slice of the data string --
	-- no repacking -- and because a damaged region is usually wider
	-- than it is tall anyway.
	--
	-- this is also the honest argument for keeping pixels behind a port
	-- rather than reaching for shared memory: the copy is real, and the
	-- design that survives it is the one that only ever ships the
	-- rectangle that changed.
	local function loadband(r, data, wait)
		local stride = r.w * 4
		local perband = stride > 0 and (sys.MAXMSG - 512) // stride or 0

		if perband < 1 then
			-- a single row already exceeds a message. nothing here
			-- can fix that; the caller has to draw narrower.
			return nil, ("row of %d bytes exceeds the %d byte " ..
			    "message limit"):format(stride, sys.MAXMSG)
		end
		if perband >= r.h then
			return tell({ op = "load", r = r, data = data }, wait)
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
	-- load above -- the limit is on messages, not on direction.
	function f.unload(r)
		local stride = r.w * 4
		local perband = stride > 0 and (sys.MAXMSG - 512) // stride or 0

		if perband < 1 then
			return nil, ("row of %d bytes exceeds the %d byte " ..
			    "message limit"):format(stride, sys.MAXMSG)
		end
		if perband >= r.h then
			return ask({ op = "unload", r = r })
		end

		local out = {}
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
