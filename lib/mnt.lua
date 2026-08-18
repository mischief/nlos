-- mnt: a dev backend that forwards to a server on a port.
--
-- plan 9's devmount. lib/srv.lua is the other half; the protocol and
-- the argument for it are documented there. this side is deliberately
-- boring: every method is the same round trip, so the interesting
-- content is the four things that are NOT just a round trip.
--
-- ---- one: a mount is a right, so a namespace is finally a capability ----
--
-- ns:describe() previously shipped a RECIPE -- kind plus constructor
-- args -- and that only worked because every backend so far derives
-- from something ambient: espfs from the ESP, procfs from sys.procs.
-- a backend whose state lives in another proc cannot be rebuilt from a
-- recipe at all, and ns.lua:541 says so.
--
-- the "mnt" kind's args carry {port={__right=h}}, and rights are COPIED
-- on transfer rather than moved (see the 'R' case in kernel.c's
-- serializer), so describe() can be called any number of times and each
-- child gets its own right to the same server. that is plan 9's
-- sentence exactly: what you send is not the Chan, it is the channel to
-- the server.
--
-- ---- two: errors ----
--
-- the server replies {err="file does not exist"} and this side re-raises
-- it with dev.error, so an error from another proc arrives at ns.lua's
-- pcall indistinguishable from a local one. bare strings, no position
-- prefix, 9front's spellings -- which is also exactly what would come
-- back as an Rerror if this were a wire.
--
-- ---- three: fids are finalized ----
--
-- ns:walk() calls attach() and walks each element without clunking the
-- intermediates. locally that costs a garbage table. over a port it
-- would be a permanent fid leak in the SERVER, one per path element per
-- lookup, which nothing could ever collect.
--
-- so a mnt handle carries __gc that clunks. lua's collector is the only
-- thing here that knows the intermediate handles are unreachable, and
-- clunk being fire-and-forget is what makes it safe to send from a
-- finalizer. dev.closable copies existing metatable fields, so an
-- opened handle keeps its finalizer alongside __close.
--
-- ---- four: a whole path in one round trip ----
--
-- walkmany is 9P's Twalk, and dev.walkpath prefers it when a backend
-- offers one. it also means no intermediate fid exists on this side at
-- all: the server makes them and knows when they die, so the finalizer
-- above has nothing to collect for a multi-element walk.

local sys = require("los.sys")
local thread = require("los.thread")
local once = require("sync.once")
local dev = require("dev")

local M = {}

-- this transport's msize (dev.IOUNIT), which lib/srv.lua clamps to on
-- the far side as well.
local IOUNIT = dev.IOUNIT

-- ONE counter for the whole proc, not one per mount. the reply port is
-- per thread and shared across every mount that thread uses, so two
-- mounts numbering their own requests would collide on it -- mount A's
-- abandoned #5 would look exactly like mount B's pending #5.
local seq = 0

local function nextseq()
	seq = seq + 1
	return seq
end

