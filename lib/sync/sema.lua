-- sync.sema: at most N threads inside something at once.
--
-- ---- the failure this exists to prevent ----
--
-- A server that spawns a thread per request has to stop somewhere. Not
-- spawning past a window is easy to write and easy to write wrongly:
-- the count and the wait have to agree, and the natural mistake is a
-- worker that cannot hand its slot back because the queue it hands it
-- to is full, which deadlocks it against the loop waiting for a slot.
-- lib/srv.lua's window carries a comment about exactly that.
--
-- The other half is that a counter alone will not do it. `if n <
-- limit then n = n + 1` is fine as far as it goes -- a thread is not
-- switched away from between the test and the store -- but the WAIT
-- when the window is full has to park, and a thread that parks on the
-- wrong thing wakes on the wrong thing.
--
-- ---- what it does ----
--
--	local sema = require("sync.sema")
--	local slots = sema.new(8)
--
--	slots:acquire()
--	thread.spawn(function()
--		serve(m)
--		slots:release()
--	end)
--
-- The tokens ARE the permits: a channel holding N of them, so acquire
-- is a receive and release is a send. There is no count to keep in
-- agreement with anything, and no way to be inside without holding
-- one. Waiting is the channel's waiting, which is the same park every
-- other thread in the system uses.
--
-- release() without a matching acquire() RAISES rather than quietly
-- widening the window. Handing back a permit that was never taken is
-- how a bounded thing stops being bounded, and it is worth hearing
-- about at the point it happens.
--
-- Nothing records WHICH thread holds a permit, so one thread may
-- acquire and another release. That is deliberate -- the srv shape
-- above does exactly that, taking a slot in the accept loop and giving
-- it back in the worker -- and it is why this is a semaphore rather
-- than a lock. If you want a thread to hold something for a stretch
-- and give it back itself, see sync.lock.
--
-- IN-PROCESS ONLY. Channels live in one lua_State, so this bounds the
-- threads of one proc and nothing else. Two procs sharing a limit is a
-- different problem: give one of them the resource and let the other
-- ask it.

local thread = require("los.thread")

local Sema = {}

Sema.__index = Sema

local function new(n)
	local q = thread.chancreate(n)

	for _ = 1, n do
		q:nbsend(true)
	end
	return setmetatable({ q = q, n = n }, Sema)
end

-- take a permit, waiting for one if none is free.
function Sema:acquire()
	self.q:recv()
end

-- take a permit only if one is free. Returns whether it got one.
function Sema:tryacquire()
	return (self.q:nbrecv())
end

function Sema:release()
	if not self.q:nbsend(true) then
		error("sync.sema: release without acquire", 2)
	end
end

-- how many permits are free right now. For diagnostics -- anything
-- that decides on this and then acts has parked in between and is
-- reading a number that has moved.
function Sema:free()
	return #self.q.buf
end

return { new = new, Sema = Sema }
