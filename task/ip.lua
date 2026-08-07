-- ip: the IPv4 host, as a proc that never stops running.
--
-- Everything under this was already written -- lib/inet.lua is the
-- body, and its header said it was waiting for a message loop. This is
-- the loop, and what it buys is that the machine is on the network
-- rather than merely capable of being. Until now nothing answered an
-- ARP request or a ping unless some proc happened to be inside pump()
-- at that instant; between calls the host simply was not there.
--
-- ARP, IPv4, ICMP and UDP in one proc, which is the split the layering
-- does not decide. They sit on one packet's path: resolving is part of
-- sending, echo is part of receiving, and a udp datagram is eight bytes
-- and a demux table. Separating them would put a message round trip
-- inside the transmission of one packet. TCP is the one that will want
-- its own proc, having timers and per-connection state and being big
-- enough that isolating its crashes is worth a hop.
--
-- The protocol is lib/udp.lua's, exactly -- open, send, recv, close,
-- cancel, with addresses as octets -- because that is what
-- lib/dhcp.lua and task/dns.lua already speak. A client cannot tell
-- whether the right it holds names the firmware's udp4 or this, which
-- is the whole point: the same clients run on both platforms.
--
--   {op="open", port=, reply=}                  -> connid | nil
--   {op="send", connid=, a=,b=,c=,d=, port=, data=, reply=} -> bool
--   {op="recv", connid=, maxlen=, reply=}       -> {data=,a=,b=,c=,d=,port=} | nil
--   {op="close", connid=}                        (no reply)
--   {op="cancel", connid=}                       (no reply)
--
-- and its own, for the layer below udp:
--
--   {op="configure", ip=, mask=, gw=, reply=}   -> true
--   {op="config", reply=}                       -> {ip=,mask=,gw=,mac=}
--   {op="stats", reply=}                        -> counters, below
--
-- and two for a protocol that lives in another proc:
--
--   {op="raw", proto=, port={__right=}, reply=} -> true | false
--   {op="output", proto=, dst=, data=, reply=}  -> true | false
--
-- which is how TCP gets here without being here. This proc keeps arp,
-- ip, icmp and udp together because they sit on one packet's path; tcp
-- is the one that does not, having timers, per-connection state, and
-- enough size that a fault in it should not take the machine off the
-- network -- if it did, the address, the lease and the ability to
-- answer a ping would go with it.
--
-- The cost is honest: an inbound segment crosses eth -> ip -> tcp
-- rather than stopping here, and an outbound one crosses back. That is
-- a per-segment tax on throughput, paid to keep the crash domains
-- apart, and it is reversible -- lib/tcp4.lua and lib/tcb.lua do not
-- care which proc requires them.
--
-- Unlike the udp ops above, these two take an address as the 4-byte
-- wire form rather than four octets. Octets are what lib/caps.lua shows
-- a client, and the udp protocol matches it because lib/dhcp.lua speaks
-- it; raw is not a client interface but a seam between two tasks, and
-- on this side of it an address has been a 4-byte string since
-- lib/ip4.lua. One length check also beats four range checks.
--
-- It starts with no address. That is not a degenerate case to be got
-- through quickly: DHCP runs over this, so the stack has to serve a
-- client before it knows who it is, and lib/inet.lua's receive path
-- accepts a frame unicast to our mac whatever the packet says for
-- exactly that reason.

local sys = require("los.sys")
local thread = require("los.thread")
local ip4 = require("ip4")
local udp4 = require("udp4")
local arp = require("arp")
local inet = require("inet")
local ethwire = require("ethwire")

-- the eth right is granted by name, like every other task's device --
-- this one's device just happens to be another task. kernel.c's driver
-- table says so with .needs = "eth"; see struct driver_desc.
local ethh = sys.granted().eth

if not ethh then
	-- nothing under us. Say it once and stop, rather than serving a
	-- protocol we cannot carry.
	error("ip: no eth capability granted", 0)
end