-- new(right) -> a dev backend speaking to the server holding `right`.
function M.new(right)
	local B = {}

	-- the reply port belongs to the CALLING THREAD, not to this mount
	-- (thread.replyport). so two threads using one mount do not
	-- serialise: each sends immediately and waits on its own port, and
	-- the server sees both requests queued instead of being told about
	-- the second only after the first round trip has finished.
	--
	-- plan 9's Mnt cannot do this. it has one channel to the server, so
	-- it needs tags plus a lock plus a queue of Mntrpc to sort the
	-- replies back out. ports are cheap enough to give one to each
	-- caller instead, which deletes the demultiplexer rather than
	-- reimplementing it.
	-- the right this mount actually talks to. `right` is an
	-- establishment port; the session it hands back has a fid space of
	-- its own, so no other client of the same server can name our fids.
	--
	-- opened on first use rather than in M.new, because ns:mount runs
	-- dev.check before any traffic and the server need not be answering
	-- yet at mount time.
	--
	-- Several threads touching a cold mount at once must still open
	-- ONE session -- each has a fid space of its own, so the last
	-- assignment would win and every fid the others minted would name
	-- nothing, permanently, since the namespace caches the root handle
	-- it walked from. sync.once is that, and carries the story.
	local session = once.new()

	local function establish(msg)
		local reply, send = thread.replyport()

		msg.seq = nextseq()
		msg.reply = { __right = send }

		-- the pcall catches a bad or closed right, which raises;
		-- everything thread.call REPORTS -- a dead or full port, a
		-- hangup -- comes back as a nil below.
		--
		-- a full queue waits for room, as in rpc below; see there
		-- for why the retry belongs to the caller.
		local ok, res, why, need

		repeat
			ok, res, why, need =
			    pcall(thread.call, right, msg, reply)
			if not ok then
				dev.error(dev.Eio)
			end
			if res == nil and why == "full" then
				thread.parksend(right, need)
			end
		until res ~= nil or why ~= "full"
		while true do
			if type(res) ~= "table" then
				dev.error(dev.Eio)
			end
			if res.seq == msg.seq then
				if res.err then
					dev.error(res.err)
				end
				if type(res.port) ~= "table" or
				    not res.port.__right then
					dev.error(dev.Enotimpl)
				end
				return res.port.__right
			end
			res = thread.await(reply)
		end
	end

	local function getsession()
		return session:get(function()
			return establish({ op = "session" })
		end)
	end

	local function rpc(msg)
		local sess = getsession()
		local reply, send = thread.replyport()

		msg.seq = nextseq()
		msg.reply = { __right = send }

		-- the send and the wait as one operation, and at the top level
		-- as one kernel entry (sys.call). inside a thread it is a send
		-- plus the scheduler's own block, which is already fused
		-- across every parked thread -- los.thread's call() explains
		-- why that leaves nothing on the table.
		--
		-- BOTH failure kinds still matter, and they arrive separately.
		-- the pcall catches a bad or closed right, which RAISES; a
		-- dead or full port is REPORTED as a nil. checking only the
		-- pcall would treat an undelivered request as sent and then
		-- wait forever for a reply nobody will send.
		--
		-- ---- and this is where a dead server is noticed ----
		--
		-- the third reported failure is a hangup, and it is the one
		-- worth spelling out. while a request is in flight the reply
		-- port has TWO rights: ours, and the one that travelled with
		-- the message. the serializer counts the in-flight one
		-- immediately, so the second right exists from the moment we
		-- send.
		--
		-- so if it drops back to one and there is nothing queued,
		-- nobody can ever reply: either the server answered and closed
		-- (drained first), or it died and proc_kill released its
		-- rights. that is the same test lib/srv.lua uses to know its
		-- last client left, and it now lives in call/await rather than
		-- being made by hand after each wake.
		--
		-- it is not a timeout, deliberately. a slow backend is not a
		-- broken one, and no deadline can tell them apart -- but the
		-- port's reference count can. dropping a right also WAKES
		-- blocked receivers (port_unref), so this costs no polling: we
		-- are woken by the very event we are looking for.
		--
		-- this matters more than it looks. the ESP is a server proc
		-- now, so it is every proc's filesystem; without this its
		-- death parked the entire machine with no diagnostic.
		-- a full queue is backpressure, not a failure. thread.call
		-- reports it as a third value, with the size it could not
		-- fit as a fourth, and this waits for that much room and
		-- sends again.
		--
		-- Retried here rather than inside thread.call because the
		-- policy belongs to the caller. A server must never wait on
		-- a client that stopped reading. A client waiting for room
		-- on the server it is talking to is what backpressure means.
		--
		-- thread.parksend waits on the calling coroutine alone, so
		-- a client's other threads keep working. The send is
		-- repeated whole, seq included: the refused one never
		-- reached the port.
		local ok, res, why, need

		repeat
			ok, res, why, need =
			    pcall(thread.call, sess, msg, reply)
			if not ok then
				dev.error(dev.Eio)	-- closed, or not a right
			end
			if res == nil and why == "full" then
				thread.parksend(sess, need)
			end
		until res ~= nil or why ~= "full"
		while true do
			if type(res) ~= "table" then
				dev.error(dev.Eio)	-- undelivered, or nobody left
			end
			if res.seq == msg.seq then
				if res.err then
					dev.error(res.err)
				end
				return res
			end
			-- a NON-matching reply belongs to a request this
			-- thread abandoned -- today only possible if an error
			-- (a memory cap, say) unwinds between the send and the
			-- recv. dropping it is the difference between one lost
			-- call and every later call reading the previous one's
			-- answer.
			--
			-- note this is NOT a tag: nothing routes on it, no
			-- table maps it to a waiter. it only says "not mine".
			res = thread.await(reply)
		end
	end

	-- a handle is {fid=n}, finalized. clunk clears fid so an explicit
	-- close and a later collection do not clunk twice -- harmless on
	-- the server, but it would send a message per collected handle
	-- forever.
	local fidmt = {
		__gc = function(h)
			-- peek, not get: a handle collected before anything
			-- ever established a session has nothing to clunk,
			-- and asking would open one in order to tear it down.
			local sess = session:peek()

			if h.fid and sess then
				pcall(sys.send, sess,
				    { op = "clunk", fid = h.fid })
				h.fid = nil
			end
		end,
	}

	local function h_of(fid)
		return setmetatable({ fid = fid }, fidmt)
	end

	function B.attach()
		return h_of(rpc({ op = "attach" }).fid)
	end

	function B.walk(h, name)
		return h_of(rpc({ op = "walk", fid = h.fid, name = name }).fid)
	end

	-- the whole path in one round trip: 9P's Twalk, and the reason
	-- dev.walkpath asks for it. it also means no intermediate fid ever
	-- exists on THIS side -- the server makes them, and knows exactly
	-- when they die, so the finalizer has nothing to collect.
	function B.walkmany(h, names)
		return h_of(rpc({ op = "walkmany", fid = h.fid,
		    names = names }).fid)
	end

	function B.stat(h)
		return rpc({ op = "stat", fid = h.fid }).st
	end

	function B.open(h, mode)
		local r = rpc({ op = "open", fid = h.fid, mode = mode })

		return dev.closable(B, h_of(r.fid))
	end

	function B.create(h, name, mode, dir)
		local r = rpc({ op = "create", fid = h.fid, name = name,
		    mode = mode, dir = dir })

		return dev.closable(B, h_of(r.fid))
	end

	-- chunked to what a port message can carry, by dev.readloop /
	-- dev.writeloop -- see their comment, which is the whole argument.
	-- a caller may ask this mount for a megabyte and get one; nothing
	-- above here knows how many round trips that took, and the backend
	-- on the far side is never asked for more than IOUNIT.
	local function readraw(h, off, n, raw)
		return dev.readloop(IOUNIT, function(o, c)
			return rpc({ op = "read", fid = h.fid, off = o,
			    n = c }).data
		end, off, n, raw)
	end

	function B.read(h, off, n)
		return readraw(h, off, n, false)
	end

	-- the same read, keeping a buffer the server gave away instead of
	-- making a string of it. For a caller that is going to work on the
	-- bytes -- a filesystem holding sectors -- where a string would be
	-- copied once to make and once to use.
	function B.readbuf(h, off, n)
		return readraw(h, off, n, true)
	end

	function B.write(h, off, data)
		return dev.writeloop(IOUNIT, function(o, chunk)
			return rpc({ op = "write", fid = h.fid, off = o,
			    data = chunk }).n
		end, off, data)
	end

	function B.readdir(h)
		return rpc({ op = "readdir", fid = h.fid }).ents
	end

	-- ask the server for a read-only right to the same tree. not a dev
	-- method -- it is attenuation, not filesystem access -- so it rides
	-- alongside rather than being part of the interface dev.check tests.
	-- goes to the establishment port, not the session: it is
	-- attenuation of the mount, not an operation on a fid.
	function B.readonly()
		return establish({ op = "readonly" })
	end

	-- release the session. ns:unmount calls this, which is what lets a
	-- server notice its last client has gone: while we hold the session
	-- right the port's reference count stays above one and the serve
	-- thread on the far side never sees a hangup.
	--
	-- the metatable is a backstop for a mount dropped without being
	-- unmounted, since the collector is then the only thing that knows.
	function B.close()
		local sess = session:peek()

		if sess then
			pcall(sys.close, sess)
			session:reset()
		end
	end

	setmetatable(B, { __gc = function() B.close() end })

	-- fire and forget, matching dev.clunk's "never fails". no reply
	-- means no round trip, which is what makes it safe from __gc.
	-- the fid is spent either way, so it is forgotten here before the
	-- reply is looked at: the server has already dropped it, and a
	-- later clunk of the same number would be clunking whatever the
	-- server has since put there.
	function B.remove(h)
		local fid = h.fid

		h.fid = nil
		rpc({ op = "remove", fid = fid })
	end

	-- the fid survives, so unlike remove it is not forgotten here.
	function B.wstat(h, st)
		if not st or st.name == nil then
			return true
		end
		rpc({ op = "wstat", fid = h.fid, name = st.name })
		return true
	end

	-- both directories are fids of this one server, so the move it
	-- cannot express over 9P it can express over a port.
	function B.rename(dsrc, name, ddst, newname)
		rpc({ op = "rename", fid = dsrc.fid, newfid = ddst.fid,
		    name = name, newname = newname })
		return true
	end

	function B.clunk(h)
		local sess = session:peek()

		if h.fid and sess then
			pcall(sys.send, sess, { op = "clunk", fid = h.fid })
			h.fid = nil
		end
	end

	return B
end

-- readonly(right) -> a right to the same server, read-only.
--
-- for a caller that wants to hand the weaker right on without mounting
-- anything itself.
function M.readonly(right)
	return M.new(right).readonly()
end

return M
