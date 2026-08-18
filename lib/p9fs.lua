-- p9fs: a dev backend (see src/dev.c) over a real 9P2000.u
-- connection -- los.platform.p9's virtio-9p transport, decoded with
-- lib/ninep.lua's client half.
--
-- lib/p9srv.lua serves this on a port (lib/srv.lua) exactly the way
-- lib/espsrv.lua serves the esp. there is no bridging to do here
-- beyond speaking the wire and re-presenting it as the same dev
-- interface every other backend already uses: virtio-9p IS a 9P
-- server, at the wire level, before any of our code runs. mnt.lua
-- neither knows nor cares what is on the other end -- there is only
-- ever one namespace mechanism, this is just another backend for it.
--
-- one virtio-9p CONNECTION (fid 0, attached once in M.new) serves
-- every client of this task's port; each dev handle gets its OWN
-- cloned fid (a zero-element Twalk) so that clunking a handle -- which
-- happens constantly, e.g. every __gc on the mnt.lua side -- can never
-- take down the shared root fid every other session also depends on.

local ninep = require("ninep")
local dev = require("dev")
local sys = require("los.sys")
local thread = require("los.thread")
local buf = require("los.buf")

local M = {}

local err = dev.error

-- `tag` is the one the request went out under; nil skips the check,
-- which is what the version handshake does since it uses NOTAG.
local function checkreply(rep, wanttype, what, tag)
	local m = ninep.decode(rep)

	if tag and m.tag ~= tag then
		err(what .. ": reply tagged " .. tostring(m.tag) ..
		    ", wanted " .. tostring(tag))
	end
	if m.type == ninep.Rerror then
		err(m.ename)
	end
	if m.type ~= wanttype then
		err(what .. ": unexpected reply type " .. tostring(m.type))
	end
	return m
end

