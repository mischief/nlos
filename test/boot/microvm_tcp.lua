-- tcp in lua, against something that is not us.
--
-- Everything under this has been tested sans-io: lib/tcp4.lua against a
-- checksum written elsewhere, lib/tcb.lua against another copy of
-- itself. Neither can catch the class of bug where we and the RFC agree
-- and the rest of the world does not. This can: the far side is qemu's
-- slirp, and the echo server behind it is an ordinary `cat` joined to
-- the stream by guestfwd.
--
-- The other thing it proves is the seam. A segment leaving here crosses
-- task/tcp4.lua, task/ip.lua, task/eth.lua and the virtio ring, and
-- comes back the same way -- and the capability the client holds is the
-- one lib/caps.lua hands to lib/http.lua and task/sshd.lua on a machine
-- with firmware. Nothing in this file knows which stack answered it.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local caps = require("caps")
local ip4 = require("ip4")

tap.plan(14)

local granted = sys.granted()
local tcph = granted.tcp
local iph = granted.ip

if not tap.ok(tcph ~= nil, "a tcp capability was granted") then
	tap.diag("no tcp task; the rest cannot run")
	tap.done()
	return
end

tap.ok(iph ~= nil, "and the ip task it is built on is running")

-- the client sees lib/caps.lua's wrapper and nothing else. On the efi
-- platform the identical call reaches the firmware's EFI_TCP4.
local net = caps.tcp(tcph)

-- wait for the machine's own dhcp client rather than configuring
-- anything: a client wanting the network waits for the address.
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

tap.diag("we are " .. ip4.str(cfg.ip))

-- ---- a connection that is refused ----
--
-- First, because it is the one that must not hang. slirp answers a SYN
-- to a port with nothing behind it with a reset, and a dial that cannot
-- tell a refusal from a silence is one that blocks a client for its
-- whole timeout on every closed port.
local refused = net.dial(10, 0, 2, 2, 9)

tap.ok(refused == nil, "dialing a closed port is refused, not hung")

-- ---- a connection that works ----
--
-- 10.0.2.100:7 is the guestfwd address; the process behind it is `cat`.
local conn = net.dial(10, 0, 2, 100, 7)

if not tap.ok(conn ~= nil, "a dial to the echo server completes") then
	local s = thread.rpc(tcph, { op = "stats" })

	if s then
		tap.diag(string.format(
		    "dialed=%d refused=%d seg_in=%d seg_out=%d seg_bad=%d " ..
		    "no_conn=%d", s.dialed, s.refused, s.seg_in, s.seg_out,
		    s.seg_bad, s.no_conn))
	end
	tap.done()
	return
end

tap.diag("connid " .. tostring(conn))

-- ---- data ----

tap.ok(net.send(conn, "hello") == true, "a write is accepted")

-- recv returns whatever has arrived, which for a stream need not be the
-- whole of what was sent -- so this reads until it has enough rather
-- than assuming one segment carries one write. A test that assumed
-- otherwise would pass here and fail on a busier link, which is the
-- worst way for it to fail.
local function readn(n, ms)
	local buf = ""
	local stop = sys.uptime_ms() + (ms or 5000)

	while #buf < n and sys.uptime_ms() < stop do
		local d = net.recv(conn, 4096)

		if d == nil then
			return buf, "eof"
		end
		buf = buf .. d
	end
	return buf
end

tap.is(readn(5), "hello", "and comes back the way it went")

-- again, so that a connection that works exactly once is not mistaken
-- for one that works.
tap.ok(net.send(conn, "second") == true, "a second write is accepted")
tap.is(readn(6), "second", "and echoes too")

-- ---- more than one segment ----
--
-- The peer advertised an mss, and 4000 bytes is several segments'
-- worth. This is where sequence numbers, the send window and in-order
-- delivery all have to be right at once, and where a stack that works
-- for one small write stops working.
local big = string.rep("abcdefghij", 400)

tap.ok(net.send(conn, big) == true, "four thousand bytes are accepted")

local back = readn(#big, 10000)

tap.is(#back, #big, "and all of them come back")
tap.ok(back == big, "in the order they were sent")

local s = thread.rpc(tcph, { op = "stats" })

tap.diag(string.format(
    "dialed=%d refused=%d seg_in=%d seg_out=%d seg_bad=%d no_conn=%d " ..
    "reset_sent=%d conns=%d",
    s.dialed, s.refused, s.seg_in, s.seg_out, s.seg_bad, s.no_conn,
    s.reset_sent, s.conns))

-- a segment we could not decode is a segment the wire damaged or we
-- built wrong, and the two are indistinguishable from a client. Zero is
-- the only acceptable number here.
tap.is(s.seg_bad, 0, "no segment failed to decode")

net.close(conn)

-- close aborts today rather than closing gracefully -- there is no FIN
-- in the sending half yet -- so what is asserted is that the connection
-- is gone, not how politely.
thread.sleep(200)
local after = thread.rpc(tcph, { op = "stats" })

tap.is(after.conns, 0, "and closing lets go of the connection")

tap.done()
