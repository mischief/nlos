-- the microvm platform runs ordinary lua-os code: the embedded libs
-- (src/thread.c, lib/cons.lua, lib/stdout.lua -- see fs.c) mean this
-- boot payload, proc 0 at PRIV_BOOT, reaches the console through
-- sys.granted().cons and print() like anything else, rather than the
-- raw los.platform.cons only the cons task itself may touch.
--
-- what it is actually for: two procs interleave rather than one running
-- to completion, so kernel.c's scheduler works here unchanged.
--
-- Not preemption, despite what this comment used to claim. The children
-- below call sys.yield(), so the interleaving is cooperative and would
-- happen with no timer at all -- which is what it was doing, since
-- interrupts were globally masked on this platform until an sti was
-- added with the ioapic work. Proving preemption needs a child that
-- never yields, and that test does not exist.

local sys = require("los.sys")
local tap = require("tap")

tap.plan(5)

local myright = sys.sendright(0)

local childcode = [[
	local sys = require("los.sys")
	local parent = (...).__right
	for i = 1, 6 do
		sys.send(parent, string.format("child %d tick %d", sys.self(), i))
		sys.yield()
	end
]]

local a = sys.spawn(childcode, { arg = { __right = myright } })
local b = sys.spawn(childcode, { arg = { __right = myright } })

tap.ok(a and b, "two children spawned")

-- order of arrival is the evidence. one child running to completion
-- before the other starts would still deliver all 12 messages, so
-- counting them proves nothing on its own -- the interleaving does.
local got, order = 0, {}

while got < 12 do
	local ok, msg = sys.tryrecv(0)

	if ok then
		order[#order + 1] = tonumber(msg:match("^child (%d+)"))
		got = got + 1
	else
		sys.yield()
	end
end

tap.ok(got == 12, "all 12 messages arrived")

local seen, switches = {}, 0

for i, pid in ipairs(order) do
	seen[pid] = (seen[pid] or 0) + 1
	if i > 1 and pid ~= order[i - 1] then
		switches = switches + 1
	end
end

local pids = {}
for pid in pairs(seen) do
	pids[#pids + 1] = pid
end

tap.ok(#pids == 2, "both children were heard from, not just one")
tap.ok(seen[pids[1]] == 6 and seen[pids[2]] == 6,
    "each child sent exactly its six")

-- a run-to-completion scheduler gives exactly one switch. anything
-- preempting gives many.
--
-- Only on one cpu. Arrival order is evidence of interleaving only
-- while there is one queue to interleave in: with two cpus the
-- children run at the same time on different ones, each yielding to an
-- empty queue and returning at once, so its six sends land in a burst
-- and the order says nothing about whether they overlapped. Asserting
-- it there would be asserting that smp does not work.
--
-- What still holds on any machine is that both ran and both finished,
-- and the two assertions above check that.
tap.diag("child switches in the message order: " .. switches)
if sys.stats().cpus > 1 then
	tap.ok(true, "interleaving is a uniprocessor question, not asked here")
else
	tap.ok(switches > 1,
	    "the two children interleaved rather than ran in turn")
end

tap.done()
