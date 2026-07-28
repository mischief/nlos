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
	local p = sys.newport()
	local payload = string.rep("x", sz)

	for _ = 1, iters do
		sys.send(p, payload)
		sys.tryrecv(p)
	end
	sys.close(p)
end

local function roundtrip_empty(_, iters)
	local p = sys.newport()

	for _ = 1, iters do
		sys.send(p, true)
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

local function crossproc(sz, iters)
	local _, h = sys.spawn(echo, { name = "echo" })
	local rp = sys.newport()

	sys.send(h, { reply = { __right = rp } })

	local payload = string.rep("x", sz)

	for _ = 1, iters do
		sys.send(h, payload)
		thread.recv(rp)
	end
	sys.send(h, "done")
	sys.close(rp)
end

-- the SAME ping-pong, but with the replier at a LOWER slot index than
-- the driver. our dispatch scans slots in order, so a reply travelling
-- "backwards" has already been passed this lap and waits for the next
-- one. that is precisely the case a handoff hint is supposed to fix, and
-- the case above (boot payload drives a proc spawned after it) is the
-- favourable ordering where it cannot help.
local function crossproc_rev(sz, iters)
	local _, eh = sys.spawn(echo, { name = "echo" })
	local dpid, dh = sys.spawn([[
		local sys = require("los.sys")
		local thread = require("los.thread")
		local m = thread.recv(sys.SELF)
		local eh, done, sz, iters = m.eh.__right, m.done.__right,
		    m.sz, m.iters
		local rp = sys.newport()

		sys.send(eh, { reply = { __right = rp } })

		local payload = string.rep("x", sz)

		for _ = 1, iters do
			sys.send(eh, payload)
			thread.recv(rp)
		end
		sys.send(eh, "done")
		sys.send(done, true)
	]], { name = "driver" })
	local donep = sys.newport()

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

print("# --- reversed slot order: replier BELOW the driver ---")
bench("rev empty", 1, 2000, function(_, n) crossproc_rev(1, n) end)
bench("rev string", 4096, 1000, crossproc_rev)

print("ok 1 - benchmarked")
sys.send(sys.granted().power, { op = "reset", mode = "shutdown" })
