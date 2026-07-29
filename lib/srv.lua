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

local NOREPLY = { clunk = true }

-- ---- the server ----

local function newstate(backend)
	local S = { B = backend, fids = {}, next = 1 }

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

	if not fn then
		if reply then
			sys.send(reply, { err = dev.Enotimpl, seq = m.seq })
			sys.close(reply)
		end
		return
	end

	local ok, res = pcall(fn, S, m)

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
end

M.dispatch = dispatch

-- serve `backend` on `port` until every client has gone away.
--
-- this parks rather than spinning: tryrecv, and if there is nothing,
-- either notice the hangup or block. sys.close wakes blocked receivers
-- precisely so the hangup case is reachable without a poll.
function M.serve(backend, port)
	dev.check(backend, "srv backend")

	local S = newstate(backend)

	while true do
		local ok, m = sys.tryrecv(port)

		if ok then
			dispatch(S, m)
		elseif sys.hungup(port) then
			return
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
function M.main(build)
	thread.spawn(function()
		M.serve(build(), sys.SELF)
	end)
	thread.run()
end

return M
