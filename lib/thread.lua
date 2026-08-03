-- los.thread: the cooperative runtime, layered on los.sys.
--
-- two-level concurrency, plan9 libthread shape:
--   procs   = isolated lua states (kernel, cross via ports, pay copy)
--   threads = coroutines inside this state (cheap, share heap)
-- Channel/alt lifted from libthread; recv() blocking sugar over ports.
--
-- returned as a module: require("los.thread") gives the scheduler table
-- with Channel/alt/recv/readline hung off it.

local sys = require("los.sys")

-- ---- thread scheduler ----

-- the run queue is a ring, not an array shifted from the front.
--
-- it was table.remove(_runq, 1), which moves every remaining element
-- down a slot: O(threads) per dispatch, so O(threads squared) to get
-- once around a proc holding many of them. head and tail indices make
-- that O(1), and the pair resets to 1/0 whenever the queue drains --
-- which it does constantly -- so they never grow without bound.
local thread = {
	_runq = {},
	_qhead = 1,
	_qtail = 0,
	_parked = {},	-- co -> reason record, see parkrec below
	_n = 0,
}

-- ---- being cut in half ----
--
-- The count hook can stop a coroutine between ANY two instructions, and
-- unlike a yield that is not a place the code chose. Where it lands
-- decides whether it matters:
--
--   main    stopped mid-update yields the whole PROC to the kernel.
--           Nothing else in this proc runs until it is resumed, and it
--           resumes exactly where it was. Harmless.
--   thread  stopped mid-update returns control to run(), which carries
--           on -- requeues it, picks someone else, and lets that
--           someone observe, or write over, a half-finished update.
--
-- So every multi-step update a THREAD makes to state another thread
-- reads is a critical section, and this is how they are marked. It is
-- not a lock: nothing is owned, nothing blocks, and two threads can
-- never be inside one at the same time anyway, because there is no
-- moment at which two coroutines are running. All it says is "do not
-- let anyone else look until I am finished", and run() honours it by
-- resuming this coroutine, and only this coroutine, until it clears.
--
-- Two rules come with it, and they are the usual two:
--
--   1. NEVER park inside one. A thread that yields voluntarily with
--      _crit set would be resumed forever by a scheduler waiting for
--      it to finish. Everything below leaves the section before it
--      parks.
--   2. A thread that dies inside one must clear it, or run() spins on
--      a corpse. resume_one does that.
--
-- Depth-counted because the channel operations call each other --
-- send() -> nbsend() -> _wakercv() -- and only the outermost may
-- release. _crit is set before the depth is touched so that a cut
-- between the two is already covered.
--
-- The depth belongs to whoever holds the section, and changing hands
-- resets it. That is what keeps one thread's mistake to itself: an
-- error raised inside a section and caught by the thread that made it
-- leaves the depth standing, because nothing unwinds it on the way
-- past, and a single shared counter would carry that leak into every
-- section any other thread entered afterwards. Ownership is already
-- recorded, so keying the depth to it costs one comparison and no
-- lookup.
--
-- Only a thread running under run() needs any of this. A cut in main
-- yields the proc to the kernel and resumes exactly where it was, so
-- there is no moment at which anyone could look; marking a section
-- there would mean run() finding itself in _crit and trying to resume
-- the coroutine it is already running.
local critdepth = 0

local function critenter()
	local co = coroutine.running()

	if co ~= thread._current then
		return		-- not a thread under run()
	end
	if thread._crit ~= co then
		thread._crit = co
		critdepth = 0	-- whatever is left is someone else's
	end
	critdepth = critdepth + 1
end

local function critleave()
	if thread._crit ~= coroutine.running() then
		return		-- never held it, or it has changed hands
	end
	critdepth = critdepth - 1
	if critdepth <= 0 then
		thread._crit = nil
	end
end

-- the ring needs no section: threads never touch it. They stage a
-- single store below and run() -- main -- is the only thing that ever
-- pushes, which is why a hole cannot be created here at all.
local function push(co)
	local t = thread._qtail + 1

	thread._qtail = t
	thread._runq[t] = co
end

-- wake[co] = true is ONE store with no index that can go stale, and no
-- intermediate state: the coroutine is staged or it is not.
local wake = {}

-- a wake delivered to a thread that has decided to park but has not
-- got there yet.
--
-- Registering on a queue and parking cannot be one step: a section may
-- not span a yield, so there is always a gap between "I am on the
-- recvq" and "I am parked". A sender in that gap takes the waiter off
-- the queue and readies a thread that is not parked, which does
-- nothing at all -- and the thread then parks, having slept through a
-- wake that already happened. Both threads park, nothing is queued,
-- and run() correctly reports a deadlock that is entirely our fault.
--
-- So a wake for a thread that is not parked leaves a token, and the
-- next park consumes it and returns instead of sleeping. That is
-- park/unpark, and it is what makes the order of the two irrelevant.
-- Every caller of parkon re-checks its own condition in a loop, so a
-- token that turns out to be spurious costs one lap and nothing else.
local woken = {}

local function pop()
	local h = thread._qhead

	if h > thread._qtail then
		return nil
	end

	local co = thread._runq[h]

	thread._runq[h] = nil
	if h == thread._qtail then
		thread._qhead, thread._qtail = 1, 0	-- drained; reset
	else
		thread._qhead = h + 1
	end
	return co
end

