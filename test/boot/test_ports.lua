-- sys.ports(): per-port counters, and the two ways a send is refused.
--
-- The counters exist because the kernel is the only place that can see
-- a refusal. A task counting its own failed sends learns about its own,
-- and every other drop in the system stays invisible -- which is how a
-- full queue comes to look exactly like a fast reader from the outside.
--
-- full and dead are counted apart on purpose. A full queue is a reader
-- that fell behind and will likely catch up; a dead one is a receive
-- right closed while someone was still sending, which is a lifecycle
-- bug and never resolves on its own.

local sys = require("los.sys")
local tap = require("tap")

tap.plan(12)

-- a handle is not a port index -- handles are per-proc and the index is
-- what the port is called kernel-wide -- and nothing in sys maps one to
-- the other. So a port is identified here by being the one that was not
-- in the list a moment ago.
local function indices()
	local seen = {}

	for _, r in ipairs(sys.ports()) do
		seen[r.port] = true
	end
	return seen
end

local function newport_watched()
	local before = indices()
	local h = sys.newport()
	local idx

	for _, r in ipairs(sys.ports()) do
		if not before[r.port] then
			idx = r.port
			break
		end
	end
	return h, idx
end

local function row(idx)
	for _, r in ipairs(sys.ports()) do
		if r.port == idx then
			return r
		end
	end
	return nil
end

-- ---- the shape ----
local all = sys.ports()

tap.ok(type(all) == "table" and #all > 0, "sys.ports() lists live ports")

local first = all[1]

tap.ok(type(first) == "table" and type(first.port) == "number" and
    type(first.qbytes) == "number" and type(first.sent) == "number",
    "and each row carries a port index and its counters")

-- our own port is a live one with a receive right, and this proc holds
-- it, so it has to be findable and owned by us.
local me, meidx = newport_watched()
local mine = row(meidx)

tap.ok(mine ~= nil, "a freshly created port appears in the list")
tap.is(mine and mine.owner, sys.self(), "and is owned by the proc that made it")
tap.ok(mine and mine.recv >= 1, "and holds a receive right")

-- ---- sent, and the queue high-water ----
local sr = sys.sendright(me)

tap.ok(sys.send(sr, "one"), "a message goes onto the queue")
tap.is(row(meidx).sent, 1, "and is counted as sent")

tap.ok(row(meidx).qbytes > 0, "the queue reports its depth")

-- drain it: qbytes falls back but qpeak must not, which is the whole
-- reason qpeak is recorded. A port sampled after it drained looks idle
-- however bad it got.
local deep = row(meidx).qpeak

sys.tryrecv(me)
tap.ok(row(meidx).qbytes == 0 and row(meidx).qpeak == deep,
    "and after draining, qbytes falls but qpeak stays")

-- ---- refused: full ----
-- push until the kernel says no. MAXQUEUE is 64KiB, so this is bounded
-- well under a second even with the payload this size.
local blob = string.rep("x", 4096)
local ok, why

repeat
	ok, why = sys.send(sr, blob)
until not ok

tap.is(why, "full", "a queue that reached MAXQUEUE refuses the send")
tap.ok(row(meidx).dropfull >= 1, "and the refusal is counted against the port")

-- ---- refused: dead ----
-- closing the receive right kills the port while the send right keeps
-- it alive, which is exactly the shape of the bug this counter is for.
local dead, deadidx = newport_watched()
local dsr = sys.sendright(dead)

sys.close(dead)
sys.send(dsr, "nobody home")

local drow = row(deadidx)

tap.ok(drow and drow.dead and drow.dropdead >= 1,
    "a send to a port whose receiver hung up is counted as dead")

tap.done()