local wire = ethwire.new(ethh)
local host = inet.new(wire, { mac = wire.mac(), ip = ip4.ANY })

-- frames are pushed into the wire's own port by the eth task, and that
-- port is in the alt below, so this proc sleeps until either a client
-- asks something or a frame arrives -- and the machine sleeps with it.
-- ethwire registered it in new(), above; a second listener here would
-- only cost a copy of every frame.
local framePort = wire.port

-- ---- udp state ----

-- datagrams that arrived with nobody waiting, per conn.
--
-- Bounded two ways, and the arriving datagram is what loses.
--
-- Which end to drop is not a toss-up. Dropping the oldest -- what this
-- did at first -- hands a slow reader the NEWEST datagrams and silently
-- loses the ones it was waiting for, which for every request/reply
-- protocol above udp is precisely backwards: the reply you are blocked
-- on is the oldest unread. Dropping the arrival instead leaves an
-- intact prefix, so a client that comes back late gets a correct
-- sequence, merely a short one. It is also what a real socket does when
-- its receive buffer is full, and what kernel.c does at MAXQUEUE: the
-- thing that does not fit is the thing that fails.
--
-- Bytes are the real bound, for the reason kernel.c gives for bounding
-- ports in bytes: eight small datagrams and eight full-sized ones are
-- very different amounts of memory. A count cap sits alongside it
-- because a flood of one-byte datagrams costs far more in Lua table
-- overhead than its byte count admits.
local RCVBUF_DEFAULT = 32 * 1024
local RCVQ_MAX = 64
-- a ceiling on what a client may ask for, since the queue it sizes is
-- held in this proc's heap and every conn gets one.
local RCVBUF_MAX = 1024 * 1024

local conns = {}	-- connid -> {port=, queue=, waiting=, ...}
local rcvbuf = RCVBUF_DEFAULT
local nextconn = 1
local nextephem = 32768

-- counters, because a stack that misbehaves quietly is the hard kind.
--
-- Every one of these exists because its absence cost time: frames in
-- and out say whether the wire is the problem, dropped says whether we
-- are, and the split between "not for us" and "nothing bound" is the
-- difference between a switch flooding us and a client that has not
-- opened the port it thinks it has.
-- ---- protocols served elsewhere ----
--
-- proto number -> a send right to the proc that owns it. One owner per
-- protocol: two procs both claiming to be TCP is not a configuration to
-- arbitrate between, it is a mistake, and the second one is told so.
local raw = {}

local stat = {
	frames_in = 0,
	frames_out_fail = 0,
	udp_in = 0,
	udp_unbound = 0,
	udp_queued = 0,
	udp_dropped = 0,
	unresolved = 0,
	raw_in = 0,
	raw_unbound = 0,
	raw_dropped = 0,
}


local function reply_to(m, v)
	local h = type(m.reply) == "table" and m.reply.__right or nil

	if h then
		sys.send(h, v)
		sys.close(h)
	end
end

-- a whole number in [0, max], or nil.
--
-- type(v) == "number" is not the check it looks like: a client can send
-- a float, and 1.5 & 0xff raises "number has no integer representation"
-- exactly as a nil reaching string.char did. So does string.pack with a
-- port of 1.5, and an out-of-range one overflows. math.tointeger is the
-- test that separates them, and it keeps 1.0 -- a client that computed
-- an octet in floating point meant a whole number and should not be
-- refused for how it stored it.
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

local function bound(port)
	for id, c in pairs(conns) do
		if c.port == port then
			return id
		end
	end
	return nil
end

