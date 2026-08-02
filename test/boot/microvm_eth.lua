-- virtio-net: a mac, a frame out, a frame in.
--
-- The proof is an ARP exchange, because it is the smallest thing that
-- needs both directions to work and cannot be faked by loopback: we ask
-- who has the gateway's address, and something off the machine has to
-- answer. Under qemu's user networking that is slirp, at 10.0.2.2.
--
-- Everything above the frame is written here, in Lua, which is the
-- point -- the C side hands over bytes and knows nothing about ARP.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(10)

local caps = sys.granted()

if not tap.ok(caps.eth ~= nil, "an eth capability was granted") then
	tap.diag("no virtio-net device found; the rest cannot run")
	tap.done()
	return
end

local function rpc(msg)
	local reply = sys.newport()

	msg.reply = { __right = sys.sendright(reply) }
	sys.send(caps.eth, msg)
	return thread.recv(reply)
end

-- ---- the mac ----
local r = rpc({ op = "mac" })
local mac = r and r.mac

tap.ok(type(mac) == "string" and #mac == 6,
    "the device reports a 6-byte mac")

if mac then
	tap.diag(string.format("mac %02x:%02x:%02x:%02x:%02x:%02x",
	    mac:byte(1, 6)))
end

-- qemu hands out 52:54:00:... for its own devices; the first octet
-- being even is what makes it a unicast address rather than a multicast
-- one, and a device reporting otherwise is misconfigured.
tap.ok(mac and (mac:byte(1) & 1) == 0,
    "and it is a unicast address")

-- ---- an ARP request ----
local BCAST = string.rep("\255", 6)
local ME = "\10\0\2\15"		-- 10.0.2.15, what slirp leases
local GW = "\10\0\2\2"		-- 10.0.2.2, slirp itself

-- ethernet header + arp payload, by hand. string.pack does the widths;
-- everything here is network byte order, which is what ">" gives.
local function arp_request()
	return BCAST .. mac .. string.pack(">I2", 0x0806) ..
	    string.pack(">I2I2I1I1I2", 1, 0x0800, 6, 4, 1) ..
	    mac .. ME .. string.rep("\0", 6) .. GW
end

-- listen before sending, not after. slirp answers in microseconds, so
-- a listener registered after the request would miss the reply to it.
local frames = sys.newport()
local lr = rpc({ op = "listen", port = { __right = sys.sendright(frames) } })

tap.ok(lr and lr.ok, "the wire accepts a listener")

local sent = rpc({ op = "send", data = arp_request() })

tap.ok(sent and sent.ok, "an arp request goes out on the wire")

-- ---- and the answer ----
-- blocking, not polling: the frame is pushed into our own port, so the
-- proc sleeps until one arrives instead of spinning to learn that none
-- did.
local reply, seen
local deadline = sys.uptime_ms() + 3000

seen = 0
while sys.uptime_ms() < deadline do
	local m = thread.recvtimeout(frames, 200)
	local f = m and m.data

	if f then
		seen = seen + 1
	end

	if f and #f >= 42 and string.unpack(">I2", f, 13) == 0x0806 then
		local op = string.unpack(">I2", f, 21)

		if op == 2 then		-- an ARP reply
			reply = f
			break
		end
	end
end

tap.diag("saw " .. seen .. " frames")

if not tap.ok(reply ~= nil, "an arp reply came back") then
	tap.diag("nothing answered for 10.0.2.2 within 3s")
	tap.done()
	return
end

-- ---- and it is addressed to us, about the address we asked for ----
tap.is(reply:sub(1, 6), mac, "the reply is addressed to our mac")

local sender_mac = reply:sub(23, 28)
local sender_ip = reply:sub(29, 32)

tap.is(sender_ip, GW, "it is from the address we asked about")
tap.ok(sender_mac ~= BCAST and sender_mac ~= string.rep("\0", 6),
    "and carries a real mac for it")
tap.diag(string.format("10.0.2.2 is at %02x:%02x:%02x:%02x:%02x:%02x",
    sender_mac:byte(1, 6)))

-- ---- the line is routed, not just the queue polled ----
--
-- Everything above works whether or not an interrupt ever fires, which
-- is exactly why this needs asserting separately. Until the IOAPIC had
-- a redirection entry -- and until anything did sti at all, which
-- nothing on this platform used to -- the device raised its line into
-- a machine that had masked it, and no driver could tell.
-- Sampled until it moves rather than once. The eth task polls -- its
-- own header says why, and says it is waiting for an interrupt to park
-- on -- so the frame can come out of the used ring before the line is
-- taken, leaving the count at zero at the instant the exchange
-- finishes. The race is in the observation, not the routing.
--
-- A dead line never delivers, so the count stays zero for the whole
-- window and this still fails, which is the case it was written for.
-- What it no longer does is fail because the guest got faster.
--
-- One port for the whole loop, not rpc(): rpc mints a fresh port per
-- call and never closes it, and MAXPORTS is 256 -- so a polling loop
-- built on it runs the machine out of ports and hangs rather than
-- failing. That is a property of rpc, which every other caller here
-- uses a bounded number of times.
local irqs
local irqport = sys.newport()
local irqright = sys.sendright(irqport)
local irqdeadline = sys.uptime_ms() + 500

while sys.uptime_ms() < irqdeadline do
	-- sys.call rather than send-then-recv: this is the send-then-wait
	-- shape it exists for, and one kernel entry instead of two. It
	-- takes the reply port rather than making one, which is why it is
	-- no help with the lifetime problem above -- the port is still
	-- the caller's to own, and here it is owned once for the loop.
	irqs = sys.call(caps.eth,
	    { op = "irqs", reply = { __right = irqright } }, irqport)
	if irqs and irqs.n and irqs.n > 0 then
		break
	end
	sys.yield()
end

tap.diag("virtio interrupts taken: " .. tostring(irqs and irqs.n))
tap.ok(irqs and irqs.n and irqs.n > 0,
    "the device's interrupt reached the cpu")

tap.done()
