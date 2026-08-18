-- srv: serve a dev backend on a port.
--
-- this is the server half of the mount driver; lib/mnt.lua is the
-- client half. together they are plan 9's devmount, and the thing they
-- prove is that the dev interface -- not 9P's wire format -- is what
-- crosses a port.
--
-- ---- the protocol, and why it is not 9P bytes ----
--
-- 9P's framing exists to recover message boundaries from a byte stream.
-- a port is a MESSAGE port, so size[4] would be a second encoding
-- stacked on the serializer, solving a problem the serializer already
-- solved. what travels here is the dev call itself, as a table:
--
--	{op="walk", fid=3, name="lib", reply={__right=rp}}  ->  {fid=4}
--	{op="read", fid=4, off=0, n=4096, reply={...}}      ->  {data="..."}
--
-- 9P's SEMANTICS survive intact -- fids, explicit offsets, walk one
-- element at a time, create-implies-open -- because those are the dev
-- interface (see src/dev.c, which was shaped fid-first for exactly
-- this). what does not survive is everything the wire format needs and
-- a port supplies for free:
--
--   tag/Tflush   a reply right carried in each request, pointing at the
--                CALLING THREAD's own port (thread.replyport). tags
--                exist to demultiplex several outstanding replies on
--                one channel; one port per caller means there is
--                nothing to demultiplex, so requests still pipeline and
--                no table maps answers back to waiters. the right
--                itself costs three bytes in the serializer, measured
--                under 5% of a round trip and cheaper than the plain
--                table it replaces. abandoning a request is closing a
--                right.
--   Tauth        holding the right IS the authentication. a proc that
--                was never sent this port cannot reach this backend.
--   msize        dev.IOUNIT, which both halves chunk to. The serializer
--                does bound a message, but by REFUSING it -- and a reply
--                that cannot be sent is a client waiting forever, so the
--                bound has to be respected rather than merely relied on.
--   size[4]      the port preserves the boundary.
--
-- lib/ninep.lua is still the encoding at a real boundary -- com2, TCP,
-- anything off this machine. it is not the encoding between two procs.
--
-- ---- a server is a proc, and the mount is the spawn right ----
--
-- sys.spawn returns a send right to the child's own receive port, so
-- serving on sys.SELF makes that right the mount:
--
--	local pid, h = sys.spawn('require("srv").main()')
--	ns:mount("/host", mnt.new(h), "mnt", { port = {__right = h} })
--
-- that is plan 9's srv, minus the /srv registry: the capability to talk
-- to a file server is an ordinary right, granted by being sent.
--
-- ---- lifetime ----
--
-- serve() returns when the port hangs up -- when the last client drops
-- its right, nobody can ever send again, so there is nothing left to
-- serve. that is devsrv's rule and it needs no shutdown message, which
-- is good: a shutdown op would let any one mount holder kill the server
-- for every other holder.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local buf = require("los.buf")
local sema = require("sync.sema")
local lock = require("sync.lock")

local M = {}

-- ---- the ops ----
--
-- each is the dev call, verbatim. they RAISE on failure, because the
-- backend raises and nothing in between should be checking -- the one
-- pcall is in dispatch(), which is this module's syscall entrypoint in
-- exactly the sense src/dev.c describes.

local ops = {}

function ops.attach(S)
	return { fid = S.put(S.B.attach()) }
end

function ops.walk(S, m)
	return { fid = S.put(S.B.walk(S.get(m.fid), m.name)) }
end

