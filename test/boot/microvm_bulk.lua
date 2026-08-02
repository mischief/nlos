-- bulk transfer, in and out, over the lua tcp stack.
--
-- Every other test moves a few kilobytes and asks whether the protocol
-- is right. This asks whether it works: several megabytes in each
-- direction, which is thousands of segments, a window that closes and
-- reopens continuously, and a send buffer that fills and drains. A
-- stack can be perfectly correct on a five-byte echo and fall over on
-- the first transfer big enough to need flow control.
--
-- The far end is test/hostserver.lua, reached through slirp: a guest
-- connecting to 10.0.2.2 is proxied onto the host's loopback. That is
-- deliberately not a machine on anyone's network -- a bulk test that
-- depends on a LAN is a test that fails when a switch is rebooted.
--
-- What arrives is hashed rather than merely counted. A stack that
-- duplicated or dropped a whole segment can still deliver the right
-- number of bytes, and a payload of one repeated character would hide
-- it; the pattern the server sends has period 251 for that reason, and
-- the hash is what actually says the stream was the stream.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local caps = require("caps")
local ip4 = require("ip4")
local sha256 = require("crypto.sha256")

-- rewritten by test/microvm_bulk.lua before injection
local PORT = tonumber("@@PORT@@")
local DOWN = tonumber("@@DOWN@@")
local UP = tonumber("@@UP@@")

tap.plan(9)

local granted = sys.granted()

if not tap.ok(granted.tcp ~= nil, "a tcp capability was granted") then
	tap.done()
	return
end

local cfg
local deadline = sys.uptime_ms() + 10000

repeat
	cfg = granted.ip and thread.rpc(granted.ip, { op = "config" })
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

local net = caps.tcp(granted.tcp)

-- the same pattern test/hostserver.lua generates, so the guest can say
-- what it should have received without being sent it. Its length is a
-- whole number of periods, so repeating the block is the same stream as
-- continuing the pattern -- see hostserver's comment for the version of
-- this that was not, and passed its length check while failing its hash.
local BLOCKLEN = 251 * 261

local function pattern(n)
	local out = {}

	for i = 0, n - 1 do
		out[#out + 1] = string.char(i % 251)
	end
	return table.concat(out)
end

local BLOCK = pattern(BLOCKLEN)

-- the hash of `total` bytes of the stream, computed a block at a time.
-- Building the whole string first would mean a four-megabyte table of
-- one-character strings in a guest with 256MB, to check a transfer that
-- was deliberately never held in memory.
local function expected(total)
	local h = sha256.new()
	local left = total

	while left > 0 do
		local n = math.min(BLOCKLEN, left)

		h:update(n == BLOCKLEN and BLOCK or BLOCK:sub(1, n))
		left = left - n
	end
	return h:final()
end

local function hex(s)
	return (s:gsub(".", function(ch)
		return string.format("%02x", ch:byte())
	end))
end

-- ---- inbound ----

local conn = net.dial(10, 0, 2, 2, PORT)

if not tap.ok(conn ~= nil, "dialled the host's server through slirp") then
	tap.done()
	return
end

net.send(conn, "chargen " .. DOWN .. "\n")

local got = 0
local h = sha256.new()
local t0 = sys.uptime_ms()

while true do
	-- 16KB rather than 4KB: every recv is a message round trip to the
	-- tcp task, and the smaller the ask the more of the transfer is
	-- spent in ipc rather than on the wire. Not 64KB, because MAXMSG
	-- is 64KB and the reply table has to fit inside one.
	local data = net.recv(conn, 16384)

	if not data then
		break
	end
	got = got + #data
	h:update(data)
end

local ms = sys.uptime_ms() - t0

tap.diag(string.format("received %d bytes in %d ms (%.0f KB/s)",
    got, ms, ms > 0 and got / ms or 0))

tap.is(got, DOWN, "every byte of a multi-megabyte download arrives")
tap.is(hex(h:final()), hex(expected(DOWN)),
    "and they are the bytes that were sent, in that order")

net.close(conn)

-- ---- outbound ----
--
-- The other direction, which exercises the send window, the
-- retransmission queue and the send buffer filling -- none of which a
-- download touches.
local up = net.dial(10, 0, 2, 2, PORT)

if not tap.ok(up ~= nil, "dialled again for the upload") then
	tap.done()
	return
end

net.send(up, "discard\n")

-- 16KB a send, not a whole BLOCK. One send is one message, and MAXMSG
-- is 64KB -- a 65511-byte payload plus the table around it does not fit,
-- and the failure is not a refused send but an unserializable message
-- that kills the calling proc. lib/http.lua chunks its response bodies
-- for exactly this reason.
--
-- The content of the upload is not checked: hostserver's discard counts
-- bytes, because what is being measured here is our send path.
local block = BLOCK:sub(1, 16384)
local sent = 0

t0 = sys.uptime_ms()
while sent < UP do
	local n = math.min(#block, UP - sent)
	local piece = n == #block and block or block:sub(1, n)

	if not net.send(up, piece) then
		break
	end
	sent = sent + n
end

-- the close is what tells the server the upload ended, and what makes
-- it report the count back.
net.close(up)
ms = sys.uptime_ms() - t0

tap.diag(string.format("sent %d bytes in %d ms (%.0f KB/s)",
    sent, ms, ms > 0 and sent / ms or 0))
tap.is(sent, UP, "every byte of a multi-megabyte upload is accepted")

local s = thread.rpc(granted.tcp, { op = "stats" })

tap.diag(string.format(
    "seg_in=%d seg_out=%d seg_bad=%d no_conn=%d reset_sent=%d",
    s.seg_in, s.seg_out, s.seg_bad, s.no_conn, s.reset_sent))

-- a segment that would not decode is one the wire damaged or we built
-- wrong, and a client cannot tell those apart. Zero is the only
-- acceptable number over a hundred thousand segments.
tap.is(s.seg_bad, 0, "no segment failed to decode")

local ips = thread.rpc(granted.ip, { op = "stats" })

tap.diag(string.format("frames_in=%d raw_in=%d raw_dropped=%d out_fail=%d",
    ips.frames_in, ips.raw_in, ips.raw_dropped, ips.frames_out_fail))

tap.done()
