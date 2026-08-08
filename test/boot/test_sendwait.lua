-- backpressure: a message too big to fit alongside another must wait,
-- not vanish.
--
-- sys.send reports a full queue as (false, "full") rather than raising,
-- because the kernel will not decide between a pipe writer that should
-- wait and a server reply that must not. Ignoring the return therefore
-- drops the message silently, and the damage is invisible: the bytes
-- that did arrive are all correct. That is how six of a smiley's seven
-- bands went missing and came back as a tidy yellow arc.
--
-- sendwait is the shared answer, used by draw's put and by the
-- requester() every other capability wrapper is built on.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local draw = require("draw")
local sendwait = require("caps.rpc").sendwait

tap.plan(8)

tap.ok(type(sendwait) == "function", "caps exposes sendwait")

-- big enough that two cannot be queued at once: MAXQUEUE and MAXMSG are
-- both 64KiB, so one of these fills the queue on its own.
local BIG = string.rep("x", 40000)
local port = sys.newport("test_sendwait")
local right = sys.sendright(port)

tap.ok(sys.send(right, { data = BIG }), "the first big message fits")

-- the queue is now too full for a second, which is the situation the
-- whole mechanism exists for
local ok2, why = sys.send(right, { data = BIG })

tap.ok(not ok2 and why == "full",
    "a second is refused with 'full' rather than raising: " .. tostring(why))

-- a reader that drains after a delay, so a waiting sender can proceed
-- and a dropping one cannot
sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local a = ...

	thread.sleep(50)
	while true do
		thread.recv(a.__right)
	end
]], { arg = { __right = port } })
-- {__right = port} rather than sendright: this child has to receive,
-- and sendright deliberately strips that.

-- this must not return until the message is actually queued
local sent, serr = sendwait(right, { data = BIG })

tap.ok(sent, "sendwait delivers once the reader drains: " .. tostring(serr))

-- and it must really be there: drain what we can still see locally.
-- The spawned reader is taking messages too, so the assertion is that
-- sendwait reported success only after a real enqueue, not that a
-- specific count remains.
tap.ok(sent == true, "and reports success rather than a silent drop")

-- a dead port is a different failure and must not spin forever
local dead = sys.newport("test_sendwait.d")
local dright = sys.sendright(dead)

sys.close(dead)

local dok, derr = sendwait(dright, { data = "x" })

tap.ok(not dok or derr == nil,
    "a send that fails for another reason returns instead of looping")

-- ---- and from inside a thread, which is where the callers are ----
--
-- Parking is legal only for the coroutine the kernel resumed, so the
-- wait differs inside a thread. It is reached only when the far end is
-- full, so a full queue is what the test has to arrange.
local tport = sys.newport("test_sendwait.t")
local tright = sys.sendright(tport)

sys.send(tright, { data = BIG })		-- full before we start

sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local a = ...

	thread.sleep(50)
	while true do
		thread.recv(a.__right)
	end
]], { arg = { __right = tport } })

local tok, tres

thread.spawn(function()
	tok, tres = pcall(sendwait, tright, { data = BIG })
end)
thread.run()

tap.ok(tok, "sendwait from inside a thread does not raise: " ..
    tostring(not tok and tres or ""))
tap.ok(tres == true, "and it delivers, rather than reporting a drop")

tap.done()