-- portq[h] is the coroutine waiting in recv() on that port, or a list
-- of them. a scalar in the common case on purpose: thread.replyport()
-- gives every thread its own port, so one waiter is overwhelmingly
-- normal, and making that case an append-and-remove on a list cost more
-- than the direct handoff saved.
local portq = {}
local pending = {}	-- port handle -> messages taken with no taker

-- a handed-over message lives on the coroutine's own park record
-- rather than in a table keyed by coroutine. that record is already being looked up
-- on both sides -- deliver holds it to check the thread is still parked
-- where it said, and recv fetches it to park again -- so carrying the
-- message there costs no lookup at all, where two side tables cost four.
--
-- this is what go and libthread do: the value is written into the
-- waiter itself (sudog.elem, the Alt's value slot), never into a
-- registry the waker has to consult. doing it the other way made the
-- whole direct-handoff path a net loss at small thread counts.
--
--   r.mail    the message
--   r.hasmail true; separate, because nil is a legal message

-- port-parked threads that are not a plain recv(): a bare park(), or an
-- alt() over several ports. the scheduler can only do the receive
-- itself when this is empty, since those two want to do their own.
--
-- a set rather than a count, so releasing costs one unconditional store
-- and needs no read-modify-write on the hot path. it is normally empty,
-- so it stays small and next() on it is cheap.
local nonrecv = {}

function thread._ready(co)
	critenter()
	nonrecv[co] = nil
	if thread._parked[co] then
		thread._parked[co] = nil
	else
		woken[co] = true	-- on its way to park: leave the token
	end
	wake[co] = true
	critleave()
end

-- hand `msg`, taken from port `h`, to a thread waiting in recv() on it.
-- stale queue entries (a thread readied for some other reason) are
-- dropped as they are found, which is why the queue is never pruned
-- anywhere else. returns false if nobody was waiting after all.
local function handover(co, h, msg)
	local r = thread._parked[co]

	if not (r and r.recv and r.port == h) then
		return false	-- readied for some other reason; stale
	end
	r.mail, r.hasmail = msg, true
	thread._ready(co)
	return true
end

local function deliver(h, msg)
	local q = portq[h]

	if q == nil then
		return false
	end
	if type(q) == "thread" then
		portq[h] = nil
		return handover(q, h, msg)
	end
	while #q > 0 do
		local co = table.remove(q, 1)

		if handover(co, h, msg) then
			return true
		end
	end
	return false
end

-- one park record per coroutine, reused for the life of that coroutine.
--
-- parking allocated a fresh {port=h} every time, and a thread parks once
-- for every message it waits for -- so a proc holding n parked threads
-- produced n garbage tables for each message delivered to any one of
-- them. unused fields are set to false rather than nil: both are falsy
-- to the readers below, and a table whose shape never changes stays off
-- lua's rehash path.
--
-- weak-keyed, so a collected coroutine takes its record with it.
local parkrec = setmetatable({}, { __mode = "k" })

-- ---- direct handoff ----
--
-- when every parked thread is an ordinary recv() on one port, the
-- scheduler can do the receive itself -- sys.altrecv takes a message
-- from whichever port has one, in the same breath as finding it -- and
-- hand the value to the thread that wanted it. that is go's model
-- (chansend copies into a dequeued sudog and readies that goroutine)
-- and libthread's (altexec hands the value to a specific waiting Alt),
-- and unlike a ready-port hint there is no moment where anything is
-- merely observed.
--
-- the scheduler taking the message means a failed delivery would lose
-- it, so this path runs only when every port-parked thread is a
-- recv() registered in portq below. a bare park(), or an alt() waiting
-- on several ports, puts the proc back on the hint path -- which is
-- correct, just slower. `pending` is the belt-and-braces: a message
-- taken for a port whose waiter has vanished is held there for whoever
-- calls recv() next, rather than dropped.
local function parkon(port, ports, chan, isrecv)
	local co = coroutine.running()
	local r = parkrec[co]

	if not r then
		r = { port = false, ports = false, chan = false,
		    recv = false, mail = false, hasmail = false }
		parkrec[co] = r
	end
	critenter()
	r.port, r.ports, r.chan, r.recv = port, ports, chan, isrecv or false
	if isrecv then
		local q = portq[port]

		if q == nil then
			portq[port] = co
		elseif type(q) == "thread" then
			portq[port] = { q, co }
		else
			q[#q + 1] = co
		end
	elseif port or ports then
		nonrecv[co] = true
	end
	if woken[co] then
		-- readied between deciding to park and getting here. The
		-- caller loops and looks again, which is where the value
		-- actually is.
		woken[co] = nil
		nonrecv[co] = nil
		critleave()
		return
	end
	thread._parked[co] = r
	critleave()
	-- a section still standing here has leaked, and this is the one
	-- place that can know it: rule 1 says a section may not span a
	-- yield, and this is where a thread yields voluntarily, so a depth
	-- that survived to this line is a section whose critleave was
	-- jumped over by an error the thread went on to catch. Left alone
	-- it would be fatal to the proc rather than to the thread -- run()
	-- resumes the holder and only the holder, so a parked one is
	-- resumed forever, and the proc spins without ever blocking. The
	-- thread's own state is already lost; what is repairable is the
	-- scheduler's, so take the section back and let the rest run.
	if thread._crit == co then
		thread._crit = nil
		critdepth = 0
	end
	coroutine.yield()
	-- a wake that landed between _parked and the yield above cleared
	-- _parked before it was set, so clear it here too: a RUNNING
	-- coroutine must never be marked parked, or run() will decline to
	-- requeue it the next time the hook cuts it.
	thread._parked[co] = nil
end

-- the table form, for any caller outside this file.
function thread._park(reason)
	parkon(reason.port or false, reason.ports or false,
	    reason.chan or false)
end

function thread.spawn(fn, ...)
	local args = table.pack(...)
	local co = coroutine.create(function()
		fn(table.unpack(args, 1, args.n))
	end)
	-- No hook to install: lua_newthread copies hook, mask and count
	-- from the parent (lua/lstate.c), so this coroutine already
	-- carries the kernel's count hook and busy threads yield back to
	-- the scheduler on their own. sys.preempt used to be called here
	-- to do it by hand, which did nothing Lua had not already done and
	-- overrode the kernel's calibrated period with a hardcoded 25000
	-- -- the very constant 4e5a1c2 removed for being unknowable ahead
	-- of time. test/boot/test_preempt.lua pins the property.
	--
	-- the count is a read-modify-write on state every thread shares, and
	-- spawn is callable from a thread, so it needs the section: two
	-- threads cut between the read and the store lose an increment, _n
	-- undercounts, and run()'s loop ends while the threads it forgot are
	-- still queued or parked. they are not deadlocked and nothing is
	-- raised -- the proc simply leaves them where they stand and its
	-- caller is told the work is done.
	--
	-- wake[co] needs nothing beyond being inside it: one store, no index
	-- that can go stale. resume_one's matching decrement needs nothing at
	-- all, since it runs only in main, where a cut yields to the kernel
	-- and resumes in place.
	critenter()
	thread._n = thread._n + 1
	wake[co] = true
	critleave()
	return co
end

-- the port set handed to sys.altblock, refilled rather than rebuilt.
--
-- this was two fresh tables per full park, sized by how many threads
-- were parked, plus a { r.port } wrapper table for each single-port
-- waiter. `seen` is stamped with a generation instead of being cleared,
-- so dedup costs a compare; `set` is filled in place, and only the tail
-- left over from a larger previous park has to be nil'd, since
-- sys.altblock reads it with luaL_len.
local altset, altseen, altgen, altn = {}, {}, 0, 0

local function gatherports()
	altgen = altgen + 1

	local n = 0

	for _, r in pairs(thread._parked) do
		local ps = r.ports

		if ps then
			for i = 1, #ps do
				local h = ps[i]

				if altseen[h] ~= altgen then
					altseen[h] = altgen
					n = n + 1
					altset[n] = h
				end
			end
		elseif r.port then
			local h = r.port

			if altseen[h] ~= altgen then
				altseen[h] = altgen
				n = n + 1
				altset[n] = h
			end
		end
	end
	for i = n + 1, altn do
		altset[i] = nil
	end
	altn = n
	return n
end

-- ready the threads parked on ONE port, rather than all of them.
--
-- the hint from sys.altblock/altpoll is advisory: it says a port had a
-- message a moment ago, not that this thread will get it. recv() is
-- still a tryrecv/park loop, so a thread woken for a message someone
-- else took simply parks again. that is what keeps this safe to build
-- on a level check -- see altready() in the kernel.
--
-- returns false when the hint named a port nobody is parked on, which
-- can happen if the thread that wanted it was readied for another
-- reason first. the caller falls back to waking everyone.
local function readyon(h)
	local woke = false

	for co, r in pairs(thread._parked) do
		if r.port == h then
			thread._ready(co)
			woke = true
		elseif r.ports then
			local ps = r.ports

			for i = 1, #ps do
				if ps[i] == h then
					thread._ready(co)
					woke = true
					break
				end
			end
		end
	end
	return woke
end

-- wake every port-parked thread and let each find out for itself. the
-- fallback, and before the hint existed it was the only path.
local function readyall()
	for co, r in pairs(thread._parked) do
		if r.port or r.ports then
			thread._ready(co)
		end
	end
end

-- wake the threads parked on ports that have hung up.
--
-- altset is exactly the ports some thread of ours is parked on, so this
-- is the whole question this proc can have about hangups: a parked
-- thread cannot care about a port that is not in it, and a hangup
-- anywhere else is not ours to notice. altn kernel calls, in place of
-- waking every thread to have it ask for itself.
local function wakehungup()
	local woke = false

	for i = 1, altn do
		if sys.hungup(altset[i]) and readyon(altset[i]) then
			woke = true
		end
	end
	return woke
end

-- the one place a thread is resumed, so the rules about what a yield
-- meant live together rather than being restated.
local function resume_one(co)
	thread._current = co
	local ok, err = coroutine.resume(co)
	thread._current = nil
	if coroutine.status(co) == "dead" then
		thread._n = thread._n - 1
		thread._parked[co] = nil
		if thread._crit == co then
			-- died mid-update. nothing can repair the structure
			-- it was halfway through, but leaving _crit set
			-- would have run() resume a corpse forever.
			thread._crit = nil
			critdepth = 0
		end
		if not ok then
			print("thread error: " .. tostring(err))
		end
	elseif thread._crit == co then
		-- cut inside a critical section: NOT requeued and nothing
		-- else runs. run() comes straight back to it, which is the
		-- whole mechanism -- the half-finished update is never
		-- observed, and run() never allocates a ring slot that this
		-- coroutine already believes is its own.
		return
	elseif not thread._parked[co] then
		-- preempted by its count hook, or yielded to stay runnable.
		-- either way it goes back on the queue, and the proc keeps
		-- running.
		--
		-- no yield to the kernel here: when the quantum is what
		-- ended the thread's turn, preempt_hook has already armed
		-- this state to trip on its next instruction, so the proc is
		-- about to be descheduled from inside this loop whether or
		-- not lua asks.
		push(co)
	end
end

-- run until all threads finish. this is the proc's event loop.
function thread.run()
	while thread._n > 0 do
		-- a thread stopped mid-update finishes before anything else
		-- in this proc runs -- including the delivery sweep below,
		-- which readies threads and would push onto a ring the cut
		-- thread may itself be in the middle of.
		if thread._crit then
			resume_one(thread._crit)
			goto lap
		end

		-- staged wakeups enter the ring here, in main. Must be
		-- before every "is anything runnable" test below, or a
		-- staged thread reads as nothing to run.
		if next(wake) ~= nil then
			for c in pairs(wake) do
				wake[c] = nil
				push(c)
			end
		end

		-- deliver to parked threads while a sibling is still
		-- runnable.
		--
		-- one thread that never parks would otherwise starve every
		-- thread that does: the altrecv/altblock branch below is the
		-- only other place a parked thread is readied, and it runs
		-- only when the runq is empty, which never happens while
		-- anything is runnable. a message would sit in a port with
		-- its reader parked beside it.
		--
		-- the wake cannot come from the kernel here. port_push wakes
		-- whoever is parked ON THE PORT, and this proc is not parked
		-- -- it is running. so the scheduler has to ask, and asking
		-- every round is what keeps the delay to one round rather
		-- than a poll interval.
		--
		-- affordable because the question is asked in two steps:
		-- sys.anyready is a bounded scan of our own rights in C,
		-- with no port set to build, and the sweep below -- which
		-- costs a gatherports over every parked thread -- runs only
		-- when it says yes. so an idle proc and a busy one that has
		-- nothing waiting both pay one cheap call.
		--
		-- and skipped entirely when the run queue is empty, which
		-- is the case this exists to exclude: with nothing runnable
		-- the altrecv/altblock branch below is about to deliver
		-- anyway, and it does it without polling.
		--
		-- the loop repeats because one poll reports one port and
		-- several may have filled.
		if thread._qhead <= thread._qtail
		    and next(thread._parked) ~= nil and sys.anyready()
		    and gatherports() > 0 then
			local i = sys.altpoll(altset)

			while i do
				local h = altset[i]

				if not readyon(h) then
					break
				end
				i = sys.altpoll(altset)
			end
		end
		local co = pop()
		if co then
			resume_one(co)
		else
			-- everyone parked. gather ports, sleep in kernel.
			if gatherports() == 0 then
				error("deadlock: all threads parked on channels")
			end
			if next(nonrecv) == nil then
				-- every waiter is a plain recv(): take the
				-- message here and hand it over, no wake
				-- to go and look for it.
				local i, msg = sys.altrecv(altset)

				if i then
					local h = altset[i]

					if not deliver(h, msg) then
						local q = pending[h]

						if not q then
							q = {}
							pending[h] = q
						end
						q[#q + 1] = msg
						readyall()
					end
				end
				-- and unconditionally, whether or not a
				-- message came back. a hangup and a message
				-- can arrive in the same wake -- unmounting
				-- sends a clunk and then drops the right --
				-- and taking the message consumes the wake
				-- that would have reported the hangup. so
				-- the state is checked every time rather
				-- than only when we came back empty-handed.
				wakehungup()
			else
				local i = sys.altblock(altset)

				-- the hint names the port that has
				-- something; only its threads need to run.
				local woke = i and readyon(altset[i]) or false

				-- a hangup is a wake the ready-port hint
				-- cannot describe: the thread that has to
				-- notice its peer is gone is the one with
				-- nothing queued, so altready never names
				-- it. asked every time rather than only when
				-- the hint is missing, because a hangup and
				-- a message can arrive in one wake and the
				-- message would consume it.
				if wakehungup() then
					woke = true
				end

				-- a wake we cannot attribute to any port of
				-- ours still has to be safe, so everyone
				-- gets to look.
				if not woke then
					readyall()
				end
			end
		end
		::lap::
	end
end

local function inthread()
	return thread._current ~= nil and
	    thread._current == coroutine.running()
end

-- ---- Channel (libthread flavor; cap 0 = rendezvous) ----
--
-- close() is 9front libthread's chanclose() and go's close(ch): the way
-- a producer says "no more". a PORT gets this for free -- sys.hungup
-- reports it straight out of the kernel's refcount, which is why
-- lib/prog.lua's PipeStream needs no protocol for eof -- but a channel
-- is a plain table with no lifetime, so it has to be told.
--
-- three rules, all of them go's:
--
--   * values already sent are received FIRST. close is not a discard:
--     recv drains buf and any deposited sender before it reports the
--     close. that is the same order the port side uses (drain, then
--     test hangup -- see lib/webterm.lua's pump), and the two matching
--     is most of the value of having both.
--   * sending on a closed channel RAISES. whoever closed it declared
--     there would be no more, so a later send is a bug rather than a
--     race, and it should be loud.
--   * recv on a closed, drained channel returns nil plus false. the
--     second value is go's `v, ok := <-ch`, and it earns its place
--     because nil is a legal value on a rendezvous channel (the
--     deposit path carries it fine), so nil alone is ambiguous.
--     callers that take one value -- every one written before this --
--     are unaffected.
--
-- close() is IDEMPOTENT, where go panics on a double close. a stream's
-- :close() runs on the normal path and again while an error unwinds,
-- and "closed" is a state rather than an event, so making the second
-- call fatal would punish correct cleanup and nothing else.

local Channel = {}
Channel.__index = Channel

local function chancreate(cap)
	return setmetatable({
		cap = cap or 0,
		buf = {},
		sendq = {},	-- {v=, co=, done=} (co=nil means deposited)
		recvq = {},	-- {co=}
		closed = false,
	}, Channel)
end

function Channel:_wakercv()
	critenter()
	while #self.recvq > 0 do
		local w = table.remove(self.recvq, 1)

		-- off the queue and not yet readied is the state that must
		-- not be left behind: nothing would ever wake it again.
		if w.co then
			thread._ready(w.co)
		end
	end
	critleave()
end

-- no more values will ever be sent. wakes everyone parked on this
-- channel: receivers so they can drain and then see the close, senders
-- so they can fail instead of parking forever.
function Channel:close()
	if self.closed then
		return
	end
	self.closed = true

	critenter()

	-- a parked SENDER's value was never taken and now never will be,
	-- so it is dropped and the sender raises. a DEPOSITED rendezvous
	-- value (co == nil, done already true) is left alone -- a receiver
	-- still has the right to drain it, per the first rule above.
	local keep = {}

	for _, s in ipairs(self.sendq) do
		if s.co then
			thread._ready(s.co)
		else
			keep[#keep + 1] = s
		end
	end
	self.sendq = keep
	self:_wakercv()
	critleave()
end

function Channel:nbsend(v)
	if self.closed then
		error("send on closed channel", 2)
	end
	critenter()
	if #self.buf < self.cap then
		self.buf[#self.buf + 1] = v
		self:_wakercv()
		critleave()
		return true
	end
	if self.cap == 0 and #self.recvq > 0 then
		-- rendezvous with a parked receiver: deposit the value
		self.sendq[#self.sendq + 1] = { v = v, done = true }
		self:_wakercv()
		critleave()
		return true
	end
	critleave()
	return false
end

function Channel:send(v)
	if self:nbsend(v) then
		return
	end
	local r = { v = v, co = coroutine.running(), done = false }

	critenter()
	self.sendq[#self.sendq + 1] = r
	self:_wakercv()
	critleave()
	repeat
		parkon(false, false, self)
		-- close() dropped us from sendq and woke us; the value was
		-- never taken. no need to unlink, only to fail.
		if not r.done and self.closed then
			error("send on closed channel", 2)
		end
	until r.done
end

function Channel:nbrecv()
	critenter()
	if #self.buf > 0 then
		local v = table.remove(self.buf, 1)
		local s = table.remove(self.sendq, 1)
		if s then
			self.buf[#self.buf + 1] = s.v
			s.done = true
			if s.co then
				thread._ready(s.co)
			end
		end
		critleave()
		return true, v
	end
	local s = table.remove(self.sendq, 1)
	if s then
		s.done = true
		if s.co then
			thread._ready(s.co)
		end
		critleave()
		return true, s.v
	end
	-- drained. only now does the close become visible -- the third
	-- return is what lets recv() tell "closed" from "someone sent
	-- nil", which a rendezvous channel can genuinely do. alt() takes
	-- two values and is unaffected.
	if self.closed then
		critleave()
		return true, nil, true
	end
	critleave()
	return false
end

function Channel:recv()
	while true do
		-- looking and then registering is ONE step. A sender that
		-- runs between them finds a recvq we are not in yet, wakes
		-- nobody, and leaves its value in the buffer -- and we would
		-- then park on a value that had already arrived. That is the
		-- race that hung the 9p client, and it is why the section
		-- covers the nbrecv as well as the append.
		--
		-- It ends before parkon: parking inside a section would have
		-- run() resume us forever waiting for us to finish.
		critenter()
		local ok, v, closed = self:nbrecv()

		if ok then
			critleave()
			return v, not closed
		end

		local w = { co = coroutine.running() }

		self.recvq[#self.recvq + 1] = w
		critleave()

		parkon(false, false, self)

		critenter()
		for i, q in ipairs(self.recvq) do
			if q == w then
				table.remove(self.recvq, i)
				break
			end
		end
		critleave()
	end
end

-- ---- alt: select over channel recv/send and port recv ----
-- cases: {c=chan, op="recv"} | {c=chan, op="send", v=} | {port=h}
-- returns index, value. note: alt-send on unbuffered channels only
-- pairs with an already-parked receiver.
--
-- a CLOSED channel is always ready to receive, yielding nil -- which is
-- libthread's behaviour and what makes alt usable for "wait for work or
-- for the producer to finish". a closed channel in a SEND case raises,
-- same as Channel:send would. nil here is ambiguous with a sent nil for
-- the reason nbrecv's comment gives; test c.closed if it matters.
--
-- ---- build the case table once, outside the loop ----
--
-- alt neither keeps nor mutates `cases`, so a caller whose cases do not
-- change should hoist them rather than write the table literal at the
-- call. `alt({{port=a},{port=b}})` inside a `while true` builds three
-- tables per trip, and that measured as 34% of an alt that finds a
-- message already waiting -- more than everything below costs.
--
-- this is not a micro-optimisation for hot paths only: the exclusive
-- device tasks (wire, tcp, udp) sit in exactly this loop for the life of
-- the machine, so it is where an idle system spends its time.
--
-- when one case's port genuinely varies, keep the table and assign the
-- field (task/sshd.lua's pump does this, because a session reset
-- replaces its console port). one store still beats three allocations.

-- the scratch alt parks with, one set per coroutine and reused.
--
-- alt allocated a fresh plist, a fresh marks, and a waiter plus a mark
-- pair per channel case EVERY time round its inner loop -- and that
-- loop runs once per wakeup, not once per alt, so a thread woken for a
-- message another case took paid it again. Same family as the three
-- allocations 2e231e8 removed from park, and the last one left.
--
-- keyed by coroutine and weak, so a collected thread takes its scratch
-- with it. Reuse is safe because alt never nests: nothing between
-- entering alt and leaving it can call alt again on the same coroutine
-- -- nbrecv and nbsend do not park, and parkon yields to the scheduler,
-- which resumes this same coroutine back inside this same call.
local altscratch = setmetatable({}, { __mode = "k" })

local function scratchfor(co)
	local s = altscratch[co]

	if not s then
		s = { plist = {}, marks = {}, waiters = {} }
		altscratch[co] = s
	end
	return s
end

local function alt(cases)
	local n = #cases

	while true do
		-- polling every case and then registering on the ones that
		-- had nothing is ONE step, exactly as in Channel:recv: a
		-- sender that runs in between finds queues we are not on
		-- yet, wakes nobody, and we park on a value that arrived.
		-- Every early return below leaves the section first.
		critenter()

		-- a counted loop rather than ipairs: this scan runs on every
		-- alt whether or not anything parks, so the per-case iterator
		-- call is pure overhead on the one path that is always taken.
		for i = 1, n do
			local cs = cases[i]

			if cs.port then
				local ok, m = sys.tryrecv(cs.port)
				if ok then
					critleave()
					return i, m
				end
			elseif cs.op == "recv" then
				local ok, v = cs.c:nbrecv()
				if ok then
					critleave()
					return i, v
				end
			else
				if cs.c:nbsend(cs.v) then
					critleave()
					return i
				end
			end
		end
		if inthread() then
			local co = coroutine.running()
			local s = scratchfor(co)
			local plist, marks, waiters =
			    s.plist, s.marks, s.waiters
			local np, nm = 0, 0

			for i = 1, n do
				local cs = cases[i]

				if cs.port then
					np = np + 1
					plist[np] = cs.port
				elseif cs.op == "recv" then
					nm = nm + 1

					-- one waiter table per channel case,
					-- reused across parks rather than made
					-- fresh: the queue it goes on drops it
					-- again below, so it is free by the
					-- time we need it next.
					--
					-- indexed by nm and not by the case
					-- slot, so it pairs with marks. That
					-- costs nothing because every waiter
					-- is the same {co = co} -- which case
					-- it stands for is carried by which
					-- queue it was put on, not by the
					-- table.
					local w = waiters[nm]

					if not w then
						w = { co = co }
						waiters[nm] = w
					end

					local q = cs.c.recvq

					q[#q + 1] = w
					marks[nm] = q
				end
			end
			-- only the tail left over from a larger previous park
			-- has to be cleared, since altblock reads plist with
			-- luaL_len and marks is walked to nm. same trick as
			-- gatherports' set.
			for i = np + 1, #plist do
				plist[i] = nil
			end
			critleave()
			parkon(false, plist, false)
			critenter()
			for i = 1, nm do
				local q = marks[i]
				local w = waiters[i]

				for j = 1, #q do
					if q[j] == w then
						table.remove(q, j)
						break
					end
				end
				marks[i] = false
			end
			critleave()
		else
			-- top-level caller (no thread.run() driving us, e.g.
			-- an exclusive task's main chunk calling alt()
			-- directly -- wire.lua, tcp.lua and udp.lua all do
			-- exactly this): thread._park is a bare
			-- coroutine.yield(),
			-- meaningless without thread.run()'s own loop to
			-- notice "everyone parked" and call the real
			-- sys.altblock on our behalf. with no such loop, that
			-- yield returns straight back to the kernel's
			-- lua_resume without ever setting this proc BLOCKED
			-- -- kernel_run then just resumes it again next lap,
			-- forever, a busy-spin disguised as blocking (this
			-- was a real bug: ps showed wire/tcp stuck "ready"
			-- forever, churning memory, never actually parking).
			-- channel cases make no sense here either way (recvq
			-- is purely in-process), so only port cases are
			-- valid.
			critleave()
			local plist = {}
			for _, cs in ipairs(cases) do
				if not cs.port then
					error("alt: channel case used outside thread.run()")
				end
				plist[#plist + 1] = cs.port
			end
			sys.altblock(plist)
		end
	end
end

-- ---- port sugar ----

-- blocking recv on a port right; thread-aware.
-- a threaded recv takes its value from the mailbox when the scheduler
-- already dequeued it (see deliver), and falls back to doing the
-- receive itself otherwise -- which is what a top-level caller, or one
-- on the hint path, always does.
local function recv(h)
	while true do
		local co = inthread() and coroutine.running()

		local r = co and parkrec[co]

		if r and r.hasmail then
			local m = r.mail

			r.hasmail, r.mail = false, false
			return m
		end
		if co then
			-- checked even when this coroutine has never parked
			-- and so has no record yet: a message may have been
			-- taken for this port with no taker at the time.
			local q = pending[h]

			if q and #q > 0 then
				return table.remove(q, 1)
			end
		end

		local ok, msg = sys.tryrecv(h)

		if ok then
			return msg
		end
		if co then
			parkon(h, false, false, true)
		else
			sys.block(h)
		end
	end
end

-- a reply port belonging to the CALLING THREAD, made once and reused.
--
-- request/reply over ports needs somewhere for the reply to land, and
-- the natural owner is the caller, not the service. a thread makes one
-- synchronous call at a time by construction -- it blocks for the
-- answer -- so ONE port per thread serves every service it will ever
-- talk to, however many mounts or tasks that is.
--
-- this is what makes 9P's tags unnecessary rather than merely omitted.
-- tags exist to demultiplex several outstanding replies arriving on one
-- channel; distinct ports need no demultiplexing at all, so threads
-- sharing a service stop serialising behind a lock and the replies
-- still cannot be confused. see lib/mnt.lua, which was the lock.
--
-- the budget is real: MAXPORTS is 128 for the whole system. so the
-- table is weak-keyed and the port carries a finalizer, and a thread
-- that exits gives its port back rather than holding one until the proc
-- dies. running out is raised, not worked around -- silently falling
-- back to a shared port would reintroduce exactly the crossed replies
-- this exists to prevent.
local replyports = setmetatable({}, { __mode = "k" })

local function replyport()
	local co = coroutine.running()
	local p = replyports[co]

	if not p then
		local h = sys.newport()

		if not h then
			error("out of ports", 0)
		end
		p = setmetatable({ h = h }, {
			__gc = function(t)
				pcall(sys.close, t.h)
			end,
		})
		replyports[co] = p
	end
	return p.h
end

-- readline: a request/reply against cons, the sole task with raw
-- keyboard access. the reply port is allocated once per proc and
-- reused, not minted fresh on every call.
--
-- consHandle is required: there is no well-known cons handle to fall
-- back on. the boot payload gets its number from sys.granted().cons,
-- everyone else from the {__right=} message that granted it.
--
-- the PROMPT goes to consHandle too, as an ordinary write, rather than
-- to ambient stdout. it used to be a plain io.write, which was
-- invisible while cons and stdout were the same serial device -- but
-- the prompt belongs to whoever is being asked for the line, and
-- io.write does not follow the right. a console that is not the serial
-- port (lib/webterm.lua serves one to a browser) got every line it
-- asked for and none of the prompts, while the prompts piled up on
-- com1 belonging to nobody. one message per prompt is the cost.
local cons_reply_port

-- send, treating a full queue as backpressure and a dead port as a
-- reportable fact. returns false only when the port is gone for good.
local function sendwait(h, msg)
	while true do
		local ok, why = sys.send(h, msg)

		if ok then
			return true
		end
		if why ~= "full" then
			return false
		end
		sys.sendblock(h)
	end
end

local function readline(consHandle, prompt)
	if prompt and not sendwait(consHandle,
	    { op = "write", data = prompt }) then
		return nil
	end
	if not cons_reply_port then
		cons_reply_port = sys.newport()
	end
	-- a console that has gone away is EOF, exactly as ^d is. this is
	-- load-bearing rather than tidy: a dead port DROPS silently (it
	-- never raised, see api_send), so without this a reader whose
	-- console vanished parks in recv() below forever, holding its proc
	-- until reboot. lib/webterm.lua reaping an idle session is exactly
	-- that case -- it closes the session port and expects the shell to
	-- end -- and dos's repl already treats a nil line as "session
	-- over", so the whole teardown falls out of returning nil here.
	if not sendwait(consHandle, { op = "readline",
	    reply = { __right = cons_reply_port } }) then
		return nil
	end
	return recv(cons_reply_port)
end

-- ---- timers ----
--
-- both of these are thin sugar over sys.timer(ms), which hands back a
-- receive right to a port that gets one message after ms. that shape is
-- what makes them sugar rather than kernel features: a timer is just
-- another port, so it composes with alt() for free.
--
-- resolution is the scheduler tick, ~10-15ms: a timer fires up to one
-- tick late and never early. do not use these to pace anything finer.

-- park for ms milliseconds. yields to the rest of the proc's threads if
-- called under thread.run(), and blocks the whole proc otherwise --
-- either way it PARKS rather than spinning, which is the entire point:
-- a `while sys.ticks() - t0 < n do sys.yield() end` loop keeps the proc
-- READY, so the kernel can never reach its idle sleep while any proc is
-- waiting for anything.
local function sleep(ms)
	local t = sys.timer(ms)

	if not t then
		return false	-- timer table full; caller decides
	end
	recv(t)
	sys.close(t)
	return true
end

-- receive from port h, giving up after ms. returns the message, or nil
-- plus "timeout". the timer is closed on both paths so a fast reply
-- doesn't leak a timer slot until its deadline.
local function recvtimeout(h, ms)
	local t = sys.timer(ms)

	if not t then
		return nil, "no timer available"
	end

	local which, m = alt({ { port = h }, { port = t } })

	sys.close(t)
	if which == 2 then
		return nil, "timeout"
	end
	return m
end

-- ---- exports ----
-- the module is the scheduler table with the rest of the runtime hung
-- off it: require("los.thread") -> { spawn, run, recv, readline, sleep,
-- recvtimeout, Channel, chancreate, alt, ... }.

thread.Channel = Channel
thread.chancreate = chancreate
thread.alt = alt
-- park on a port once, thread-aware, without consuming anything. for
-- callers that need to re-check some other condition (a hangup, say)
-- after waking rather than just taking the next message.
local function park(h)
	if inthread() then
		parkon(h, false, false)
	else
		sys.block(h)
	end
end

-- exported because "am I running under the scheduler" decides more
-- than blocking does: code that spawns helper threads and then waits
-- for them has to park on a channel when it is itself a thread, and
-- drive thread.run() when it is not. Getting that backwards either
-- stalls the proc or nests a second scheduler inside the first.
thread.inthread = inthread
thread.park = park

-- park until a port might have ROOM, the send-side mirror of park().
-- for a writer that wants backpressure instead of a failed send: loop
-- on sys.send and call this when it reports "full".
--
-- NOTE the asymmetry with park(): inside a thread this parks the whole
-- PROC (sys.sendblock), not just the calling coroutine, because the
-- scheduler's park reasons are receive-shaped -- thread.run hands its
-- port set to sys.altblock, and a send wait is not a port set. that
-- means one coroutine blocked on a full port stalls its siblings,
-- which is why a SERVER must never use this (it would stop serving
-- everyone because one client stopped reading). pipe-shaped code,
-- which is what this is for, has nothing else to get on with anyway.
local function parksend(h)
	sys.sendblock(h)
end

-- ---- request/reply ----
--
-- await() waits for one message on a REPLY port, and unlike recv() it
-- gives up when the port hangs up instead of parking forever. the
-- difference is not a policy choice, it is what the two ports can know:
-- a quiet service port may simply be idle, but a reply port holds two
-- rights while a request is in flight -- ours, and the one that
-- travelled with the message -- so a drop back to one with nothing
-- queued means the holder died without answering.
--
-- returns nil plus "hungup" in that case, matching what sys.call
-- reports for the same condition.
local function await(h)
	while true do
		local got, res = sys.tryrecv(h)

		if got then
			return res
		end
		if sys.hungup(h) then
			return nil, "hungup"
		end
		park(h)
	end
end

-- call(h, msg, replyh): send a request and wait for its reply.
--
-- one call site, two implementations, because the fused kernel entry is
-- not available to a thread. sys.call marks the whole PROC blocked and
-- takes it off the run queue, so a coroutine yielding out of that would
-- strand every sibling thread -- the kernel refuses it outright rather
-- than letting it happen quietly.
--
-- that costs a thread nothing, because the expensive half is already
-- fused on its side: what a thread pays for is the block, and thread.run
-- hands every parked port to sys.altrecv, which blocks and TAKES in one
-- entry on behalf of all of them at once. what is left over here is a
-- plain send, which does not block and never was the cost. a fused
-- thread.call would only fold in the cheap half.
--
-- both paths report the same three failures as nil plus a reason:
-- "dead", "full", "hungup". a full queue is the caller's policy (see
-- sendwait), which is why it is reported rather than waited out.
local function call(h, msg, replyh)
	if not inthread() then
		return sys.call(h, msg, replyh)
	end

	local ok, why = sys.send(h, msg)

	if not ok then
		return nil, why or "dead"
	end
	return await(replyh)
end


-- giveright: a {__right=} table that closes the right it minted.
--
-- For putting a capability to ANOTHER port in a message -- what
-- task/srvd.lua answers a lookup with, and what task/sshd.lua hands a
-- session. Not for a reply port: call() takes that as a handle and
-- needs no right minted at all.
--
-- Sending COPIES. The serializer takes its own reference to the port --
-- kernel.c bumps nrights on the message's behalf, precisely so the
-- sender closing its copy cannot flush the queue -- and leaves the
-- caller's handle live, still spending one of MAXRIGHTS. A server that
-- mints one per request and forgets it stops answering after 512 of
-- them, which is why task/srvd.lua and task/sshd.lua use this: both run
-- forever.
--
-- The __gc is a net, not the mechanism. Collection is not prompt, so a
-- burst can still exhaust MAXRIGHTS between cycles; what it buys is
-- that forgetting stops being permanent.
--
-- Not for a right meant to outlive its message: a capability handed to
-- a child in sys.spawn's arg must not be closed when the arg table is
-- collected.
local function giveright(h)
	local r = sys.sendright(h)

	if not r then
		return nil
	end

	return setmetatable({ __right = r }, {
		__gc = function()
			pcall(sys.close, r)
		end,
	})
end

-- rpc: call() for a caller that has no reply port of its own.
--
-- call() is the transport and wants a reply handle; this is the wrapper
-- that supplies one -- the per-coroutine replyport, named directly
-- rather than as a minted send right, which is what lib/mnt.lua and
-- lib/srv.lua do and is the only shape that cannot leak: there is
-- nothing to close because nothing was minted.
--
-- Worth stating why that is safe to reuse across calls: a reply
-- arriving after a timeout lands in the same port the next call reads.
-- So `timeout` is for callers that can tolerate that, and a protocol
-- that cannot should carry its own sequence number, as lib/mnt.lua's
-- does.
local function rpc(dest, msg, timeout)
	local reply = replyport()

	msg.reply = { __right = reply }

	if timeout then
		local ok, why = sys.send(dest, msg)

		if not ok then
			return nil, why or "dead"
		end
		return recvtimeout(reply, timeout)
	end
	return call(dest, msg, reply)
end

thread.giveright = giveright
thread.parksend = parksend
thread.recv = recv
thread.rpc = rpc
thread.await = await
thread.call = call
thread.replyport = replyport
thread.readline = readline
thread.sleep = sleep
thread.recvtimeout = recvtimeout

return thread
