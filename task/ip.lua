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
local inet = require("inet")
local ethwire = require("ethwire")

-- the eth right arrives in the first message, like every other proc
-- that is spawned rather than kernel-registered (see task/dns.lua).
local m0 = thread.recv(sys.SELF)
local ethh = m0.eth.__right

local wire = ethwire.new(ethh)
local host = inet.new(wire, { mac = wire.mac(), ip = ip4.ANY })

-- a receive parked in the eth task, permanently. Its reply port is in
-- the alt below, so this proc sleeps until either a client asks
-- something or a frame arrives -- and the machine sleeps with it.
local framePort = sys.newport()
local parked = false

local function park()
	if parked then
		return
	end
	-- giveright, not a bare sendright: this runs forever, and one
	-- right per frame never closed is a stack that stops receiving.
	sys.send(ethh, { op = "recv", wait = true,
	    reply = thread.giveright(framePort) })
	parked = true
end

-- ---- udp state ----

local conns = {}	-- connid -> {port=}
local nextconn = 1
local nextephem = 32768

-- datagrams that arrived with nobody waiting, per conn. Bounded: a
-- client that stops reading must not grow this task's heap without
-- limit, and dropping the oldest is what a socket buffer does.
local QUEUE_MAX = 8

local function reply_to(m, v)
	local h = type(m.reply) == "table" and m.reply.__right or nil

	if h then
		sys.send(h, v)
		sys.close(h)
	end
end

local function bound(port)
	for id, c in pairs(conns) do
		if c.port == port then
			return id
		end
	end
	return nil
end

-- hand a datagram to whoever is waiting for it, or hold it.
local function deliver(c, msg)
	if #c.waiting > 0 then
		reply_to(table.remove(c.waiting, 1), msg)
		return
	end
	c.queue[#c.queue + 1] = msg
	if #c.queue > QUEUE_MAX then
		table.remove(c.queue, 1)
	end
end

local function on_udp(p)
	local d = udp4.decode(p.payload, p.src, p.dst)

	if not d then
		return
	end

	local id = bound(d.dport)

	if not id then
		return		-- nothing bound; a real host would send an
				-- icmp port-unreachable, which nothing here
				-- yet consumes
	end

	local a, b, c4, d4 = p.src:byte(1, 4)

	deliver(conns[id], { data = d.data, a = a, b = b, c = c4, d = d4,
	    port = d.sport })
end

-- ---- client requests ----

local function on_request(m)
	if m.op == "open" then
		local port = m.port

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
		conns[id] = { port = port, waiting = {}, queue = {} }
		reply_to(m, id)

	elseif m.op == "send" then
		local c = conns[m.connid]

		if not c or type(m.data) ~= "string" then
			reply_to(m, false)
			return
		end

		local dst = string.char(m.a, m.b, m.c, m.d)
		local ok = host:output(dst, ip4.PROTO_UDP,
		    udp4.encode(c.port, m.port, m.data, host.ip, dst))

		-- a send that had to resolve first is reported as failed and
		-- the arp request is on its way, so the caller's own retry
		-- succeeds. Every client above udp already retries, because
		-- udp loses datagrams for less interesting reasons than this.
		reply_to(m, ok and true or false)

	elseif m.op == "recv" then
		local c = conns[m.connid]

		if not c then
			reply_to(m, nil)
			return
		end
		if #c.queue > 0 then
			reply_to(m, table.remove(c.queue, 1))
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

	elseif m.op == "configure" then
		host.ip = m.ip or host.ip
		host.mask = m.mask
		host.gw = m.gw
		reply_to(m, true)

	elseif m.op == "config" then
		reply_to(m, { ip = host.ip, mask = host.mask, gw = host.gw,
		    mac = host.mac })

	else
		reply_to(m, nil)
	end
end

-- ---- the loop ----

while true do
	park()

	local which, m = thread.alt({
		{ port = sys.SELF },
		{ port = framePort },
	})

	if which == 2 then
		parked = false

		local p = m and m.data and host:input(m.data)

		-- input() answers arp and icmp itself; what comes back is a
		-- packet for something above.
		if p and p.proto == ip4.PROTO_UDP then
			on_udp(p)
		end
	else
		on_request(m)
	end
end
