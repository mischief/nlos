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
-- interface (see lib/dev.lua, which was shaped fid-first for exactly
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
--   msize        the serializer's own limits already bound a message.
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

local M = {}

-- ---- the ops ----
--
-- each is the dev call, verbatim. they RAISE on failure, because the
-- backend raises and nothing in between should be checking -- the one
-- pcall is in dispatch(), which is this module's syscall entrypoint in
-- exactly the sense lib/dev.lua describes.

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
	return { fid = S.put(S.B.create(S.get(m.fid), m.name, m.mode)) }
end

function ops.read(S, m)
	return { data = S.B.read(S.get(m.fid), m.off, m.n) }
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
	local recv = sys.newport()
	local port = sys.sendright(recv)

	-- the session inherits the window, and this is the serve that
	-- actually needs it: the establishment port answers session and
	-- readonly, which do not block, while every read and walk a client
	-- makes arrives here.
	thread.spawn(function()
		M.serve(ro and dev.readonly(S.B) or S.B, recv,
		    { establish = false, workers = S.workers })
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
		local recv = sys.newport()

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
			M.serve(S.B, recv, { ro = true, workers = S.workers })
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
		-- establishment unless told otherwise, so a plain
		-- serve(backend, port) is what a server wants and only srv
		-- itself makes the other kind
		establish = not opts or opts.establish ~= false,
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
		sys.send(reply, out)
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

	if workers < 2 then
		-- thread.await is the drain-then-test-hangup loop this used to
		-- write out by hand, and the hangup half is the same question
		-- lib/mnt.lua asks on the other side of the port: our right is
		-- the last one, so every client has gone. the reason to answer
		-- it from `why` rather than from the message being nil is that
		-- a message legitimately can be.
		while true do
			local m, why = thread.await(port)

			if why then
				return
			end
			dispatch(S, m)
		end
	end

	-- buffered to the worker count so a finishing worker never blocks
	-- handing its slot back, which would deadlock it against a loop
	-- that is itself waiting for a slot.
	local done = thread.chancreate(workers)
	local inflight = 0

	local function reap(block)
		if block and inflight > 0 then
			done:recv()
			inflight = inflight - 1
		end
		while inflight > 0 do
			local got = done:nbrecv()

			if not got then
				break
			end
			inflight = inflight - 1
		end
	end

	while true do
		reap(false)

		local ok, m = sys.tryrecv(port)

		if ok then
			-- at capacity: wait for a worker rather than spawning
			-- past the window
			if inflight >= workers then
				reap(true)
			end
			inflight = inflight + 1
			thread.spawn(function()
				-- dispatch already answers errors to the
				-- client; this only keeps one failed request
				-- from taking the slot with it
				pcall(dispatch, S, m)
				done:send(true)
			end)
		elseif sys.hungup(port) then
			-- clients are gone, but requests already taken off
			-- the port still have replies owed to them
			while inflight > 0 do
				reap(true)
			end
			return
		elseif inflight > 0 then
			-- workers are runnable, so parking the whole proc on
			-- the port would stop them. A bare yield is what
			-- thread.run treats as "still runnable" -- the same
			-- path a preempted thread takes -- so this goes back
			-- on the run queue rather than into _parked.
			coroutine.yield()
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
