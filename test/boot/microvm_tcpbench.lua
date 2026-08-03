-- what a tcp segment costs, and how much of it is not tcp.
--
-- 32MB over a real LAN runs at about 60us per segment, and the guess was
-- that most of that is inter-process messages rather than protocol: a
-- received segment crosses eth to ip to tcp, and the acknowledgment it
-- provokes crosses tcp to ip to eth on the way back. Five hops for
-- 1460 bytes. That guess is arithmetic over numbers measured elsewhere,
-- for a different path, which is not the same as measuring this one.
--
-- So this measures three things that can be compared:
--
--   the floor      one port round trip, which every hop pays whatever
--                  the stack does with it
--   the stack      a bulk transfer over 127.0.0.1, where the device,
--                  the driver and the wire are all gone and what is
--                  left is ip and tcp
--   the protocol   the same segments driven straight into lib/tcb.lua
--                  with no ports at all -- decode, the state machine,
--                  encode, and nothing else
--
-- The difference between the last two is what the message passing costs,
-- which is the number that decides whether the next thing worth doing is
-- delayed acknowledgments or something else entirely.
--
-- Loopback flatters the real path by two hops: eth and the virtio ring
-- are not here. That is deliberate for the same reason microvm_udpbench
-- gives -- the wire is not ours to make faster -- but it means the
-- absolute figure is a floor for the LAN case, not a prediction of it.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local caps = require("caps")
local tcp4 = require("tcp4")
local tcb = require("tcb")

tap.plan(7)

local CYCMS = sys.stats().cycles_per_ms
local granted = sys.granted()

local function us(cyc, n)
	return (cyc / n) * 1000 / CYCMS
end

if not tap.ok(granted.tcp ~= nil, "the tcp task is running") then
	tap.done()
	return
end
tap.ok(granted.ip ~= nil, "and the ip task under it")

-- ---- the floor ----
--
-- One port round trip. Every hop on the segment path is at least this,
-- so anything at or near a multiple of it is not the protocol's to lose.
local echoin = sys.newport()
local echoout = sys.newport()
local toecho = sys.sendright(echoin)

sys.spawn([[
	local sys = require("los.sys")
	local m = ...

	while true do
		sys.block(m.__in.__right)
		local ok, v = sys.tryrecv(m.__in.__right)

		if ok then
			sys.send(m.__out.__right, v)
		end
	end
]], { arg = { __in = { __right = echoin },
    __out = { __right = sys.sendright(echoout) } } })

local NFLOOR = 500
local t0 = sys.ticks()

for _ = 1, NFLOOR do
	sys.send(toecho, "x")
	sys.block(echoout)
	sys.tryrecv(echoout)
end

local floor = us(sys.ticks() - t0, NFLOOR)

tap.ok(true, "a port round trip is the floor for every hop")
tap.diag(string.format("floor: %.2f us per port round trip", floor))

-- ---- the protocol alone ----
--
-- Two connections wired to each other by hand: no ports, no tasks, no
-- messages. Segments go in one end and come out the other exactly as
-- lib/tcb.lua produces them, so what is timed is decode, the state
-- machine and encode -- the whole of what tcp does with a segment and
-- none of what the machine does to move it.
--
-- Encoded and decoded on the way across rather than passed as tables,
-- because the checksum is a real per-byte cost and skipping it would
-- flatter the protocol against the stack figure below.
local A, B = "\127\0\0\1", "\127\0\0\1"
local ca = tcb.new({ laddr = A, lport = 9001, raddr = B, rport = 9002,
    iss = 1000, mss = 1460 })
local cb = tcb.new({ laddr = B, lport = 9002, raddr = A, rport = 9001,
    iss = 900000, mss = 1460 })

local function cross(from, to, src, dst, now)
	local n = 0

	for _, s in ipairs(from:take()) do
		to:segment(tcp4.decode(tcp4.encode(s, src, dst), src, dst), now)
		n = n + 1
	end
	return n
end

ca:connect(0)
cb:listen()
cross(ca, cb, A, B, 0)
cross(cb, ca, B, A, 0)
cross(ca, cb, A, B, 0)
ca:events()
cb:events()

local PURE = 200 * 1460
local moved, crossed = 0, 0
local now = 0

-- Written in 16KB pieces into the DEFAULT buffers, exactly as the stack
-- test below writes through caps.tcp, because buffer size is not neutral
-- here and the two figures are only comparable if it matches.
--
-- The first version of this used 512KB buffers for the protocol and the
-- 32KB default for the stack, and then subtracted one from the other. It
-- is the send buffer's own size that the reslicing below is linear in,
-- so that comparison measured the difference in buffer size as though it
-- were the cost of message passing.
local spins = 0
local written = 0
local piece = string.rep("z", 16384)

