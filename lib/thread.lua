-- los.thread: the cooperative runtime, layered on los.sys.
--
-- two-level concurrency, plan9 libthread shape:
--   procs   = isolated lua states (kernel, cross via ports, pay copy)
--   threads = coroutines inside this state (cheap, share heap)
-- Channel/alt lifted from libthread; recv() blocking sugar over ports.
--
-- returned as a module: require("los.thread") gives the scheduler table
-- with Channel/alt/QLock/recv/readline hung off it.

local sys = require("los.sys")

-- ---- thread scheduler ----

local thread = {
	_runq = {},
	_parked = {},	-- co -> reason: {port=h} | {ports={...}} | {chan=c}
	_n = 0,
}

function thread._ready(co)
	thread._parked[co] = nil
	thread._runq[#thread._runq + 1] = co
end

function thread._park(reason)
	local co = coroutine.running()
	thread._parked[co] = reason
	coroutine.yield()
end

function thread.spawn(fn, ...)
	local args = table.pack(...)
	local co = coroutine.create(function()
		fn(table.unpack(args, 1, args.n))
	end)
	-- kernel count hook: busy threads yield back to the scheduler.
	-- (a lua-function hook can't yield across the C hook boundary,
	-- so the kernel installs its own C hook for us.)
	sys.preempt(co, 25000)
	thread._n = thread._n + 1
	thread._runq[#thread._runq + 1] = co
	return co
end

-- run until all threads finish. this is the proc's event loop.
function thread.run()
	local rounds = 0
	while thread._n > 0 do
		rounds = rounds + 1
		if rounds % 64 == 0 then
			sys.yield()	-- let other procs breathe
		end
		local co = table.remove(thread._runq, 1)
		if co then
			thread._current = co
			local ok, err = coroutine.resume(co)
			thread._current = nil
			if coroutine.status(co) == "dead" then
				thread._n = thread._n - 1
				thread._parked[co] = nil
				if not ok then
					print("thread error: " .. tostring(err))
				end
			elseif not thread._parked[co] then
				-- preempted by its count hook: still runnable
				thread._runq[#thread._runq + 1] = co
			end
		else
			-- everyone parked. gather ports, sleep in kernel.
			local set, seen = {}, {}
			for _, r in pairs(thread._parked) do
				for _, h in ipairs(r.ports or
				    (r.port and { r.port }) or {}) do
					if not seen[h] then
						seen[h] = true
						set[#set + 1] = h
					end
				end
			end
			if #set == 0 then
				error("deadlock: all threads parked on channels")
			end
			sys.altblock(set)
			-- wake every port-parked thread; they retry
			for co2, r in pairs(thread._parked) do
				if r.port or r.ports then
					thread._ready(co2)
				end
			end
		end
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
	while #self.recvq > 0 do
		local w = table.remove(self.recvq, 1)
		if w.co then
			thread._ready(w.co)
		end
	end
end

-- no more values will ever be sent. wakes everyone parked on this
-- channel: receivers so they can drain and then see the close, senders
-- so they can fail instead of parking forever.
function Channel:close()
	if self.closed then
		return
	end
	self.closed = true

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
end

function Channel:nbsend(v)
	if self.closed then
		error("send on closed channel", 2)
	end
	if #self.buf < self.cap then
		self.buf[#self.buf + 1] = v
		self:_wakercv()
		return true
	end
	if self.cap == 0 and #self.recvq > 0 then
		-- rendezvous with a parked receiver: deposit the value
		self.sendq[#self.sendq + 1] = { v = v, done = true }
		self:_wakercv()
		return true
	end
	return false
end

function Channel:send(v)
	if self:nbsend(v) then
		return
	end
	local r = { v = v, co = coroutine.running(), done = false }
	self.sendq[#self.sendq + 1] = r
	self:_wakercv()
	repeat
		thread._park({ chan = self })
		-- close() dropped us from sendq and woke us; the value was
		-- never taken. no need to unlink, only to fail.
		if not r.done and self.closed then
			error("send on closed channel", 2)
		end
	until r.done
end

function Channel:nbrecv()
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
		return true, v
	end
	local s = table.remove(self.sendq, 1)
	if s then
		s.done = true
		if s.co then
			thread._ready(s.co)
		end
		return true, s.v
	end
	-- drained. only now does the close become visible -- the third
	-- return is what lets recv() tell "closed" from "someone sent
	-- nil", which a rendezvous channel can genuinely do. alt() takes
	-- two values and is unaffected.
	if self.closed then
		return true, nil, true
	end
	return false
end

function Channel:recv()
	while true do
		local ok, v, closed = self:nbrecv()
		if ok then
			return v, not closed
		end
		local w = { co = coroutine.running() }
		self.recvq[#self.recvq + 1] = w
		thread._park({ chan = self })
		for i, q in ipairs(self.recvq) do
			if q == w then
				table.remove(self.recvq, i)
				break
			end
		end
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

local function alt(cases)
	while true do
		for i, cs in ipairs(cases) do
			if cs.port then
				local ok, m = sys.tryrecv(cs.port)
				if ok then
					return i, m
				end
			elseif cs.op == "recv" then
				local ok, v = cs.c:nbrecv()
				if ok then
					return i, v
				end
			else
				if cs.c:nbsend(cs.v) then
					return i
				end
			end
		end
		if inthread() then
			local marks, plist = {}, {}
			for _, cs in ipairs(cases) do
				if cs.port then
					plist[#plist + 1] = cs.port
				elseif cs.op == "recv" then
					local w = { co = coroutine.running() }
					cs.c.recvq[#cs.c.recvq + 1] = w
					marks[#marks + 1] = { cs.c.recvq, w }
				end
			end
			thread._park({ ports = plist })
			for _, m in ipairs(marks) do
				for i, q in ipairs(m[1]) do
					if q == m[2] then
						table.remove(m[1], i)
						break
					end
				end
			end
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

-- ---- qlock (plan9 QLock; only matters across yields) ----

local QLock = {}
QLock.__index = QLock

local function qlockcreate()
	return setmetatable({ held = false, q = chancreate(0) }, QLock)
end

function QLock:lock()
	while self.held do
		self.q:recv()
	end
	self.held = true
end

function QLock:unlock()
	self.held = false
	self.q:nbsend(true)
end

-- ---- port sugar ----

-- blocking recv on a port right; thread-aware.
local function recv(h)
	while true do
		local ok, msg = sys.tryrecv(h)
		if ok then
			return msg
		end
		if inthread() then
			thread._park({ port = h })
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
-- recvtimeout, Channel, chancreate, alt, QLock, qlockcreate, ... }.

thread.Channel = Channel
thread.chancreate = chancreate
thread.alt = alt
thread.QLock = QLock
thread.qlockcreate = qlockcreate
-- park on a port once, thread-aware, without consuming anything. for
-- callers that need to re-check some other condition (a hangup, say)
-- after waking rather than just taking the next message.
local function park(h)
	if inthread() then
		thread._park({ port = h })
	else
		sys.block(h)
	end
end

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

thread.parksend = parksend
thread.recv = recv
thread.replyport = replyport
thread.readline = readline
thread.sleep = sleep
thread.recvtimeout = recvtimeout

return thread
