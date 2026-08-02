-- what the ip task does when a client stops reading.
--
-- The interesting case is not that datagrams are dropped -- something
-- has to be, since a stack cannot buffer without limit for a proc that
-- has wandered off -- but WHICH. Dropping the oldest hands a slow
-- reader the newest datagrams and loses the ones it was waiting for,
-- which for every request/reply protocol above udp is exactly the wrong
-- ones: the reply you are blocked on is the oldest unread. So the
-- arrival is what loses, the prefix stays intact, and this checks that
-- rather than merely checking that the count stopped growing.
--
-- Driven with DNS because it is a request/reply protocol that answers
-- promptly and is already known to work here: send several queries
-- without reading any replies, then read.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local caps = require("caps")
local dns = require("dns")
local ip4 = require("ip4")
local dhcp = require("dhcp")
local ether = require("ether")

tap.plan(8)

local granted = sys.granted()
local iph = granted.ip

if not tap.ok(iph ~= nil, "the ip task is running") then
	tap.done()
	return
end

local udp = caps.udp(iph)

-- wait for the machine's own dhcp client rather than running a second
-- one. Only one thing may hold port 68, and task/dhcpd.lua is already
-- holding it -- which is the correct arrangement and not an obstacle:
-- a client wanting the network waits for the address, it does not go
-- and get its own.
local cfg
local deadline = sys.uptime_ms() + 8000

repeat
	cfg = thread.rpc(iph, { op = "config" })
	if cfg and cfg.ip and cfg.ip ~= ip4.ANY then
		break
	end
	thread.sleep(200)
until sys.uptime_ms() > deadline

if not tap.ok(cfg and cfg.ip and cfg.ip ~= ip4.ANY,
    "the machine configured itself") then
	tap.done()
	return
end

-- ---- shrink the receive budget, then overrun it ----
--
-- rcvbuf is this task's SO_RCVBUF: a real setting rather than a test
-- hook, and the only way to make an overrun happen deliberately without
-- sending a megabyte through somebody's resolver.
--
-- Small enough that the second reply will not fit beside the first: a
-- dns reply for this name is comfortably over 40 bytes.
thread.rpc(iph, { op = "configure", rcvbuf = 80 })

local conn = udp.open(0)

tap.ok(conn ~= nil, "opened a conn with a small receive buffer")

-- slirp's resolver, by its documented address. The ip task's config
-- carries the address and the route and not this: what a lease said
-- about dns belongs in /net, which task/dhcpd.lua serves and nothing
-- mounts here yet. A literal is honest in a test that already asserts
-- slirp's own 10.0.2.15.
local resolver = "10.0.2.3"
local NQUERIES = 4
local a, b, c, d = tostring(resolver):match("(%d+)%.(%d+)%.(%d+)%.(%d+)")

if not tap.ok(a ~= nil, "we have a gateway to ask: " .. tostring(resolver)) then
	tap.done()
	return
end

-- warm the arp cache before the burst.
--
-- Host:output drops a packet whose destination it has no mac for and
-- sends an arp request instead, so the FIRST datagram to a new peer is
-- always lost -- and a burst issued back to back is all first, since
-- the task cannot process the arp reply until it returns to its loop.
-- A real client rediscovers this as "the first request always times
-- out"; here it would have meant testing the queue with nothing in it.
udp.send(conn, tonumber(a), tonumber(b), tonumber(c), tonumber(d),
    dns.PORT, dns.build_query("example.com", 0x99))
thread.sleep(400)

-- and drain whatever the warm-up put there, so the queue is empty when
-- the burst starts and the survivor below is unambiguously the burst's
-- first and not this one's.
local warm = thread.rpc(iph, { op = "stats" })

for _ = 1, warm.queued do
	udp.recv(conn, 4096)
end

for i = 1, NQUERIES do
	-- distinct ids, so the replies are distinguishable and none is a
	-- retransmit of another.
	udp.send(conn, tonumber(a), tonumber(b), tonumber(c), tonumber(d),
	    dns.PORT, dns.build_query("example.com", 0x100 + i))
	-- deliberately no recv: the point is to let them pile up.
end

-- give the resolver time to answer all of them into a buffer that
-- cannot hold them.
thread.sleep(1500)

local st = thread.rpc(iph, { op = "stats" })

tap.diag(string.format(
    "udp_in=%d unbound=%d queued=%d qbytes=%d dropped=%d " ..
    "out_fail=%d unresolved=%d rcvbuf=%d conns=%d",
    st.udp_in, st.udp_unbound, st.queued, st.qbytes, st.conn_dropped,
    st.frames_out_fail, st.unresolved, st.rcvbuf, st.conns))

tap.ok(st.udp_in >= 2, "several replies came back")

-- the budget held: what is queued fits in it, and the rest was refused
-- rather than displacing what was already there.
tap.ok(st.qbytes <= 80, "the queue stayed inside its byte budget")

tap.ok(st.conn_dropped > 0, "and the overflow was counted, not silent")

-- ---- and the prefix survived ----
--
-- The first reply must still be there. It is the one a blocked client
-- would have been waiting for, and the one a drop-oldest policy would
-- have thrown away first.
-- a blocking recv on an empty queue would park forever, so only ask
-- for what the stats say is there.
local first = st.queued > 0 and udp.recv(conn, 4096) or nil
local addr = first and dns.parse(first.data, 0x101)

tap.ok(addr ~= nil,
    "the oldest reply is the one still in the queue: " .. tostring(addr))

tap.done()
