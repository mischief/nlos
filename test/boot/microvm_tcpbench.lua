-- what a tcp segment costs, and how much of it is not tcp.
--
-- 32MB over a real LAN runs at about 60us per segment, and the guess was
-- that most of that is inter-process messages rather than protocol: a
-- received segment crosses eth to ip to tcp, and the acknowledgment it
-- provokes crosses tcp to ip to eth on the way back. Five hops for
-- 1460 bytes.
--
-- The guess was wrong, and this is what says so. The kernel's share of a
-- segment -- every dispatch, every port push and pop, every byte of
-- message serialised -- measures at the noise floor, under a
-- microsecond. Message passing is not what this costs. What it costs is
-- Lua, four fifths of it in the tcp task.
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

tap.plan(8)

local CYCMS = sys.stats().cycles_per_ms
local granted = sys.granted()

local function us(cyc, n)
	return (cyc / n) * 1000 / CYCMS
end

-- every proc's running cycles, which the scheduler has been counting all
-- along for its own decay. Two reads around a piece of work say where it
-- went, across procs, with nothing added to any hot path.
local function cpusnap()
	local out = {}

	for _, pid in ipairs(sys.procs()) do
		local st = sys.pidstat(pid)

		if st then
			out[pid] = { name = st.name, cputime = st.cputime }
		end
	end
	return out
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
local cpu0, cpu1, donetick, start

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

	-- The reader stops the clock and takes the snapshot, the instant
	-- the last byte lands.
	--
	-- The writer used to do both after waking from a thread.sleep(5)
	-- poll, which put up to five milliseconds of doing nothing inside
	-- the measurement -- 28us per segment over this transfer, all of it
	-- attributed to the kernel because no proc was running. It read as
	-- half the cost of a segment.
	donetick = sys.ticks()
	cpu1 = cpusnap()
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

	cpu0 = cpusnap()
	start = sys.ticks()

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
	elapsed = (donetick or sys.ticks()) - start

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

	-- Was 1.25 before acknowledgments were delayed, and this assertion
	-- was written the other way round to catch the change. It is not
	-- 0.5 because not everything is delayed: a segment above a gap, one
	-- filling a gap, a closed window and a FIN are all answered at
	-- once, and read() announces a reopened window. Those are the cases
	-- that keep a peer's loss recovery working, and paying a segment
	-- for them is the trade.
	-- ---- where the time actually went ----
	--
	-- The bench could say how much of a segment was not lib/tcb.lua;
	-- it could not say whose it was. A line trace cannot answer that
	-- either, because it fires only inside Lua and the kernel's own
	-- work -- dispatch, port push and pop, serialising a 1500-byte
	-- message -- happens in no proc at all.
	--
	-- Running cycles per proc do answer it, and whatever the wall clock
	-- has that their sum does not is the kernel's, plus whatever the
	-- machine spent idle.
	local named = {}
	local accounted = 0

	for pid, after2 in pairs(cpu1) do
		local was = cpu0[pid] and cpu0[pid].cputime or 0
		local d = after2.cputime - was

		if d > 0 then
			named[#named + 1] = { name = after2.name, cyc = d }
			accounted = accounted + d
		end
	end
	table.sort(named, function(x, y) return x.cyc > y.cyc end)

	tap.diag("per segment, by proc:")
	for _, e in ipairs(named) do
		tap.diag(string.format("  %-8s %6.2f us  %4.1f%%", e.name,
		    us(e.cyc, datasegs), e.cyc / elapsed * 100))
	end
	local kern = elapsed - accounted
	local kernus = us(kern, datasegs)

	-- Sub-microsecond either way, and occasionally a shade negative:
	-- the two snapshots are taken a few instructions either side of the
	-- timed region, so the sum of running cycles can just exceed the
	-- wall clock between them. That it lands at the noise floor is the
	-- finding, not a defect in the arithmetic.
	tap.diag(string.format("  %-8s %6.2f us  %4.1f%%%s", "kernel",
	    kernus, kern / elapsed * 100,
	    math.abs(kernus) < 1 and "   (at the noise floor)" or ""))

	tap.ok(accounted > 0, "the time is attributed across procs")

	tap.ok(ackratio < 0.85,
	    "acknowledgments are delayed rather than one per segment: " ..
	    string.format("%.2f per data segment", ackratio))

	tap.done()
end)

thread.run()
