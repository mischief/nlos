-- tcp: connections, as a proc that owns all of them.
--
-- lib/tcb.lua is one connection and touches nothing; this is the loop
-- that gives it a wire, a clock and clients. It holds no device: its
-- device is task/ip.lua, named by kernel.c's driver table as .needs =
-- "ip", exactly as the ip task's device is the eth task.
--
-- It serves lib/caps.lua's tcp protocol, which is the entire point.
-- That protocol was written against the UEFI firmware's EFI_TCP4 and is
-- what lib/http.lua, lib/p9tcp.lua, lib/ssh, task/sshd.lua and
-- task/webterm.lua already speak. A client holding the right cannot
-- tell which is underneath it, so the same services run on a machine
-- with firmware and on one with nothing but a virtio-net card:
--
--   {op="dial", a=,b=,c=,d=, port=, reply=}   -> connid | nil
--   {op="send", connid=, data=, reply=}       -> true | false
--   {op="recv", connid=, maxlen=, reply=}     -> data | nil
--   {op="close", connid=}                      (no reply, ever)
--   {op="hwaddr", reply=} / {op="setaddr", ...}
--   {op="listen", port=, reply=} / {op="accept", connid=, reply=}
--
-- and its own {op="stats", reply=}.
--
-- ---- one timer, not one per connection ----
--
-- MAXTIMERS is 32 machine-wide. A timer per connection therefore runs
-- the machine out of them at 32 connections, and thread.sleep already
-- has a documented "timer table full" path. So every deadline lives in
-- its connection and the loop arms a single timer for the nearest one.
-- That is also why connections are entries in a table here rather than
-- procs of their own: a proc per connection costs ~52KB of lua heap
-- each, needs a hop to demux every segment to it, and would keep a
-- whole proc alive for the 2*MSL a TIME-WAIT connection spends doing
-- nothing at all.
--
-- What is not here yet: retransmission, out-of-order reassembly, a
-- graceful close, and listen/accept. close aborts today -- see its op
-- below -- and each gap has a commit coming.

local sys = require("los.sys")
local thread = require("los.thread")
local ip4 = require("ip4")
local tcp4 = require("tcp4")
local tcb = require("tcb")

local iph = sys.granted().ip

if not iph then
	error("tcp: no ip capability granted", 0)
end

-- 1500 of ethernet, less 20 of IP and 20 of TCP. We advertise it and
-- the peer decides what it can take; anything larger than the link
-- would be a datagram the ip layer must fragment, and it does not.
local MSS = 1500 - ip4.HDRLEN - tcp4.HDRLEN

-- how long a dial waits before giving up. Short, and short on purpose:
-- until retransmission lands a lost SYN is not resent, so this is the
-- whole of a dial's patience rather than the last resort behind it.
local DIAL_MS = 10000

local conns = {}	-- connid -> connection record
local byname = {}	-- "remote address, both ports" -> connid
local nextconn = 1
local nextephem = 32768

local stat = {
	dialed = 0,
	refused = 0,
	seg_in = 0,
	seg_out = 0,
	seg_bad = 0,
	no_conn = 0,
	reset_sent = 0,
	closing = 0,
	timedout = 0,
}

-- the packets from task/ip.lua arrive here. Registered once, below,
-- with a right that this proc keeps for as long as it runs.
local pktport = sys.newport()

local function reply_to(m, v)
	local h = type(m) == "table" and type(m.reply) == "table" and
	    m.reply.__right or nil

	if h then
		sys.send(h, v)
		sys.close(h)
	end
end

-- see task/ip.lua's whole(): a client can send a float, and 1.5 reaches
-- string.pack as an error that kills the task rather than the request.
local function whole(v, max)
	if type(v) ~= "number" then
		return nil
	end

	local n = math.tointeger(v)

	if not n or n < 0 or n > max then
		return nil
	end
	return n
end

-- a connection is identified by the pair of ports and the far address.
-- Our own address is not in the key: it is the same for every
-- connection on a machine with one interface, and using it would break
-- the moment dhcp renews into a different one.
local function name(raddr, rport, lport)
	return raddr .. string.pack(">I2I2", rport, lport)
end

local function ipconfig()
	return thread.rpc(iph, { op = "config" }) or {}
end

-- ---- the wire ----

