-- IPC throughput and latency: where does the time in a send actually go?
--
-- registered with meson's benchmark(), not test(): it asserts nothing
-- beyond "it ran", and a throughput floor in CI would be flaky on a
-- loaded host. `meson test` skips it; run it deliberately with
--
--   meson test -C build --benchmark        (or: ninja -C build benchmark)
--
-- meson runs benchmarks serially rather than in parallel, which is what
-- makes the numbers comparable between runs.
--
-- timed with sys.ticks() (raw TSC) rather than sys.uptime_ms(), and
-- reported best-of-N. an earlier version used uptime_ms, whose 1ms
-- granularity over a 20ms measurement could not distinguish a 20% change
-- from noise -- which is exactly the size of change worth measuring here.
local sys = require("los.sys")
local thread = require("los.thread")

print("1..1")

local CPMS = sys.stats().cycles_per_ms
local ROUNDS = 5

local function bench(name, sz, iters, fn)
	local best

	for _ = 1, ROUNDS do
		local t0 = sys.ticks()

		fn(sz, iters)

		local d = sys.ticks() - t0

		if not best or d < best then
			best = d
		end
	end

	local cyc = best // iters
	local ns = (cyc * 1000000) // CPMS
	local mbs = (sz * iters) / 1024 / 1024 / (best / CPMS / 1000)

	print(string.format(
	    "# %-18s %6d B  %8d cyc/msg  %8d ns/msg  %8.1f MB/s",
	    name, sz, cyc, ns, mbs))
end

-- ---- same proc: serialize + queue + deserialize, no scheduling ----
local function roundtrip(sz, iters)
	local p = sys.newport("bench_ipc")
	local payload = string.rep("x", sz)

	for _ = 1, iters do
		sys.send(p, payload)
		sys.tryrecv(p)
	end
	sys.close(p)
end

local function roundtrip_empty(_, iters)
	local p = sys.newport("bench_ipc")

	for _ = 1, iters do
		sys.send(p, true)
		sys.tryrecv(p)
	end
	sys.close(p)
end

-- the same round trip with the payload handed over rather than copied.
--
-- A fresh buffer per iteration, because a send empties the handle: what
-- is being compared is a whole message, and the string case allocates
-- its payload once. That makes this the pessimistic reading -- an
-- allocation the string case does not repeat -- and it is still the
-- honest one, since a sender that gives its bytes away has to have got
-- them from somewhere.
local buf = require("los.buf")

local function roundtrip_buf(sz, iters)
	local p = sys.newport("bench_ipc")

	for _ = 1, iters do
		sys.send(p, { __buf = buf.new(sz) })
		sys.tryrecv(p)
	end
	sys.close(p)
end

print("# cycles_per_ms=" .. CPMS .. ", best of " .. ROUNDS)
print("# --- intra-proc (no scheduler involved) ---")
bench("empty (bool)", 1, 20000, roundtrip_empty)
bench("string", 64, 20000, roundtrip)
bench("string", 4096, 5000, roundtrip)
bench("string", 60000, 1000, roundtrip)
bench("buf", 4096, 5000, roundtrip_buf)
bench("buf", 60000, 1000, roundtrip_buf)

-- ---- cross-proc: the same work plus two scheduler wakeups ----
local echo = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local back = m.reply.__right

	while true do
		local v = thread.recv(sys.SELF)

		if v == "done" then
			break
		end
		sys.send(back, v)
	end
]]

-- the echo above hands what it was given straight back, so a buffer
-- has to be wrapped again: what arrives is the receiver's, and sending
-- it on is a second transfer rather than the same one continuing.
local echobuf = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local back = m.reply.__right

	while true do
		local v = thread.recv(sys.SELF)

		if v == "done" then
			break
		end
		sys.send(back, { __buf = v })
	end
]]

local function crossproc_buf(sz, iters)
	local _, h = sys.spawn(echobuf, { name = "echobuf" })
	local rp = sys.newport("bench_ipc.rp")

	sys.send(h, { reply = { __right = rp } })
	for _ = 1, iters do
		sys.send(h, { __buf = buf.new(sz) })
		thread.recv(rp)
	end
	sys.send(h, "done")
	sys.close(rp)
end

local function crossproc(sz, iters)
	local _, h = sys.spawn(echo, { name = "echo" })
	local rp = sys.newport("bench_ipc.rp")

	sys.send(h, { reply = { __right = rp } })

	local payload = string.rep("x", sz)

	for _ = 1, iters do
		sys.send(h, payload)
		thread.recv(rp)
	end
	sys.send(h, "done")
	sys.close(rp)
end

-- the same ping-pong through sys.call: one kernel entry for the client
-- half of the round trip instead of send, return, loop, tryrecv, park.
-- the difference against crossproc above is what the combined call is
-- worth on its own, before any scheduling change -- so run both.
local function crossproc_call(sz, iters)
	local _, h = sys.spawn(echo, { name = "echo" })
	local rp = sys.newport("bench_ipc.rp")

	sys.send(h, { reply = { __right = rp } })

	local payload = string.rep("x", sz)

	for _ = 1, iters do
		sys.call(h, payload, rp)
	end
	sys.send(h, "done")
	sys.close(rp)
end

-- `loop` is the inner round trip, so the send+recv and the sys.call
-- forms differ in exactly one line and nothing else.
local function revdriver(loop)
	return [[
		local sys = require("los.sys")
		local thread = require("los.thread")
		local m = thread.recv(sys.SELF)
		local eh, done, sz, iters = m.eh.__right, m.done.__right,
		    m.sz, m.iters
		local rp = sys.newport("bench_ipc.rp")

		sys.send(eh, { reply = { __right = rp } })

		local payload = string.rep("x", sz)

		for _ = 1, iters do
			]] .. loop .. [[
		end
		sys.send(eh, "done")
		sys.send(done, true)
	]]
