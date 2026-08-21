-- loopbench: the same stack with no radio under it.
--
-- Both ends of one connection live in this program and talk over
-- 127.0.0.1, so segments cross task/tcp4.lua and task/ip.lua exactly as
-- they do off the wire, and nothing else is in the path. What netbench
-- costs over the same bytes, minus what this costs, is the radio.

local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")

local net = assert(prog.net(), "loopbench: no network capability")
local CPMS = sys.stats().cycles_per_ms
local TOTAL = tonumber(arg and arg[1]) or 256 * 1024
local CHUNK = 1460
local PORT = 9099
local block = string.rep("x", CHUNK)

local function cputimes()
	local t = {}

	for _, pid in ipairs(sys.procs()) do
		local st = sys.pidstat(pid)

		t[pid] = { name = st.name, cpu = st.cputime }
	end
	return t
end

local lid = assert(net.listen(PORT), "loopbench: cannot listen")
local sent, got = 0, 0
local before, t0

thread.spawn(function()
	local c = assert(net.accept(lid), "loopbench: accept failed")

	while sent < TOTAL do
		if not net.send(c, block) then
			break
		end
		sent = sent + CHUNK
	end
	net.close(c)
end)

thread.spawn(function()
	local c = assert(net.dial(127, 0, 0, 1, PORT), "loopbench: dial failed")

	before = cputimes()
	t0 = sys.ticks()
	while got < TOTAL do
		local d = net.recv(c, 4096)

		if not d or #d == 0 then
			break
		end
		got = got + #d
	end
	net.close(c)
end)

thread.run()

local d = sys.ticks() - t0
local after = cputimes()
local ms = d / CPMS

-- both directions cross the stack, so the rate a one-way transfer
-- would see over the same work is about twice this.
print(string.format("%d bytes in %.0f ms = %.1f KB/s each way", got, ms,
    got * 1000 / ms / 1024))

local rows = {}

for pid, a in pairs(after) do
	local b = before[pid]
	local dt = a.cpu - (b and b.cpu or 0)

	if dt > 0 then
		rows[#rows + 1] = { name = a.name, ms = dt // CPMS }
	end
end
table.sort(rows, function(x, y) return x.ms > y.ms end)
for _, r in ipairs(rows) do
	print(string.format("  %-10s %6d ms %3d%%", r.name, r.ms,
	    r.ms * 100 // math.max(ms, 1)))
end
