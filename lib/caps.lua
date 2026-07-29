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
