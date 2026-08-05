-- N procs each doing a fixed amount of pure computation, then exit.
--
-- The payload is deliberately dull: no messages after the start, no
-- io, nothing that touches a shared structure. What is being measured
-- is whether two cpus run lua at the same time, and any shared work in
-- here would measure the lock instead.
--
-- It reports nothing useful by itself. The measurement is the wall
-- clock of the whole boot, taken by the host, at one cpu against two --
-- which is the only place it can be taken from. See AGENTS.md on why:
-- "whether the kernel reaches its idle sleep is not [observable from
-- inside] ... verified from outside by qemu CPU time. Prefer an honest
-- external measurement over an assertion that cannot fail."

local sys = require("los.sys")
local tap = require("tap")

tap.plan(2)

local NPROC = 4
local ROUNDS = 4000000

local me = sys.sendright(0)
local kids = {}

for i = 1, NPROC do
	kids[i] = sys.spawn([[
		local sys = require("los.sys")
		local a = ...
		local parent = a.reply.__right
		local rounds = a.rounds
		-- integer work, no allocation: an allocating loop would
		-- measure the per-proc heap rather than the scheduler.
		local home = sys.pidstat().home
		local acc = 0
		for j = 1, rounds do
			acc = (acc + j * 2654435761) % 4294967296
		end
		sys.send(parent, tostring(home))
	]], { arg = { reply = { __right = me }, rounds = ROUNDS } })
end

tap.ok(#kids == NPROC, NPROC .. " spinners spawned")

local got = 0
local homes = {}

while got < NPROC do
	local ok, msg = sys.tryrecv(0)
	if ok then
		got = got + 1
		-- each spinner reports its own home, taken while it was
		-- alive. Counting sys.procs() at the end instead counts
		-- only the survivors -- the boot drivers, all placed
		-- before any AP was dispatching -- and reported cpu0=4
		-- on a machine that was in fact spreading them.
		local h = tonumber(msg) or 0
		homes[h] = (homes[h] or 0) + 1
	else
		sys.yield()
	end
end

tap.ok(got == NPROC, "all " .. NPROC .. " finished")

-- where they ran, which says whether placement spread them at all. Not
-- an assertion: on one cpu the only right answer is that they all
-- share it.
local parts = {}
for cpu, n in pairs(homes) do
	parts[#parts + 1] = string.format("cpu%d=%d", cpu, n)
end
table.sort(parts)
tap.diag("procs by home: " .. table.concat(parts, " "))
local st = sys.stats()

tap.diag("cpus: " .. tostring(st.cpus))
for i, c in ipairs(st.cpu or {}) do
	tap.diag(string.format("cpu%d: apicid=%d dispatching=%s laps=%d dispatched=%d idles=%d",
		i - 1, c.apicid, tostring(c.dispatching), c.laps, c.dispatched, c.idles))
end

tap.done()