local function output(c, seg)
	local bytes = tcp4.encode(seg, c.laddr, c.raddr)

	-- no reply asked for: a round trip per segment would put the ip
	-- task's latency inside every one of them. sendwait rather than
	-- send, so a full queue parks this proc instead of losing the
	-- segment -- see lib/caps.lua's requester for why the size
	-- argument is what makes that park rather than spin.
	local need = #bytes + 256

	while true do
		local ok, why = sys.send(iph, { op = "output",
		    proto = ip4.PROTO_TCP, dst = c.raddr, data = bytes })

		if ok then
			stat.seg_out = stat.seg_out + 1
			return true
		end
		if why ~= "full" then
			return nil, why
		end
		sys.sendblock(iph, need)
	end
end

-- everything the state machine wants to send, sent.
local function flush(c)
	for _, seg in ipairs(c.t:take()) do
		output(c, seg)
	end
end

-- a reset for a segment belonging to no connection we have. This is
-- what makes a closed port say so instead of swallowing the SYN and
-- leaving the peer to retransmit into silence for a minute.
local function refuse(src, dst, seg)
	local r = tcp4.reset_for(seg)

	if not r then
		return
	end
	stat.reset_sent = stat.reset_sent + 1
	sys.send(iph, { op = "output", proto = ip4.PROTO_TCP, dst = src,
	    data = tcp4.encode(r, dst, src) })
end

-- ---- connections ----

local function forget(c)
	conns[c.id] = nil
	byname[c.key] = nil
end

-- answer everyone parked on this connection, and say the same thing to
-- all of them. A client blocked in recv on a connection that has just
-- been reset must come back with nil rather than waiting for a segment
-- that cannot arrive.
local function wake(c, value)
	for _, m in ipairs(c.readers) do
		reply_to(m, value)
	end
	c.readers = {}

	if c.writer then
		reply_to(c.writer.m, value and true or false)
		c.writer = nil
	end
	if c.dialer then
		reply_to(c.dialer, nil)
		c.dialer = nil
	end
end

-- hand out whatever the state machine has for readers, oldest first.
local function feed(c)
	while #c.readers > 0 do
		local m = c.readers[1]
		local data = c.t:read(m.maxlen or 4096)

		if data == nil then
			-- the peer closed and there is nothing left: the
			-- stream ended, which is what nil means here and what
			-- every client of caps.tcp already treats as eof.
			table.remove(c.readers, 1)
			reply_to(m, nil)
		elseif #data > 0 then
			table.remove(c.readers, 1)
			reply_to(m, data)
		else
			return		-- nothing yet; keep waiting
		end
	end
end

-- as much of a parked write as the send buffer will now take.
local function push(c)
	local w = c.writer

	if not w then
		return
	end

	local n = c.t:write(w.data:sub(w.off + 1), sys.uptime_ms())

	if n == nil then
		reply_to(w.m, false)
		c.writer = nil
		return
	end
	w.off = w.off + n
	if w.off >= #w.data then
		reply_to(w.m, true)
		c.writer = nil
	end
end

-- one pass over everything a segment or a request may have changed.
-- Called after every entry point, so that no path has to remember which
-- of these it might have made possible.
local function service(c)
	for _, e in ipairs(c.t:events()) do
		if e.kind == "established" then
			stat.dialed = stat.dialed + 1
			if c.dialer then
				reply_to(c.dialer, c.id)
				c.dialer = nil
				c.deadline = nil
			end
		elseif e.kind == "refused" or e.kind == "reset" then
			if e.kind == "refused" then
				stat.refused = stat.refused + 1
			end
			c.dead = true
		elseif e.kind == "closing" then
			-- the peer is done sending. Nothing to do here: a
			-- reader learns it from recv returning nil, and the
			-- user may still write.
			stat.closing = stat.closing + 1
		end
	end

	-- the state machine reaching CLOSED is what ends a connection,
	-- whether that was a reset, a timeout, or an orderly close that has
	-- finished waiting out its TIME-WAIT.
	if c.t.state == tcb.CLOSED then
		c.dead = true
	end

	push(c)
	feed(c)
	flush(c)

	if c.dead then
		-- flush first: a reset we were asked to send still has to go
		-- out before the connection stops existing.
		wake(c, nil)
		forget(c)
	end