-- a whole path in one message. the backend may have its own walkmany --
-- a mount of a mount does -- and otherwise this is dev.walkall, which is
-- the same loop the client would have run, minus a round trip each.
--
-- the intermediates are clunked HERE, which is the point of doing this
-- server-side: these handles are ours, we know they died the moment the
-- next walk succeeded, and for espfs they are real EFI file handles.
-- across a port the client could never have known.
function ops.walkmany(S, m)
	local h = S.get(m.fid)

	if S.B.walkmany then
		return { fid = S.put(S.B.walkmany(h, m.names)) }
	end

	local made = {}
	local ok, res

	for _, name in ipairs(m.names or {}) do
		ok, res = pcall(S.B.walk, h, name)
		if not ok then
			for _, x in ipairs(made) do
				pcall(S.B.clunk, x)
			end
			dev.error(tostring(res) .. ": '" .. name .. "'")
		end
		-- a backend may hand back the SAME handle (dev.mem does for
		-- ".."), which is the caller's and not ours to release
		if res ~= h then
			made[#made + 1] = res
		end
		h = res
	end
	-- everything except the one we are about to name is dead
	for i = 1, #made - 1 do
		pcall(S.B.clunk, made[i])
	end
	return { fid = S.put(h) }
end

function ops.stat(S, m)
	return { st = S.B.stat(S.get(m.fid)) }
end

function ops.open(S, m)
	return { fid = S.put(S.B.open(S.get(m.fid), m.mode)) }
end

function ops.create(S, m)
	return { fid = S.put(S.B.create(S.get(m.fid), m.name, m.mode, m.dir)) }
end

-- clamped to what a reply can actually carry, rather than trusted.
--
-- lib/mnt.lua already chunks to the same number, so a well-behaved
-- client never reaches this. It is here because the alternative to
-- clamping is not an error: a reply too big to serialize cannot be sent,
-- and a client waiting for an answer that will never arrive hangs. A
-- server must not be reachable into that state by a number in a message.
--
-- clamping rather than raising because a short read is already what this
-- interface means and what every caller handles -- see dev.readloop.
function ops.read(S, m)
	local n = m.n

	if type(n) == "number" and n > dev.IOUNIT then
		n = dev.IOUNIT
	end
	-- readbuf where the backend has one: it answers with bytes it owns,
	-- which the transfer below hands over instead of copying.
	local rd = S.B.readbuf or S.B.read
	local d = rd(S.get(m.fid), m.off, n)

	-- a backend that answered with bytes of its own hands them over
	-- rather than having them copied into the reply. A buffer it may
	-- not give away -- a view onto a cache -- travels as bytes, which
	-- is what a string would have done anyway.
	if buf.is(d) and d:movable() then
		return { data = { __buf = d } }
	end
	return { data = d }
end

function ops.write(S, m)
	return { n = S.B.write(S.get(m.fid), m.off, m.data) }
end

function ops.readdir(S, m)
	return { ents = S.B.readdir(S.get(m.fid)) }
end

-- clunk never fails and never replies, matching dev.clunk. the client
-- sends it from a finalizer as well as from close(), so it must not
-- care whether the fid is still there.
-- remove the file a fid names, and clunk the fid either way.
--
-- 9P's Tremove, including the part that is easy to get wrong: the fid
-- is spent whether or not the remove succeeded, because the client has
-- no way to find out which and would otherwise leak one on every
-- refusal. The error still comes back.
--
-- A backend that has no remove says Enotimpl rather than pretending:
-- src/dev.c marks it optional, and a client that cannot tell a
-- refusal from a success would report a file gone that is still there.
function ops.remove(S, m)
	local h = S.fids[m.fid]

	if h == nil then
		dev.error(dev.Ebadfid)
	end
	S.fids[m.fid] = nil
	if not S.B.remove then
		pcall(S.B.clunk, h)
		dev.error(dev.Enotimpl)
	end

	local ok, err = pcall(S.B.remove, h)

	pcall(S.B.clunk, h)
	if not ok then
		error(err, 0)
	end
	return { ok = true }
end

-- the name, on a fid the client keeps: unlike remove, a wstat does not
-- spend it, so the file goes on being reachable through it.
function ops.wstat(S, m)
	local h = S.fids[m.fid]

	if h == nil then
		dev.error(dev.Ebadfid)
	end
	if not S.B.wstat then
		dev.error(dev.Enotimpl)
	end
	S.B.wstat(h, { name = m.name })
	return { ok = true }
end

-- two directory fids, so this is the move 9P has no message for. The
-- server holds both ends, which is what makes it one operation.
function ops.rename(S, m)
	local src, dst = S.fids[m.fid], S.fids[m.newfid]

	if src == nil or dst == nil then
		dev.error(dev.Ebadfid)
	end
	if not S.B.rename then
		dev.error(dev.Enotimpl)
	end
	S.B.rename(src, m.name, dst, m.newname)
	return { ok = true }
end

function ops.clunk(S, m)
	local h = S.fids[m.fid]

	if h then
		S.fids[m.fid] = nil
		pcall(S.B.clunk, h)
	end
end

-- session: hand back a right to the same backend with its own fid space.
--
-- one fid table per client, which is what 9P gets from having one per
-- connection. a shared table lets a client name another client's fid by
-- guessing a small integer, and ports carry no sender identity, so the
-- server cannot tell whose fid it is being handed -- a separate port per
-- client is the only place that distinction can live.
--
-- the establishment port answers this and readonly; fid operations
-- belong to a session, so a client cannot keep using the shared space by
-- accident.
function ops.session(S)
	local ro = S.ro
	local recv = sys.newport("srv.recv")
	local port = sys.sendright(recv)

	-- the session inherits the window, and this is the serve that
	-- actually needs it: the establishment port answers session and
	-- readonly, which do not block, while every read and walk a client
	-- makes arrives here.
	thread.spawn(function()
		M.serve(ro and require("devtree").readonly(S.B) or S.B, recv,
		    { establish = false, workers = S.workers,
		      lock = S.lock })
		-- serve returns when the client has gone. Closed by this
		-- thread, the one that was parked on it, rather than by
		-- whoever called session.
		sys.close(recv)
	end)

	-- the second return is closed once the reply has been sent. the
	-- transfer gives the client its own right, so ours is surplus --
	-- and keeping it would hold the port's reference count at two, so
	-- sys.hungup would never fire and the serve thread above would
	-- outlive the client that asked for it.
	return { port = { __right = port } }, port
end

-- readonly: hand back a right to the same backend, served read-only.
--
-- attenuation, and it needs no capability check because it cannot
-- escalate: what comes back is strictly weaker than the right used to
-- ask. so anyone holding a mount may mint a read-only one and pass that
-- on instead, which is how a filesystem gets served at two authority
-- levels with no permission bit anywhere -- the difference is which
-- right you hold.
--
-- one port per server, made on first request and shared. the read-only
-- view has its own fid space, so a holder cannot reach a writable fid by
-- guessing a number in the read-write server's space.
function ops.readonly(S)
	if not S.roport then
		local recv = sys.newport("srv.recv")

		-- send only for the client. {__right=} copies the recv flag,
		-- so handing out the port as created would let a holder
		-- receive on it and take another client's requests.
		S.roport = sys.sendright(recv)
		thread.spawn(function()
			-- an establishment port for the read-only view, so
			-- readonly then session composes and the read-only
			-- clients get private fid spaces too.
			--
			-- this loop never sees a hangup: we hold two rights to
			-- the port ourselves, so nrights never falls to one.
			-- it lives as long as the server proc.
			M.serve(S.B, recv,
			    { ro = true, workers = S.workers,
			      lock = S.lock })
		end)
	end
	return { port = { __right = S.roport } }
end

local NOREPLY = { clunk = true }

-- what an establishment port answers. everything else there is
-- Enotimpl: fid operations need a session, whose fid space is its own.
local ESTABLISH = { session = true, readonly = true }

-- ---- the server ----

local function newstate(backend, opts)
	local S = {
		B = backend, fids = {}, next = 1,
		ro = opts and opts.ro or false,
		-- carried so a session serve started from ops.session gets
		-- the same window the establishment serve was given
		workers = opts and opts.workers or 0,
		-- One worker means one thread of control over the backend,
		-- and that has to hold across every loop reachable from this
		-- one: ops.session spawns a second serve on the same backend,
		-- so two loops end up calling into it, and a backend that is
		-- mid-park in one of them is a backend the other must not
		-- enter. The lock is made here and passed down, so all of
		-- them queue on the same one.
		lock = (opts and opts.lock) or lock.new(),
		-- establishment unless told otherwise, so a plain
		-- serve(backend, port) is what a server wants and only srv
		-- itself makes the other kind
		establish = not opts or opts.establish ~= false,
		-- opts.other(m, reply) -> handled. A server may answer ops
		-- that are not file ops on the same port; it owns the reply
		-- right if it takes the message.
		other = opts and opts.other,
	}

	function S.put(h)
		local fid = S.next

		S.next = fid + 1
		S.fids[fid] = h
		return fid
	end

	function S.get(fid)
		local h = S.fids[fid]

		if h == nil then
			dev.error(dev.Ebadfid)
		end
		return h
	end

	return S
end

-- one message. the reply right is closed on every path including the
-- error and unknown-op ones, so a malformed request cannot leak a right
-- into the server for the rest of its life.
local function dispatch(S, m)
	local reply = type(m) == "table" and type(m.reply) == "table" and
	    m.reply.__right or nil
	local fn = type(m) == "table" and ops[m.op] or nil

	if fn and S.establish and not ESTABLISH[m.op] then
		fn = nil
	end
	if fn and not S.establish and ESTABLISH[m.op] then
		fn = nil
	end
	if not fn then
		if S.other and S.other(m, reply) then
			return
		end
		if reply then
			sys.send(reply, { err = dev.Enotimpl, seq = m.seq })
			sys.close(reply)
		end
		return
	end

	local ok, res, tmp = pcall(fn, S, m)

	if reply and not NOREPLY[m.op] then
		local out

		if ok then
			out = res or {}
		else
			-- the message crosses the port as a bare string and
			-- mnt re-raises it, which is what makes an error from
			-- another proc indistinguishable from a local one.
			out = { err = tostring(res) }
		end
		-- echoed, never interpreted. it is the client's own marker
		-- for "this answer is the one I am still waiting for"; the
		-- server keeps no state about it, which is exactly what
		-- distinguishes it from a 9P tag.
		out.seq = m.seq

		-- a reply that cannot be sent must still be answered.
		--
		-- sys.send raises if the message will not serialize -- too
		-- large, or carrying something it cannot encode -- and this
		-- call is outside the pcall above because it is the reply to
		-- that pcall's result. Left bare, such a failure returned
		-- from dispatch having sent nothing, and the client waited
		-- for an answer that was never coming: a hang, in the one
		-- place where the whole point is that errors come back as
		-- Rerror. So the failure is caught and reported as one.
		--
		-- the fallback carries only a string, so the thing that
		-- could not be encoded is not in it.
		local sent = pcall(sys.send, reply, out)

		if not sent and not NOREPLY[m.op] then
			pcall(sys.send, reply,
			    { err = dev.Eio .. ": reply too large to send",
			      seq = m.seq })
		end
	end
	if reply then
		sys.close(reply)
	end
	-- after the reply, so the right is still ours while it is being
	-- transferred out
	if ok and tmp then
		sys.close(tmp)
	end
end

M.dispatch = dispatch

-- every fid this loop still holds, released.
--
-- A client that goes away without clunking is the ordinary case, not
-- the exception: it was killed, or it died, or it simply exited holding
-- an open file. 9P closes a connection's fids when the connection ends
-- for that reason, and a backend that keeps anything per handle needs
-- the same. An exclusive device is where it shows first -- one
-- interrupted reader of a device and nothing can open it
-- again until the server proc is restarted.
local function clunkall(S)
	for fid, h in pairs(S.fids) do
		S.fids[fid] = nil
		pcall(S.B.clunk, h)
	end
end

-- serve `backend` on `port` until every client has gone away.
--
-- this parks rather than spinning: tryrecv, and if there is nothing,
-- either notice the hangup or block. sys.close wakes blocked receivers
-- precisely so the hangup case is reachable without a poll.
-- serve(backend, port, opts)
--
-- an establishment port by default: it answers session and readonly and
-- nothing else, and the sessions it hands out carry the fid spaces.
-- opts.establish = false is srv's own use, for a session port.
-- opts.ro makes the sessions it hands out read-only views.
--
-- opts.workers = N dispatches each message in its own thread, up to N
-- at once, instead of one at a time. Off by default, and it should stay
-- off for a backend whose calls do not block: a local one answers
-- inside dispatch without ever yielding, so a thread per message would
-- buy nothing and cost a coroutine.
--
-- It is for a backend that waits on something. lib/p9fs.lua does -- its
-- every call is a round trip to the device -- and serially that meant a
-- client's Nth concurrent read waited for the N-1 before it, however
-- many the transport could actually have had in flight (see
-- VIRTIO_9P_SLOTS). The reply port travels in the message, so a worker
-- needs nothing from the loop to answer.
--
-- Bounded because the alternative is a coroutine per queued message and
-- no limit on how many that is. N is a window, not a thread count worth
-- tuning: past the transport's own depth the extra workers only queue.
function M.serve(backend, port, opts)
	dev.check(backend, "srv backend")

	local S = newstate(backend, opts)
	local workers = opts and opts.workers or 0

	-- opts.tick = { ms = , fn = function(backend) end } asks for fn to be
	-- run between requests, at most every ms, and once more as the server
	-- shuts down. It is how a backend that has to flush on a clock -- gefs
	-- syncing its cache -- gets a heartbeat without a thread of its own: a
	-- second thread calling into the backend would run concurrently with a
	-- request and defeat the whole point of one worker. Here it is the same
	-- loop, so fn and dispatch never overlap. This is plan 9 gefs's own
	-- shape, where the 5-second timer only enqueues a sync for the single
	-- mutator to run in turn (runtasks in fs.c), never syncs itself.
	local tick = opts and opts.tick

	if workers < 2 then
		-- thread.await is the drain-then-test-hangup loop this used to
		-- write out by hand, and the hangup half is the same question
		-- lib/mnt.lua asks on the other side of the port: our right is
		-- the last one, so every client has gone. the reason to answer
		-- it from `why` rather than from the message being nil is that
		-- a message legitimately can be.
		--
		-- with a tick, recvtimeout stands in for await: it is alt over
		-- the port and a timer, so a request is still drained first and a
		-- timeout is the heartbeat. hangup is not a message the alt wakes
		-- on, so it is tested after each tick -- the shutdown flush lands
		-- there, at most one interval late.
		-- One worker is one thread of control over the backend, and
		-- one loop cannot deliver that by itself: ops.session spawns
		-- a second serve on the same backend, so the tick fires in
		-- this loop while a client request is being served in that
		-- one. Both park constantly -- every block gefs reads is a
		-- round trip -- and parking is exactly when the other loop
		-- gets to run, so the two interleave inside an unlocked
		-- filesystem. The lock is per backend, made in newstate and
		-- passed down to every serve reachable from it.
		--
		-- Held across the call rather than around it, for the same
		-- reason: what has to be indivisible is the whole request,
		-- parks included.
		local function serialized(fn, arg)
			S.lock:lock()
			local ok, err = pcall(fn, S, arg)
			S.lock:unlock()
			if not ok then
				error(err, 0)
			end
		end

		while true do
			if tick then
				local m, why = thread.recvtimeout(port, tick.ms)

				if why then
					serialized(function(st)
						tick.fn(st.B)
					end)
					if sys.hungup(port) then
						clunkall(S)
						return
					end
				else
					serialized(dispatch, m)
				end
			else
				local m, why = thread.await(port)

				if why then
					if backend.hangup then
						pcall(backend.hangup)
					end
					clunkall(S)
					return
				end
				serialized(dispatch, m)
			end
		end
	end

	-- Nothing here takes S.lock. Asking for a window is asking for
	-- requests to overlap, so a backend given one must already be
	-- reentrant, and serializing it would answer a question the caller
	-- did not ask.
	--
	-- the window IS the permits: a worker holds one for as long as it
	-- runs, so there is no count to keep in step with anything and no
	-- way to be inside the window without holding one. The version
	-- this replaces carried its own counter and a reaping loop, and a
	-- comment about the deadlock waiting for whoever got the buffering
	-- wrong.
	local slots = sema.new(workers)

	local function inflight()
		return workers - slots:free()
	end

	while true do
		local ok, m = sys.tryrecv(port)

		if ok then
			-- at capacity this parks until a worker hands one
			-- back, which is the whole of "do not spawn past the
			-- window".
			slots:acquire()
			thread.spawn(function()
				-- dispatch already answers errors to the
				-- client; this only keeps one failed request
				-- from taking the slot with it
				pcall(dispatch, S, m)
				slots:release()
			end)
		elseif sys.hungup(port) then
			-- a parked read waits on the client that has just
			-- gone, so it must be released before the permits
			-- are counted -- it holds one.
			if backend.hangup then
				pcall(backend.hangup)
			end
			-- clients are gone, but requests already taken off
			-- the port still have replies owed to them. Taking
			-- every permit is how you wait for every worker.
			for _ = 1, workers do
				slots:acquire()
			end
			clunkall(S)
			return
		elseif inflight() > 0 then
			-- workers are runnable, so parking the whole proc on
			-- the port would stop them. thread.yield gives them the
			-- cpu without parking: this loop goes to the back of
			-- the run queue and comes round again. A bare
			-- coroutine.yield() would not -- the scheduler reads
			-- that as the count hook cutting us and hands the cpu
			-- straight back, which here is a spin.
			thread.yield()
		else
			thread.park(port)
		end
	end
end

-- run as a whole proc: serve on our own receive port, so the right
-- sys.spawn handed our parent is the mount. build() constructs the
-- backend inside the server proc, which is the only place it can be
-- constructed -- a backend is a table of closures and does not travel.
-- note thread.run() takes no argument -- it drives whatever is already
-- in the runq -- so the serve loop has to be spawned first. running
-- under the thread scheduler rather than at the top level is what lets
-- a server proc do anything else at the same time; serve() itself parks
-- through thread.park, which works either way.
-- opts is passed through to M.serve; opts.workers is the one a driver
-- task is likely to want (see the note there).
function M.main(build, opts)
	thread.spawn(function()
		M.serve(build(), sys.SELF, opts)
	end)
	thread.run()
end

return M