-- hand a datagram to whoever is waiting for it, or hold it -- or, if
-- there is no room to hold it, drop it and say so.
local function deliver(c, msg)
	if #c.waiting > 0 then
		reply_to(table.remove(c.waiting, 1), msg)
		return
	end

	local n = #msg.data

	if #c.queue >= RCVQ_MAX or c.qbytes + n > c.rcvbuf then
		stat.udp_dropped = stat.udp_dropped + 1
		c.dropped = c.dropped + 1
		return
	end

	c.queue[#c.queue + 1] = msg
	c.qbytes = c.qbytes + n
	stat.udp_queued = stat.udp_queued + 1
end

-- take the head of the queue, keeping the byte count honest.
local function dequeue(c)
	local msg = table.remove(c.queue, 1)

	c.qbytes = c.qbytes - #msg.data
	return msg
end

local function on_udp(p)
	local d = udp4.decode(p.payload, p.src, p.dst)

	if not d then
		return
	end

	stat.udp_in = stat.udp_in + 1

	local id = bound(d.dport)

	if not id then
		stat.udp_unbound = stat.udp_unbound + 1
		return		-- nothing bound; a real host would send an
				-- icmp port-unreachable, which nothing here
				-- yet consumes
	end

	local a, b, c4, d4 = p.src:byte(1, 4)

	deliver(conns[id], { data = d.data, a = a, b = b, c = c4, d = d4,
	    port = d.sport })
end

-- hand a packet to the proc that owns its protocol.
--
-- A failed delivery is a dropped packet and never a stalled receive
-- path. If the owner's queue is full we lose the packet exactly as a
-- wire would, and above tcp that is a retransmission -- whereas waiting
-- here would stop this proc reading frames for arp, icmp, dhcp and
-- every udp client at once, to buy one connection a segment it is
-- perfectly able to ask for again.
local function on_raw(p)
	local h = raw[p.proto]

	if not h then
		stat.raw_unbound = stat.raw_unbound + 1
		return
	end

	local ok, why = sys.send(h, { src = p.src, dst = p.dst,
	    proto = p.proto, data = p.payload })

	if ok then
		stat.raw_in = stat.raw_in + 1
	elseif why == "full" then
		stat.raw_dropped = stat.raw_dropped + 1
	else
		-- dead or hungup: the owner is gone for good, so the
		-- registration goes with it rather than being retried on
		-- every packet forever. Closing our right is what lets the
		-- port actually go away.
		sys.close(h)
		raw[p.proto] = nil
	end
end

-- ---- client requests ----

local function on_request(m)
	if m.op == "open" then
		local port = m.port

		-- checked HERE, not where it is used. an unchecked port is
		-- stored on the conn and only reaches string.pack on the
		-- first send, so a bad open plants the failure and some
		-- later, innocent send is what dies of it.
		if port ~= nil and port ~= 0 then
			port = whole(port, 0xffff)
			if not port then
				reply_to(m, nil)
				return
			end
		end
		if not port or port == 0 then
			port = nextephem
			nextephem = 32768 + ((nextephem - 32767) % 28000)
		end
		if bound(port) then
			reply_to(m, nil)	-- already in use
			return
		end

		local id = nextconn

		nextconn = nextconn + 1
		conns[id] = { port = port, waiting = {}, queue = {},
		    qbytes = 0, dropped = 0, rcvbuf = rcvbuf }
		reply_to(m, id)

	elseif m.op == "send" then
		local c = conns[m.connid]

		-- every field checked before it is used, because a client
		-- must not be able to kill the stack. It could: a send with
		-- a missing octet reached string.char as a nil and took the
		-- whole task down, and with it the network for every other
		-- proc on the machine. A bad request is answered false.
		--
		-- whole() rather than type(): the value has to be an INTEGER
		-- in range, not merely a number, since the arithmetic below
		-- and string.pack inside udp4.encode both raise on a float
		-- with no integer representation. Checking the type alone
		-- left the same hole this comment is about, one field over.
		local port = whole(m.port, 0xffff)
		local a, b = whole(m.a, 0xff), whole(m.b, 0xff)
		local cc, d = whole(m.c, 0xff), whole(m.d, 0xff)

		if not c or type(m.data) ~= "string" or not port or
		    not a or not b or not cc or not d then
			reply_to(m, false)
			return
		end

		local dst = string.char(a, b, cc, d)
		-- srcfor, not host.ip: a datagram to 127.0.0.1 comes from
		-- 127.0.0.1, and the checksum below covers a pseudo-header
		-- of both addresses -- so the address claimed here and the
		-- one the packet is stamped with in output() have to be the
		-- same one, or the receiver discards it as corrupt.
		local src = host:srcfor(dst)
		local data = m.data
		local ok, why = host:output(dst, ip4.PROTO_UDP, {
			len = udp4.HDRLEN + #data,
			fill = function(f, off)
				udp4.encode(c.port, port, data, src, dst, f, off)
			end,
		})

		if not ok then
			stat.frames_out_fail = stat.frames_out_fail + 1
		elseif why == "held" then
			-- accepted, waiting on an arp reply. Counted because
			-- a machine doing this constantly is one whose
			-- neighbours keep expiring.
			stat.unresolved = stat.unresolved + 1
		end

		reply_to(m, ok and true or false)

	elseif m.op == "recv" then
		local c = conns[m.connid]

		if not c then
			reply_to(m, nil)
			return
		end
		if #c.queue > 0 then
			reply_to(m, dequeue(c))
			return
		end
		c.waiting[#c.waiting + 1] = m

	elseif m.op == "close" then
		local c = conns[m.connid]

		if c then
			-- answer anyone still waiting rather than leaving
			-- them blocked on a conn that no longer exists.
			for _, w in ipairs(c.waiting) do
				reply_to(w, nil)
			end
			conns[m.connid] = nil
		end

	elseif m.op == "cancel" then
		-- abort outstanding receives without closing the conn, for a
		-- caller running its own timeout (task/dns.lua does). They
		-- complete as nil, which is what unblocks the caller.
		local c = conns[m.connid]

		if c then
			for _, w in ipairs(c.waiting) do
				reply_to(w, nil)
			end
			c.waiting = {}
		end

	elseif m.op == "raw" then
		-- claim a protocol. The right in m.port is kept, not replied
		-- to and not closed: it is where packets go from here on.
		-- Every path that does not keep it closes it, because a right
		-- that arrives in this proc's table and is neither kept nor
		-- closed is one slot of MAXRIGHTS gone until reboot -- which
		-- is the leak this branch has already found in three separate
		-- files.
		local proto = whole(m.proto, 0xff)
		local h = type(m.port) == "table" and m.port.__right or nil

		if not proto or not h then
			if h then
				sys.close(h)
			end
			reply_to(m, false)
			return
		end

		-- icmp and udp are answered here and are not on offer. Letting
		-- a client take udp would not move it, it would silently stop
		-- every udp conn this task is already serving.
		if proto == ip4.PROTO_UDP or proto == ip4.PROTO_ICMP then
			sys.close(h)
			reply_to(m, false)
			return
		end

		if raw[proto] then
			-- a re-registration replaces, which is what a restarted
			-- tcp task needs; the previous owner's right is closed
			-- rather than left behind.
			sys.close(raw[proto])
		end
		raw[proto] = h
		reply_to(m, true)

	elseif m.op == "output" then
		-- one packet, from the proc that owns a protocol. Everything
		-- checked before use, for the reason send's comment gives: a
		-- bad field here would kill the stack, and with it the
		-- network for every other proc on the machine.
		local proto = whole(m.proto, 0xff)

		if not proto or type(m.dst) ~= "string" or #m.dst ~= ip4.LEN or
		    type(m.data) ~= "string" then
			reply_to(m, false)
			return
		end

		local ok, why = host:output(m.dst, proto, m.data)

		if not ok then
			stat.frames_out_fail = stat.frames_out_fail + 1
		elseif why == "held" then
			stat.unresolved = stat.unresolved + 1
		end

		-- the reply is optional here, unlike every op above: reply_to
		-- does nothing when the message carried no reply right, so a
		-- sender that cannot afford a round trip per segment simply
		-- omits it. What it gives up is backpressure, so a task doing
		-- that owes itself a sendwait -- see lib/caps.lua's requester
		-- for why a full queue is worth parking on rather than
		-- spinning through.
		reply_to(m, ok and true or false)

	elseif m.op == "configure" then
		-- only what was named. Assigning m.mask and m.gw
		-- unconditionally meant a caller setting one field silently
		-- lost the others -- a client adjusting its receive buffer
		-- would drop the route it had just been given by dhcp.
		host.ip = m.ip or host.ip
		host.mask = m.mask or host.mask
		host.gw = m.gw or host.gw
		-- the receive budget for conns opened from here on, which is
		-- what SO_RCVBUF is on a unix. Existing conns keep theirs:
		-- changing a buffer under a client that is using it is a
		-- surprise nobody asked for.
		-- and checked, for the same reason as open's port: this is
		-- stored and only used later, in `c.qbytes + n > c.rcvbuf`,
		-- where a string or a table raises inside the RECEIVE path
		-- -- so a bad config would kill the stack on the next frame
		-- to arrive rather than on the request that caused it.
		if m.rcvbuf ~= nil then
			local n = whole(m.rcvbuf, RCVBUF_MAX)

			if not n then
				reply_to(m, false)
				return
			end
			rcvbuf = n
		end
		reply_to(m, true)

	elseif m.op == "config" then
		reply_to(m, { ip = host.ip, mask = host.mask, gw = host.gw,
		    mac = host.mac })

	elseif m.op == "stats" then
		local s = { conns = 0 }

		for k, v in pairs(stat) do
			s[k] = v
		end
		s.queued, s.waiting, s.qbytes, s.conn_dropped = 0, 0, 0, 0
		for _, c in pairs(conns) do
			s.conns = s.conns + 1
			s.queued = s.queued + #c.queue
			s.waiting = s.waiting + #c.waiting
			s.qbytes = s.qbytes + c.qbytes
			s.conn_dropped = s.conn_dropped + c.dropped
		end
		s.rcvbuf = rcvbuf
		-- protocols claimed by another proc. Zero on a machine with
		-- no tcp task, one on a machine with it -- which is the first
		-- thing to check when tcp is silent, since a registration
		-- that never happened and a registration that was dropped
		-- look identical from outside.
		s.raw = 0
		for _ in pairs(raw) do
			s.raw = s.raw + 1
		end
		-- live arp entries: a number that should sit still on a
		-- quiet link and climb on a busy one, and which says
		-- whether expiry is doing anything at all.
		s.arp = arp.count()
		reply_to(m, s)

	else
		reply_to(m, nil)
	end
end

-- ---- the loop ----

local cases = {
	{ port = sys.SELF },
	{ port = framePort },
}

while true do
	local which, m = thread.alt(cases)

	if which == 2 then
		if m and m.data then
			stat.frames_in = stat.frames_in + 1
		end

		local p = m and m.data and host:input(m.data)

		-- input() answers arp and icmp itself; what comes back is a
		-- packet for something above. udp is served in this proc,
		-- everything else is somebody's registered protocol or
		-- nothing at all.
		if p and p.proto == ip4.PROTO_UDP then
			on_udp(p)
		elseif p then
			on_raw(p)
		end
	else
		on_request(m)

		-- a packet sent to ourselves never reached the wire, so
		-- nothing will interrupt to say it arrived: this loop is
		-- the only thing that can collect it, and only right after
		-- the request that produced it. Drained here rather than in
		-- the send op so one request cannot recurse into another.
		while true do
			local p = host:loopnext()

			if not p then
				break
			end
			stat.frames_in = stat.frames_in + 1

			-- the same demux the wire path uses. Handling only udp
			-- here -- which is what the two changes produced when
			-- they were merged, each correct alone -- silently
			-- drops a loopback segment for any protocol served in
			-- another proc, tcp included.
			if p.proto == ip4.PROTO_UDP then
				on_udp(p)
			else
				on_raw(p)
			end
		end
	end
end