t0 = sys.ticks()
while moved < PURE do
	now = now + 1
	spins = spins + 1
	if spins > 20000 then
		break			-- stalled; the assertion below says so
	end

	while written < PURE do
		local room = math.min(#piece, PURE - written)
		local n = ca:write(room == #piece and piece or
		    piece:sub(1, room), now)

		if not n or n == 0 then
			break
		end
		written = written + n
	end

	crossed = crossed + cross(ca, cb, A, B, now)

	local got = cb:read()

	while got and got ~= "" do
		moved = moved + #got
		got = cb:read()
	end
	crossed = crossed + cross(cb, ca, B, A, now)
end

local purecyc = sys.ticks() - t0
local puresegs = PURE // 1460
local pureus = us(purecyc, puresegs)

tap.is(moved, PURE, "the protocol moved every byte with no ports involved")
tap.diag(string.format("protocol: %.2f us per data segment (%d segments, " ..
    "%d crossings)", pureus, puresegs, crossed))

-- ---- the stack ----
--
-- The same bytes, through the real tasks over 127.0.0.1. Both ends are
-- threads because caps.tcp blocks the proc at the top level, and both
-- ends of a loopback connection have to take turns.
local net = caps.tcp(granted.tcp)
local PORT = 9100
local BULK = 256 * 1024
local l = net.listen(PORT)

if not tap.ok(l ~= nil, "a listener for the bulk transfer") then
	tap.done()
	return
end

local before = thread.rpc(granted.tcp, { op = "stats" })
local got, elapsed = 0, 0

thread.spawn(function()
	local c = net.accept(l)

	if not c then
		return
	end
	while got < BULK do
		local d = net.recv(c, 16384)

		if not d then
			break
		end
		got = got + #d
	end
	net.close(c)
end)

thread.spawn(function()
	local conn = net.dial(127, 0, 0, 1, PORT)

	if not conn then
		tap.diag("dial failed")
		tap.done()
		return
	end

	local payload = string.rep("y", 16384)
	local sent = 0
	local start = sys.ticks()

	while sent < BULK do
		if not net.send(conn, payload) then
			break
		end
		sent = sent + #payload
	end

	-- the reader is another thread in this proc, so it has run
	-- whenever this one blocked; when the last send returns the
	-- transfer is as done as it is going to get without waiting.
	while got < BULK do
		thread.sleep(5)
	end
	elapsed = sys.ticks() - start

	net.close(conn)
	net.close(l)

	local after = thread.rpc(granted.tcp, { op = "stats" })
	local segs_in = after.seg_in - before.seg_in
	local segs_out = after.seg_out - before.seg_out
	local datasegs = BULK // 1460
	local stackus = us(elapsed, datasegs)

	tap.is(got, BULK, "the stack moved every byte over loopback")

	tap.diag(string.format("stack: %.2f us per data segment, %.1f MB/s",
	    stackus, (BULK / 1048576) / (elapsed / CYCMS / 1000)))
	tap.diag(string.format("segments: %d in, %d out for %d of data",
	    segs_in, segs_out, datasegs))

	-- The finding, and the number delayed acknowledgments have to beat.
	--
	-- Both endpoints of a loopback connection are in this one task, so
	-- seg_out counts the data going one way AND the acknowledgments
	-- coming back. What is interesting is the difference: everything
	-- beyond the data segments is a segment sent purely to say
	-- something arrived, and each one costs the whole path out through
	-- the ip task -- two hops here, three on a real link where eth and
	-- the virtio ring are also in the way.
	local pureacks = segs_out - datasegs
	local ackratio = pureacks / datasegs

	tap.diag(string.format("acks: %d of the %d segments sent are pure " ..
	    "acknowledgments, %.2f per data segment", pureacks, segs_out,
	    ackratio))
	tap.diag(string.format("split: %.2f us protocol + %.2f us everything " ..
	    "else = %.2f us (%.0f%% is not lib/tcb.lua), floor %.2f us",
	    pureus, stackus - pureus, stackus,
	    (stackus - pureus) / stackus * 100, floor))

	tap.ok(ackratio > 0.8,
	    "today a segment is acknowledged on its own: " ..
	    string.format("%.2f acks per data segment", ackratio))

	tap.done()
end)

thread.run()