-- ---- two shapes of transport, and why the difference is not ours ----
--
-- ROUTED: {rpc = function(reqbytes) return replybytes end}. The reply
-- returned IS the reply to that request. los.platform.p9 is this: it
-- keeps a window of slots and the device answers into the slot's own
-- buffer, so routing is positional and no tag is ever read. The
-- self-mount loopback in test/boot/test_ninep_selfmount.lua is this
-- too, trivially, since it computes the answer inline.
--
-- STREAM: {send = function(bytes), recv = function() return frame end}.
-- One channel, replies interleaved in whatever order the server chose,
-- and nothing but the tag to say whose is whose. recv returns exactly
-- one complete frame, or nil at end of connection -- de-framing belongs
-- to whatever owns the byte stream, since that is where the partial
-- reads live.
--
-- The mux for the second lives HERE rather than in the transport,
-- because the tag it routes on is allocated here. Splitting them would
-- mean the transport had to learn a number this file chose -- by
-- parsing it back out of the bytes, or by being handed it -- and then
-- two places would have to agree about tag lifetime for no benefit.
--
-- Note this is the demultiplexer lib/mnt.lua deliberately does not
-- have. It is not a failure to reproduce that trick: mnt can give every
-- caller its own port, and a byte stream is one channel that cannot be
-- subdivided. The tag exists precisely because of that, and this is the
-- one layer where it earns its keep -- above, in the routed case, it is
-- only an assertion.
-- opts.timeout: milliseconds before a request is given up on and
-- flushed. Stream transports only, and off by default -- a slow server
-- is not a broken one, and the right deadline is the caller's to know.
-- Meaningless for a routed transport, where the wait lives inside the
-- transport and there is no tag to flush.
function M.new(transport, opts)
	local p9 = transport or require("los.platform.p9")
	local timeout = opts and opts.timeout
	local B = {}
	local next_fid = 1

	-- a 9P tag has to be unique among OUTSTANDING requests, and no
	-- more than that -- it exists so a reply can be matched to its
	-- request. This used to be the constant 1, which was true enough
	-- when the transport held one request at a time and every rpc was
	-- therefore the only one in flight.
	--
	-- It no longer is: los.platform.p9 keeps a window of them (see
	-- VIRTIO_9P_SLOTS), so two threads of this task can be waiting on
	-- the device at once and a shared tag would make their replies
	-- indistinguishable to any server that looked.
	--
	-- Held only for the duration of the call, so the table never grows
	-- past the window. Note that nothing here routes on the tag: the
	-- transport answers into the slot the request was started in, so
	-- rpc() below verifies the tag rather than dispatching on it, and
	-- a mismatch is a transport bug rather than a race to recover
	-- from.
	local intag = {}
	local nexttag = 0

	-- a tag abandoned mid-flight is never handed out again, because the
	-- reply to it may still be coming and would then be delivered to
	-- whichever request got the number next. Only reachable when
	-- something unwinds between the send and the receive -- an error in
	-- a sibling that kills the thread, say -- but the failure it
	-- prevents is one call silently answering with another's data,
	-- which is not a thing to leave to chance.
	--
	-- Bounded: a poisoned tag is retired by the reply that eventually
	-- arrives for it (see deliver below), so this cannot grow without
	-- the server having lost a reply outright.
	local poisoned = {}

	-- the search and the claim need nothing between them: a thread is
	-- not switched away from except where it parks, and nothing here
	-- does. Finding t free is still true when it is marked.
	local function alloctag()
		local t = nexttag

		repeat
			t = (t % 0xfffe) + 1
			if t == nexttag then
				dev.error("9p: no free tags")
			end
		until not intag[t] and not poisoned[t]
		nexttag = t
		intag[t] = true
		return t
	end

	-- ---- the mux, for a stream transport only ----
	--
	-- pending[tag] is the waiting caller's own one-slot channel. A
	-- channel rather than resuming the coroutine directly because the
	-- reader is a thread like any other and src/thread.c's scheduler owns
	-- who runs -- handing it the value and letting the scheduler wake
	-- the waiter is the same shape lib/dos.lua joins its stages with.
	-- nil for a routed transport, a table for a stream one. Written as
	-- a statement because `p9.rpc and nil or {}` is always {}: `and
	-- nil` makes the left side falsy, so the `or` always fires.
	local pending
	local reader

	if not p9.rpc then
		pending = {}
	end

	local function deliver(frame)
		-- peek, do not decode: the waiter decodes it anyway in
		-- checkreply, and the reader has no use for the rest.
		local tag = select(3, string.unpack("<I4BI2", frame))
		local ch = pending[tag]

		if ch then
			pending[tag] = nil
			ch:send(frame)
		elseif poisoned[tag] then
			-- the late reply we were holding the tag for; it can
			-- be reused now
			poisoned[tag] = nil
		end
		-- otherwise a reply to nothing: a server bug, and dropping it
		-- is strictly better than guessing whose it might be
	end

	if pending then
		reader = thread.spawn(function()
			while true do
				local frame = p9.recv()

				if not frame then
					break		-- connection gone
				end
				deliver(frame)
			end
			-- wake everyone still waiting; their recv would
			-- otherwise never return
			for t, ch in pairs(pending) do
				pending[t] = nil
				ch:close()
			end
		end)
	end

	-- one round trip under a tag the caller already owns, on either
	-- shape of transport. Tversion needs this: it goes out under NOTAG,
	-- which is not allocated and cannot be, but on a stream it still
	-- has to be waited for through the mux -- the reader thread is
	-- already running by then and would otherwise swallow the reply.
	-- wait for one reply, or `ms` milliseconds, whichever comes first.
	-- Returns the frame, or nil on timeout, or false if the
	-- connection died under us.
	--
	-- alt rather than Channel:recv because a deadline is a port and a
	-- reply is a channel, and thread.alt is the one primitive that
	-- takes both. sys.timer's port is closed on every path -- timers
	-- are a machine-wide fixed pool (MAXTIMERS), so leaking one per
	-- timed-out request would exhaust it far sooner than the ports
	-- would.
	local function waitreply(ch, ms)
		if not ms then
			local frame, alive = ch:recv()

			if alive == false then
				return false
			end
			return frame
		end

		local timer = sys.timer(ms)

		if not timer then
			local frame, alive = ch:recv()

			if alive == false then
				return false
			end
			return frame
		end

		local which, v, alive = thread.alt({
			{ c = ch, op = "recv" },
			{ port = timer },
		})

		sys.close(timer)
		if which ~= 1 then
			return nil		-- deadline
		end
		if alive == false then
			return false
		end
		return v
	end

	-- give up on `tag`, per flush(5).
	--
	-- The Tflush carries its own tag; the server echoes THAT one, so
	-- the Rflush routes to a waiter of its own and never to the
	-- request being abandoned. Both outcomes then have to be handled,
	-- and neither is an error:
	--
	--   the original reply arrives first -- honour it. The request
	--   completed, and "completed" can mean a fid was allocated or a
	--   file created. Returning it to the caller is what keeps that
	--   fid accounted for; discarding it here would leak one on the
	--   server with nothing left holding its number.
	--
	--   the Rflush arrives first -- the transaction is cancelled and
	--   is to be treated as never sent, so there is nothing to clean
	--   up and the caller gets its timeout.
	--
	-- oldtag is not released either way until the Rflush lands: a
	-- server may still answer a flushed request, and a tag reused
	-- before then would collect someone else's reply. If the Rflush
	-- never comes the tag stays poisoned for the life of the
	-- connection, which is a bounded leak of tag space and the only
	-- safe reading of a server that has stopped answering at all.
	local function flush(oldtag, oldch, ms)
		local ftag = alloctag()
		local fch = thread.chancreate(1)

		pending[ftag] = fch
		if not pcall(p9.send, ninep.tflush(ftag, oldtag)) then
			pending[ftag] = nil
			intag[ftag] = nil
			poisoned[oldtag] = true
			return nil
		end

		local late
		local cases = {
			{ c = oldch, op = "recv" },
			{ c = fch, op = "recv" },
		}

		while true do
			local which, v, alive = thread.alt(cases)

			if which == 1 then
				if alive == false then
					break
				end
				late = v		-- honour it, but keep waiting
			else
				break			-- Rflush, or the connection went
			end
		end

		pending[ftag] = nil
		pending[oldtag] = nil
		intag[ftag] = nil
		intag[oldtag] = nil
		return late
	end

	local function rawrpc(bytes, tag)
		if not pending then
			-- a routed transport answers the request it was given,
			-- and the wait lives inside it (los.platform.p9 yields
			-- between device polls). There is no point at which
			-- this side could time out, and nothing to flush: a
			-- slot is not a tag.
			return p9.rpc(bytes)
		end

		local ch = thread.chancreate(1)

		pending[tag] = ch
		local ok, e = pcall(p9.send, bytes)

		if not ok then
			pending[tag] = nil
			error(e, 0)
		end

		local frame = waitreply(ch, timeout)

		if frame == false then
			pending[tag] = nil
			dev.error(dev.Eio)
		end
		if frame == nil then
			local late = flush(tag, ch, timeout)

			if late then
				return late
			end
			dev.error("9p: request timed out")
		end
		pending[tag] = nil
		return frame
	end

	-- build(tag) -> request bytes; returns the decoded reply, already
	-- checked. The check lives in here rather than at the call sites
	-- so that the tag never has to be threaded back out to them --
	-- which is what makes it impossible for a call site to forget it.
	local function rpc(build, wanttype, what)
		local t = alloctag()
		local ok, rep = pcall(rawrpc, build(t), t)

		-- rawrpc has already settled what happens to the tag: a
		-- completed flush frees it, a flush that could not be
		-- established poisons it. Anything else here -- a failed
		-- send, a dead connection, an Rerror -- leaves nothing
		-- outstanding to collide with.
		intag[t] = nil
		if not ok then
			error(rep, 0)
		end
		return checkreply(rep, wanttype, what, t)
	end

	-- propose .u (what qemu's virtio-9p always negotiates down to
	-- anyway); a server that only speaks base 9P2000 -- this module's
	-- own M.serve, or any generic 9P2000 fileserver -- replies
	-- "9P2000" instead, per ordinary 9P version negotiation, and dotu
	-- below drives every place after this that the two dialects
	-- differ (Tattach's n_uname, Tcreate's extension). anything else
	-- (including "unknown") is a server we can't drive at all.
	local vm = ninep.decode(rawrpc(
	    ninep.tversion(ninep.NOTAG, 8192, "9P2000.u"), ninep.NOTAG))

	if vm.type ~= ninep.Rversion or
	    (vm.version ~= "9P2000.u" and vm.version ~= "9P2000") then
		error("p9fs: version negotiation failed (" ..
		    tostring(vm.version) .. ")")
	end

	local dotu = (vm.version == "9P2000.u")

	-- the negotiated msize, which until now was proposed and then
	-- thrown away. A server may answer with less than it was offered
	-- and every Tread/Twrite after this has to respect that.
	--
	-- IOHDRSZ is plan 9's name for the 9P header a data-carrying
	-- message pays for: size[4] type[1] tag[2] fid[4] offset[8]
	-- count[4]. What is left is the most data one round trip can move,
	-- and dev.readloop/dev.writeloop turn that into a transfer of any
	-- size -- the same thing devmnt does with the same number.
	local IOHDRSZ = 24
	local msize = vm.msize

	if type(msize) ~= "number" or msize < 512 or msize > 8192 then
		msize = 8192
	end

	local iounit = msize - IOHDRSZ

	rpc(function(t)
		return ninep.tattach(t, 0, ninep.NOFID, "root", "",
		    dotu and ninep.NONUNAME or nil)
	end, ninep.Rattach, "attach")

	local function newfid()
		local f = next_fid

		next_fid = next_fid + 1
		return f
	end

	-- clone fid via a zero-element walk: every handle this backend
	-- ever hands out owns an independently-clunkable fid.
	local function clone(fid)
		local nfid = newfid()

		rpc(function(t) return ninep.tclone(t, fid, nfid) end,
		    ninep.Rwalk, "clone")
		return nfid
	end

	local function h_of(fid, isdir, name)
		return { fid = fid, isdir = isdir, name = name }
	end

	function B.attach()
		return h_of(clone(0), true, "/")
	end

	function B.walk(h, name)
		if not h.isdir then
			err(dev.Enotdir)
		end

		local nfid = newfid()
		local m = rpc(
		    function(t) return ninep.twalk(t, h.fid, nfid, { name }) end,
		    ninep.Rwalk, "walk")

		if #m.wqid ~= 1 then
			err(dev.Enonexist)
		end
		return h_of(nfid, (m.wqid[1].type & 0x80) ~= 0, name)
	end

	function B.stat(h)
		local m = rpc(function(t) return ninep.tstat(t, h.fid) end,
		    ninep.Rstat, "stat")
		local st = ninep.unpackstat(m.statbytes)

		return {
			name = h.name,
			size = st.length,
			dir = (st.mode & 0x80000000) ~= 0,
		}
	end

	-- open never mutates the handed-in handle -- it clones a fresh
	-- fid, same rule as lib/espfs.lua's open() and for the same
	-- reason: the walked handle and the opened one get separate
	-- lifetimes (separate __gc clunks) on the mnt.lua side.
	function B.open(h, mode)
		local nfid = clone(h.fid)

		if h.isdir then
			if mode ~= "r" then
				err(dev.Eisdir)
			end
			return dev.closable(B, h_of(nfid, true, h.name))
		end

		local m9mode = (mode == "r") and 0 or 1
		local ok = pcall(rpc,
		    function(t) return ninep.topen(t, nfid, m9mode) end,
		    ninep.Ropen, "open")

		if not ok then
			pcall(rpc, function(t) return ninep.tclunk(t, nfid) end,
			    ninep.Rclunk, "clunk")
			err(mode == "r" and dev.Enonexist or dev.Eperm)
		end
		return dev.closable(B, h_of(nfid, false, h.name))
	end

	-- Tcreate makes AND opens in one step, like espfs.lua's create()
	-- over fs.open(path, "w"). the dev interface gives us no
	-- permission bits, so this always asks for a plain 0644 file;
	-- directory creation (perm's DMDIR bit) isn't exposed by this
	-- interface either and so isn't reachable from here.
	local PERM_0644 = 0x1A4

	function B.create(h, name, mode)
		if not h.isdir then
			err(dev.Enotdir)
		end

		local nfid = clone(h.fid)
		local m9mode = (mode == "r") and 0 or 1
		local ok = pcall(rpc,
		    function(t)
		        return ninep.tcreate(t, nfid, name, PERM_0644, m9mode,
		            dotu and "" or nil)
		    end,
		    ninep.Rcreate, "create")

		if not ok then
			pcall(rpc, function(t) return ninep.tclunk(t, nfid) end,
			    ninep.Rclunk, "clunk")
			err(dev.Eperm)
		end
		return dev.closable(B, h_of(nfid, false, name))
	end

	-- chunked to the negotiated msize. A caller may ask for more than
	-- one Tread can carry and get it, which is what makes this a mount
	-- driver rather than a thin 9P wrapper -- see dev.readloop.
	function B.read(h, off, n)
		if h.isdir then
			err(dev.Eisdir)
		end
		return dev.readloop(iounit, function(o, c)
			local m = rpc(
			    function(t) return ninep.tread(t, h.fid, o, c) end,
			    ninep.Rread, "read")

			return m.data
		end, off, n)
	end

	function B.write(h, off, data)
		if h.isdir then
			err(dev.Eisdir)
		end
		return dev.writeloop(iounit, function(o, chunk)
			local m = rpc(
			    function(t) return ninep.twrite(t, h.fid, o, chunk) end,
			    ninep.Rwrite, "write")

			return m.count
		end, off, data)
	end

	-- directories need their own Topen before Tread, same as files,
	-- but readdir()'s contract (src/dev.c) doesn't require a prior
	-- open() -- so this opens (and clunks) its OWN cloned fid rather
	-- than touching h, matching open()'s never-mutate rule.
	function B.readdir(h)
		if not h.isdir then
			err(dev.Enotdir)
		end

		local fid = clone(h.fid)
		local ok = pcall(rpc,
		    function(t) return ninep.topen(t, fid, 0) end,
		    ninep.Ropen, "readdir")

		if not ok then
			pcall(rpc, function(t) return ninep.tclunk(t, fid) end,
			    ninep.Rclunk, "clunk")
			err(dev.Eio)
		end

		local out, off = {}, 0

		while true do
			local m = rpc(
			    function(t) return ninep.tread(t, fid, off, 4096) end,
			    ninep.Rread, "readdir")

			local d = m.data

			if #d == 0 then
				break
			end

			-- the payload is a view where the transport handed
			-- back a buffer, so each entry is named rather than
			-- cut out. unpackstat reads either.
			local isbuf = buf.is(d)
			local pos = 1

			while pos <= #d do
				local n = isbuf and d:u16le(pos) or
				    string.unpack("<I2", d, pos)
				local rec = isbuf and
				    d:view(pos + 2, pos + 1 + n) or
				    d:sub(pos + 2, pos + 1 + n)
				local st = ninep.unpackstat(rec)

				-- drop "." and ".." the same way lib/espfs.lua's
				-- readdir does: a listing lists CONTENTS, and
				-- ns.lua/dev.walkall already handle ".." itself.
				if st.name ~= "." and st.name ~= ".." then
					out[#out + 1] = {
						name = st.name,
						size = st.length,
						dir = (st.mode & 0x80000000) ~= 0,
					}
				end
				pos = pos + 2 + n
			end
			off = off + #d
		end
		rpc(function(t) return ninep.tclunk(t, fid) end,
		    ninep.Rclunk, "clunk")
		table.sort(out, function(a, b) return a.name < b.name end)
		return out
	end

	-- the name, which is as far as wstat reaches. No rename() here:
	-- 9P has no message that names two directories, so a move between
	-- them is dev.Enotimpl and the namespace says so.
	function B.wstat(h, st)
		if not st or st.name == nil then
			return true
		end
		rpc(function(t)
			return ninep.twstat(t, h.fid, { name = st.name })
		end, ninep.Rwstat, "wstat")
		h.name = st.name
		return true
	end

	function B.clunk(h)
		pcall(rpc, function(t) return ninep.tclunk(t, h.fid) end,
		    ninep.Rclunk, "clunk")
	end

	return B
end

return M
