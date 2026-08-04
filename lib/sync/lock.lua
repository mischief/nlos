-- sync.lock: one thread at a time, across a park.
--
-- ---- read this before reaching for it ----
--
-- You probably want one of two other things.
--
-- OWNERSHIP. Give the resource to one thread and have everyone else
-- ask it. task/sshd.lua does this for the one shape that most obviously
-- looks like it wants a lock -- several threads with packets to put on
-- one connection -- and says so at its write():
--
--	only this thread writes, so the order packets are built in
--	is the order they leave in, which is what the sequence
--	numbers require
--
-- That is better than locking. There is no lock to forget, and the
-- ordering guarantee falls out of the structure instead of resting on
-- everybody remembering.
--
-- A CHANNEL. Handing work to whoever owns the thing is what channels
-- are for, and it is plan 9's answer as well: libthread has locks
-- because a proc there is an rfork sharing memory with other procs
-- running in parallel. Nothing here shares memory -- procs are
-- separate lua_States and talk by copying messages -- so that entire
-- category of lock does not apply and never will.
--
-- ---- what is left, and why this exists ----
--
-- One reason survives: an invariant that has to hold across a PARK.
-- Cooperative scheduling removes the need to guard a few instructions,
-- because nothing interrupts them. It does not remove the need to
-- guard a stretch that blocks in the middle -- and this runtime blocks
-- constantly, since every message is a round trip. Python's asyncio
-- ships a Lock for exactly this reason despite having no parallelism
-- at all.
--
-- So: if a multi-step thing spans a park and a second thread stepping
-- into the middle of it would be wrong, this is the tool.
--
--	local lock = require("sync.lock")
--	local l = lock.new()
--
--	l:lock()
--	local a = fetch(x)	-- parks
--	local b = fetch(y)	-- parks; must see the same a
--	l:unlock()
--
-- ---- and why it is written this way ----
--
-- A cap-1 channel holding one token IS the lock. There is no `held`
-- flag, because a flag has to be tested and then set, and a version of
-- this that did that shipped and was wrong: two threads both fell out
-- of `while self.held do` and both took it. Nothing here can be in a
-- state where the lock looks free and is not.
--
-- Nothing records which thread holds it, so it is not recursive:
-- locking twice in one thread waits forever on itself. plan 9's QLock
-- has the same shape and the same rule.
--
-- unlock() of an unlocked lock RAISES, because it means the caller
-- believes it holds something it does not.
--
-- IN-PROCESS ONLY, like everything built on channels. Two procs cannot
-- share this. That is not a gap to fill later -- see the top of this
-- comment.

local sema = require("sync.sema")

local Lock = {}

Lock.__index = Lock

local function new()
	return setmetatable({ s = sema.new(1) }, Lock)
end

function Lock:lock()
	self.s:acquire()
end

function Lock:trylock()
	return self.s:tryacquire()
end

function Lock:unlock()
	if self.s:free() > 0 then
		error("sync.lock: unlock of an unlocked lock", 2)
	end
	self.s:release()
end

return { new = new, Lock = Lock }