end

local revsend = revdriver("sys.send(eh, payload) thread.recv(rp)")
local revcall = revdriver("sys.call(eh, payload, rp)")

-- the same ping-pong, but with the replier at a lower slot index than
-- the driver, which was expected to be the unfavourable ordering: a
-- reply travelling "backwards" past a lap that had already gone by.
-- it is worth about 8%, not the factor it was thought to be, because
-- make_ready puts a woken proc on the current lap and dispatch phase 2
-- picks up anything woken during phase 1. kept because it is still the
-- worst ordering, so it bounds what ordering can cost.
local function crossproc_rev(sz, iters, src)
	local _, eh = sys.spawn(echo, { name = "echo" })
	local _, dh = sys.spawn(src or revsend, { name = "driver" })
	local donep = sys.newport("bench_ipc.donep")

	sys.send(dh, { eh = { __right = eh }, done = { __right = donep },
	    sz = sz, iters = iters })
	sys.close(dh)
	sys.close(eh)
	thread.recv(donep)
	sys.close(donep)
end

print("# --- cross-proc (adds two scheduler wakeups per round trip) ---")
bench("xproc empty", 1, 2000, function(_, n) crossproc(1, n) end)
bench("xproc string", 64, 2000, crossproc)
bench("xproc string", 4096, 2000, crossproc)
bench("xproc string", 60000, 500, crossproc)
bench("xproc buf", 4096, 2000, crossproc_buf)
bench("xproc buf", 60000, 500, crossproc_buf)

print("# --- cross-proc via sys.call (one kernel entry per round trip) ---")
bench("call empty", 1, 2000, function(_, n) crossproc_call(1, n) end)
bench("call string", 64, 2000, crossproc_call)
bench("call string", 4096, 2000, crossproc_call)
bench("call string", 60000, 500, crossproc_call)

print("# --- reversed slot order: replier BELOW the driver ---")
bench("rev empty", 1, 2000, function(_, n) crossproc_rev(1, n) end)
bench("rev string", 4096, 1000, crossproc_rev)
bench("rev call empty", 1, 2000,
    function(_, n) crossproc_rev(1, n, revcall) end)
bench("rev call string", 4096, 1000,
    function(sz, n) crossproc_rev(sz, n, revcall) end)

-- ---- alt: what selecting over several ports costs ----
--
-- the shape every exclusive device task runs (wire, tcp, udp all alt
-- over their own port plus a raw device line), so it is the loop the
-- machine spends its idle time in rather than a corner case.
--
-- two things are separated here because they are fixed by different
-- edits. The CASE TABLE is the caller's: `alt({{port=a},{port=b}})`
-- builds three tables every time round the loop, and the cases never
-- change, so hoisting it out is a call-site fix. What is left is alt's
-- own cost, which is the scan plus -- when nothing is ready -- the
-- plist/marks/waiter allocations inside it.
--
-- both are measured on a port that already has a message, so no park
-- happens and what is timed is the scan and the construction alone.
-- the parking path is measured separately below.
local function alt_inline(_, iters)
	local a, b = sys.newport("bench_ipc"), sys.newport("bench_ipc")

	for _ = 1, iters do
		sys.send(b, true)
		thread.alt({ { port = a }, { port = b } })
	end
	sys.close(a)
	sys.close(b)
end

local function alt_hoisted(_, iters)
	local a, b = sys.newport("bench_ipc"), sys.newport("bench_ipc")
	local cases = { { port = a }, { port = b } }

	for _ = 1, iters do
		sys.send(b, true)
		thread.alt(cases)
	end
	sys.close(a)
	sys.close(b)
end

-- the first case ready rather than the second: alt scans in order and
-- returns on the first hit, so the pair bounds how much the scan itself
-- contributes.
local function alt_first(_, iters)
	local a, b = sys.newport("bench_ipc"), sys.newport("bench_ipc")
	local cases = { { port = a }, { port = b } }

	for _ = 1, iters do
		sys.send(a, true)
		thread.alt(cases)
	end
	sys.close(a)
	sys.close(b)
end

-- ---- alt that actually parks ----
--
-- the path that allocates: plist, marks, and a waiter per channel case,
-- all rebuilt on every trip round alt's inner loop. driven from a
-- thread, because parking is what a thread does differently -- a
-- top-level alt goes to sys.alt instead and never touches marks.
local function alt_park(sz, iters)
	local _, h = sys.spawn(echo, { name = "echo" })
	local rp = sys.newport("bench_ipc.rp")
	local idle = sys.newport("bench_ipc.idle")

	sys.send(h, { reply = { __right = rp } })

	local payload = string.rep("x", sz)
	local cases = { { port = rp }, { port = idle } }

	thread.spawn(function()
		for _ = 1, iters do
			sys.send(h, payload)
			thread.alt(cases)
		end
		sys.send(h, "done")
	end)
	thread.run()
	sys.close(rp)
	sys.close(idle)
end

print("# --- alt: the device-task select loop (nothing parks) ---")
bench("alt inline", 1, 20000, alt_inline)
bench("alt hoisted", 1, 20000, alt_hoisted)
bench("alt first case", 1, 20000, alt_first)

print("# --- alt that parks (cross-proc, from a thread) ---")
bench("alt park", 1, 2000, function(_, n) alt_park(1, n) end)

print("ok 1 - benchmarked")
sys.send(sys.granted().power, { op = "reset", mode = "shutdown" })
