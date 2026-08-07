-- port hangup, the in-flight-right bug it exposed, and the queue ceiling.
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(11)

-- ---- hangup: "am I the only holder?" ----
--
-- our rights make no send/recv distinction in use (api_send never checks
-- r->recv), so "no senders left" is not a question this model can
-- answer. "nobody else holds it" is, and for a pipe it means the same:
-- if no other right exists, nothing can ever write again.
local p = sys.newport("test_hangup")

tap.ok(sys.hungup(p), "a port only I hold is already hungup")

local pid, h = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)

	sys.send(m.w.__right, { op = "write", data = "hello" })
	sys.send(m.w.__right, { op = "write", data = "world" })
]], { name = "writer" })

sys.send(h, { w = { __right = p } })
sys.close(h)
tap.ok(not sys.hungup(p), "not hungup while another proc holds a right")

sys.monitor(pid)
local m

repeat
	m = thread.recv(sys.SELF)
until m.exit == pid

tap.ok(sys.hungup(p), "hungup once that proc exits")

-- hangup means "no more", not "gone": queued data survives
local ok1, d1 = sys.tryrecv(p)
local ok2, d2 = sys.tryrecv(p)

tap.ok(ok1 and d1.data == "hello", "data queued before hangup survives it")
tap.ok(ok2 and d2.data == "world", "in order")
tap.ok(not sys.tryrecv(p), "and then the queue is empty")

-- ---- the bug hangup exposed: an in-flight right is still a right ----
--
-- closing your own copy of a right the instant after sending it used to
-- flush the port. the receiver had not run, so its right was still in
-- the message queue -- counted in nrights but NOT in nrecv -- so nrecv
-- hit zero, the port was declared dead and everything on it was thrown
-- away, while a live receive right was in flight.
local q = sys.newport("test_hangup")
local wpid, wh = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local out = m.out.__right
	local ok, v = sys.tryrecv(m.q.__right)

	sys.send(out, { got = ok and v or "NOTHING" })
]], { name = "late" })

local reply = sys.newport("test_hangup.rep")

sys.send(q, "queued before anyone else holds it")
-- hand the right over and IMMEDIATELY drop ours, before the child runs
sys.send(wh, { q = { __right = q }, out = { __right = reply } })
sys.close(wh)
sys.close(q)

local got = thread.recv(reply)

tap.is(got.got, "queued before anyone else holds it",
    "queue survives the sender closing its right before delivery")

-- ---- the queue ceiling ----
--
-- ports were unbounded, so a fast writer into a slow reader grew the
-- kernel heap without limit -- memory charged to no proc's mem_limit.
--
-- over the ceiling a send REPORTS rather than raising: false plus
-- "full", distinct from false plus "dead". it used to raise, which made
-- the policy decision for every caller -- a pipe writer died at the
-- ceiling instead of applying backpressure. the blocked-on-write proc
-- state this comment used to list as "still to do" is sys.sendblock,
-- and lib/prog.lua's PipeStream:write is the loop built on it.
local big = sys.newport("test_hangup.big")
local chunk = string.rep("x", 8000)
local sent, why = 0, nil

for _ = 1, 200 do
	local okk, w = sys.send(big, chunk)

	if not okk then
		why = w
		break
	end
	sent = sent + 1
end

tap.is(why, "full", "the queue has a ceiling, reported not raised")
tap.ok(sent > 0 and sent < 200,
    "after accepting some but not all (" .. sent .. " of 200)")

-- draining makes room again
sys.tryrecv(big)
tap.ok(sys.send(big, chunk), "draining frees space for another send")

-- and a dead port is a DIFFERENT answer, so a writer can tell "wait"
-- from "give up" -- which is the whole reason the reason string exists
local dead = sys.newport("test_hangup.dea")

sys.close(dead)
local dok, dwhy = pcall(sys.send, dead, "x")

tap.ok(not dok or dwhy == "dead",
    "a dead port reports 'dead', not 'full'")

tap.done()
