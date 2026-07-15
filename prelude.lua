-- prelude: loaded into every proc before its chunk runs.
--
-- two-level concurrency, plan9 libthread shape:
--   procs   = isolated lua states (kernel, cross via ports, pay copy)
--   threads = coroutines inside this state (cheap, share heap)
-- Channel/alt lifted from libthread; recv() blocking sugar over ports.

los.SELF = 0
los.KBD = 1	-- proc 0 only
los.SERIAL = 2	-- proc 0 only

-- ---- thread scheduler ----

thread = {
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
	-- count hook: busy threads yield back to the scheduler
	debug.sethook(co, function()
		coroutine.yield()
	end, "", 100000)
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
			los.yield()	-- let other procs breathe
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
			los.altblock(set)
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

Channel = {}
Channel.__index = Channel

function chancreate(cap)
	return setmetatable({
		cap = cap or 0,
		buf = {},
		sendq = {},	-- {v=, co=, done=} (co=nil means deposited)
		recvq = {},	-- {co=}
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

function Channel:nbsend(v)
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
	return false
end

function Channel:recv()
	while true do
		local ok, v = self:nbrecv()
		if ok then
			return v
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

function alt(cases)
	while true do
		for i, cs in ipairs(cases) do
			if cs.port then
				local ok, m = los.tryrecv(cs.port)
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
	end
end

-- ---- qlock (plan9 QLock; only matters across yields) ----

QLock = {}
QLock.__index = QLock

function qlockcreate()
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
function recv(h)
	while true do
		local ok, msg = los.tryrecv(h)
		if ok then
			return msg
		end
		if inthread() then
			thread._park({ port = h })
		else
			los.block(h)
		end
	end
end

-- line editor over the keyboard port (proc 0 only)
function readline(prompt)
	if prompt then
		io.write(prompt)
	end
	local buf = {}
	while true do
		local c = recv(los.KBD)
		if c == "\r" or c == "\n" then
			io.write("\n")
			return table.concat(buf)
		elseif c == "\4" then -- ctrl-d
			if #buf == 0 then
				return nil
			end
		elseif c == "\8" or c == "\127" then -- backspace
			if #buf > 0 then
				table.remove(buf)
				io.write("\8 \8")
			end
		elseif #c == 1 and c >= " " then
			buf[#buf + 1] = c
			io.write(c)
		end
	end
end
