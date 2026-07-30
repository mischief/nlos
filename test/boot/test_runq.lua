-- dispatch fairness and wait-list correctness.
--
-- the guarantee: every runnable proc runs at least once and at most once
-- per lap, whatever the priority function computes. it holds because
-- "already had its turn" is membership in a set that dispatch drains,
-- not something derived from priority -- so a policy that is wrong costs
-- ordering and cannot starve anyone.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(10)

-- ---- many procs all make progress, including a low-priority one
-- ---- competing with spinners ----

local N = 20
local rp = sys.newport()
local pids = {}

for i = 1, N do
	local pid = sys.spawn([[
		local sys = require("los.sys")
		local a = ...
		local n = 0

		-- yield in a loop: stays runnable, so every lap must run it
		for _ = 1, 200 do
			n = n + 1
			sys.yield()
		end
		sys.send(a.out.__right, { i = a.i, n = n })
	]], { name = "fair" .. i, arg = { out = { __right = rp }, i = i } })

	pids[#pids + 1] = pid
end

tap.is(#pids, N, "spawned " .. N .. " runnable procs")

-- weight one of them right down and another right up; both must finish
local ok1 = pcall(sys.set_priority, pids[1], 1)
local ok2 = pcall(sys.set_priority, pids[N], 16)

tap.ok(ok1 and ok2, "set extreme weights on two of them")

local seen, rounds = {}, 0
local deadline = sys.uptime_ms() + 15000

while rounds < N and sys.uptime_ms() < deadline do
	local m = thread.recvtimeout(rp, 5000)

	if not m then
		break
	end
	seen[m.i] = m.n
	rounds = rounds + 1
end

tap.is(rounds, N, "every proc finished (" .. rounds .. "/" .. N .. ")")
tap.ok(seen[1] == 200, "the lowest-weight proc completed all its work")
tap.ok(seen[N] == 200, "so did the highest")

local allfull = true

for i = 1, N do
	if seen[i] ~= 200 then
		allfull = false
	end
end
tap.ok(allfull, "none was starved short of its work")

-- ---- a proc woken from an alt leaves every list it was on ----
--
-- a waiter record exists per (proc, port), so an alt puts the proc on
-- several. waking has to remove all of them: a stale entry means a later
-- message to an unrelated port wakes a proc that is not waiting for it,
-- or the pool leaks.

local a, b, c = sys.newport(), sys.newport(), sys.newport()
local arp = sys.newport()
local apid, ah = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local n = 0

	for _ = 1, 3 do
		local i = thread.alt({ { port = m.a.__right },
		    { port = m.b.__right }, { port = m.c.__right } })

		n = n + i
	end
	sys.send(m.rp.__right, { n = n })
]], { name = "altwaiter" })

sys.send(ah, { a = { __right = a }, b = { __right = b },
    c = { __right = c }, rp = { __right = arp } })

for _ = 1, 6 do
	sys.yield()
end

local before = sys.stats().ports

sys.send(c, { x = 1 })
sys.send(a, { x = 1 })
sys.send(b, { x = 1 })

local am = thread.recvtimeout(arp, 8000)

tap.ok(am ~= nil, "the alt waiter answered")
tap.is(am and am.n, 3 + 1 + 2,
    "it woke on each port in turn, so no list held a stale entry: " ..
    tostring(am and am.n))

-- the pool is finite; a leak shows up as blocking forever after enough
-- alts, so run a lot of them and check we still work
-- the waiter pool is finite and a leak would show as blocking forever, so
-- do enough alts to have consumed it several times over
local lrp = sys.newport()
local completed = 0

for round = 1, 40 do
	local p1, p2 = sys.newport(), sys.newport()
	local _, lh = sys.spawn([[
		local sys = require("los.sys")
		local thread = require("los.thread")
		local m = thread.recv(sys.SELF)

		thread.alt({ { port = m.a.__right }, { port = m.b.__right } })
		sys.send(m.rp.__right, { done = true })
	]], { name = "alt" .. round })

	sys.send(lh, { a = { __right = p1 }, b = { __right = p2 },
	    rp = { __right = lrp } })
	sys.close(lh)
	for _ = 1, 2 do
		sys.yield()
	end
	sys.send(p2, { go = true })
	if thread.recvtimeout(lrp, 4000) then
		completed = completed + 1
	end
	sys.close(p1)
	sys.close(p2)
end

tap.is(completed, 40,
    "40 rounds of alt-and-wake all completed, so no waiter leaked (" ..
    completed .. ")")
tap.ok(sys.newport() ~= nil, "and ports still allocate")

tap.done()
