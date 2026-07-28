-- IPC throughput: where does the time in a send actually go?
--
-- registered with meson's benchmark(), not test(): it asserts nothing
-- beyond "it ran", and a throughput floor in CI would be flaky on a
-- loaded host. `meson test` skips it; run it deliberately with
--
--   meson test -C build --benchmark        (or: ninja -C build benchmark)
--
-- meson runs benchmarks serially rather than in parallel, which is what
-- makes the numbers worth comparing between runs. read them from the
-- TAP diagnostics with --print-errorlogs, or from meson-logs/.
--
-- what it showed when written (see docs/uefi-notes.md for the machine):
-- intra-proc bulk runs ~1 GB/s and cross-proc ~470 MB/s at 60KB, while
-- an empty round trip is ~0.3us intra and ~11us cross. so small
-- messages are dominated by per-message and scheduler cost, not by
-- payload copying, and bulk transfer is not close to being a
-- bottleneck for anything this system does.
local sys = require("los.sys")
local thread = require("los.thread")

print("1..1")

local function bench(name, sz, iters, fn)
	local t0 = sys.uptime_ms()
	fn(sz, iters)
	local ms = sys.uptime_ms() - t0
	local bytes = sz * iters
	local mbs = ms > 0 and (bytes / 1024 / 1024) / (ms / 1000) or 0
	print(string.format("# %-22s %6d B x %5d = %7.2f MB in %5d ms -> %6.1f MB/s  (%.3f ms/msg)",
	    name, sz, iters, bytes / 1024 / 1024, ms, mbs, ms / iters))
end

-- ---- same proc: pure serialize + queue + deserialize, no scheduling ----
local function roundtrip(sz, iters)
	local p = sys.newport()
	local payload = string.rep("x", sz)
	for _ = 1, iters do
		sys.send(p, payload)
		sys.tryrecv(p)
	end
	sys.close(p)
end

-- ---- empty messages: isolates per-message overhead from payload cost ----
local function roundtrip_empty(_, iters)
	local p = sys.newport()
	for _ = 1, iters do
		sys.send(p, true)
		sys.tryrecv(p)
	end
	sys.close(p)
end

print("# --- intra-proc (serialize + queue + deserialize, no scheduler) ---")
bench("empty (bool)", 1, 20000, roundtrip_empty)
bench("string", 64, 20000, roundtrip)
bench("string", 4096, 5000, roundtrip)
bench("string", 16384, 2000, roundtrip)
bench("string", 60000, 1000, roundtrip)

-- ---- cross-proc: adds scheduler laps to the same work ----
local echo = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local back = m.reply.__right
	while true do
		local v = thread.recv(sys.SELF)
		if v == "done" then break end
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

print("# --- cross-proc (same, plus two scheduler wakeups per round trip) ---")
bench("xproc string", 64, 2000, crossproc)
bench("xproc string", 4096, 2000, crossproc)
bench("xproc string", 60000, 500, crossproc)

print("ok 1 - benchmarked")
sys.send(sys.granted().power, { op = "reset", mode = "shutdown" })