end

-- ---- inbound ----

local function on_packet(m)
	if type(m) ~= "table" or type(m.data) ~= "string" or
	    type(m.src) ~= "string" or type(m.dst) ~= "string" then
		return
	end

	local seg = tcp4.decode(m.data, m.src, m.dst)

	if not seg then
		-- a bad checksum or a runt. Counted rather than ignored: a
		-- climbing number here says the wire or our own encode is
		-- wrong, and the two look identical from a client.
		stat.seg_bad = stat.seg_bad + 1
		return
	end

	stat.seg_in = stat.seg_in + 1

	local id = byname[name(m.src, seg.sport, seg.dport)]
	local c = id and conns[id]

	if not c then
		stat.no_conn = stat.no_conn + 1
		refuse(m.src, m.dst, seg)
		return
	end

	c.t:segment(seg, sys.uptime_ms())
	service(c)
end

-- ---- client requests ----

local function on_request(m)
	if type(m) ~= "table" then
		return
	end

	if m.op == "dial" then
		local a, b = whole(m.a, 0xff), whole(m.b, 0xff)
		local cc, d = whole(m.c, 0xff), whole(m.d, 0xff)
		local port = whole(m.port, 0xffff)

		if not a or not b or not cc or not d or not port or port == 0 then
			reply_to(m, nil)
			return
		end

		local cfg = ipconfig()

		-- no address, no connection. A SYN from 0.0.0.0 would be
		-- answered by nobody, and failing here says why rather than
		-- leaving the caller to wait out the dial timeout.
		if not cfg.ip or cfg.ip == ip4.ANY then
			reply_to(m, nil)
			return
		end

		local raddr = string.char(a, b, cc, d)
		local lport = nextephem

		nextephem = 32768 + ((nextephem - 32767) % 28000)

		local id = nextconn

		nextconn = nextconn + 1

		local c = {
			id = id,
			laddr = cfg.ip, lport = lport,
			raddr = raddr, rport = port,
			key = name(raddr, port, lport),
			readers = {},
			dialer = m,
			deadline = sys.uptime_ms() + DIAL_MS,
		}

		-- The initial sequence number must not be a counter and must
		-- not be guessable from another connection's (RFC 6528): an
		-- off-path attacker who can predict it can inject into the
		-- stream. lib/tcb.lua deliberately does not generate it --
		-- it has no clock and no secret -- so it is drawn here, from
		-- the machine's rng.
		local iss

		local ok, rng = pcall(require, "los.platform.rng")

		if ok and rng then
			iss = string.unpack(">I4", rng.bytes(4))
		else
			-- no rng on this platform. Say so rather than
			-- quietly using a counter and calling it an ISN.
			reply_to(m, nil)
			return
		end

		c.t = tcb.new({
			laddr = cfg.ip, lport = lport,
			raddr = raddr, rport = port,
			iss = iss, mss = MSS,
		})
		conns[id] = c
		byname[c.key] = id
		c.t:connect(sys.uptime_ms())
		service(c)

	elseif m.op == "send" then
		local c = conns[m.connid]

		if not c or type(m.data) ~= "string" then
			reply_to(m, false)
			return
		end
		if c.writer then
			-- one write at a time per connection. Two clients
			-- interleaving into one stream is not something to
			-- arbitrate; it is a bug in whoever shared the right.
			reply_to(m, false)
			return
		end
		c.writer = { m = m, data = m.data, off = 0 }
		service(c)

	elseif m.op == "recv" then
		local c = conns[m.connid]

		if not c then
			reply_to(m, nil)
			return
		end
		c.readers[#c.readers + 1] = m
		service(c)

	elseif m.op == "close" then
		local c = conns[m.connid]

		if not c then
			return
		end

		-- A graceful close: the FIN goes out behind everything
		-- already written, and the connection stays in the table
		-- until the state machine reaches CLOSED. That is what makes
		-- a client able to write a request, close, and still have
		-- the request arrive.
		--
		-- Anyone parked on this connection is answered now rather
		-- than being left to wait out a TIME-WAIT they have no
		-- interest in: from the client's side the connection is over
		-- the moment it says so.
		c.closed_by_user = true
		c.t:close(sys.uptime_ms())
		wake(c, nil)
		service(c)

	elseif m.op == "hwaddr" then
		-- the NIC's address belongs to the layer that owns the NIC,
		-- so this is a question forwarded rather than answered. It
		-- exists because caps.tcp's clients ask it: lib/dhcp.lua
		-- wants a mac for chaddr.
		reply_to(m, ipconfig().mac)

	elseif m.op == "setaddr" then
		local a, b = whole(m.a, 0xff), whole(m.b, 0xff)
		local cc, d = whole(m.c, 0xff), whole(m.d, 0xff)

		if not a or not b or not cc or not d then
			reply_to(m, false)
			return
		end

		local cfg = { op = "configure", ip = string.char(a, b, cc, d) }

		if whole(m.ma, 0xff) and whole(m.mb, 0xff) and
		    whole(m.mc, 0xff) and whole(m.md, 0xff) then
			cfg.mask = string.char(m.ma, m.mb, m.mc, m.md)
		end
		if whole(m.ga, 0xff) and whole(m.gb, 0xff) and
		    whole(m.gc, 0xff) and whole(m.gd, 0xff) then
			cfg.gw = string.char(m.ga, m.gb, m.gc, m.gd)
		end
		reply_to(m, thread.rpc(iph, cfg) and true or false)

	elseif m.op == "listen" or m.op == "accept" then
		-- not yet. nil is the protocol's own answer for "could not",
		-- and a client that gets it fails where it asked rather than
		-- blocking forever on an accept that will never complete.
		reply_to(m, nil)

	elseif m.op == "stats" then
		local s = { conns = 0 }

		for k, v in pairs(stat) do
			s[k] = v
		end
		s.states = {}
		for _, c in pairs(conns) do
			s.conns = s.conns + 1
			s.states[#s.states + 1] = c.t.state
		end
		reply_to(m, s)

	else
		reply_to(m, nil)
	end
end

-- ---- deadlines ----

local function expire(now)
	-- a copy, because service() may remove a connection from conns and
	-- modifying a table while iterating it with pairs is undefined.
	local live = {}

	for id, c in pairs(conns) do
		live[id] = c
	end

	for _, c in pairs(live) do
		-- the dial deadline is this task's, not the state machine's:
		-- it bounds how long a client waits, and a connection whose
		-- SYN is still being retransmitted is one the client has
		-- already given up on.
		if c.deadline and now >= c.deadline then
			c.deadline = nil
			stat.timedout = stat.timedout + 1
			if c.dialer then
				reply_to(c.dialer, nil)
				c.dialer = nil
			end
			c.t:abort(now)
			c.dead = true
		else
			-- retransmissions and TIME-WAIT belong to the state
			-- machine, which is told the time and decides.
			c.t:tick(now)
		end
		service(c)
	end
end

-- one timer for the whole task, re-armed to the nearest deadline. See
-- the header: MAXTIMERS is 32 machine-wide, so this is not an
-- optimisation but the only arrangement that scales past 32 conns.
local timer

local function rearm()
	local soonest

	for _, c in pairs(conns) do
		-- two deadlines per connection and one timer for the task:
		-- the dial timeout above, and whatever the state machine
		-- wants next -- a retransmission, or the end of a TIME-WAIT.
		local want = c.t:deadline()

		if c.deadline and (not want or c.deadline < want) then
			want = c.deadline
		end
		if want and (not soonest or want < soonest) then
			soonest = want
		end
	end

	if timer then
		sys.close(timer)
		timer = nil
	end
	if soonest then
		local ms = soonest - sys.uptime_ms()

		timer = sys.timer(ms > 1 and ms or 1)
	end
end

-- ---- start ----

-- claim tcp from the ip task. Without this nothing is ever delivered,
-- so a failure here is fatal rather than something to carry on past.
if not thread.rpc(iph, { op = "raw", proto = ip4.PROTO_TCP,
    port = thread.giveright(pktport) }) then
	error("tcp: the ip task refused the tcp protocol", 0)
end

while true do
	rearm()

	local cases = { { port = sys.SELF }, { port = pktport } }

	if timer then
		cases[3] = { port = timer }
	end

	local which, m = thread.alt(cases)

	if which == 2 then
		on_packet(m)
	elseif which == 3 then
		expire(sys.uptime_ms())
	else
		on_request(m)
	end
end
