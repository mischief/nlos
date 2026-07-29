-- mnt: a dev backend that forwards to a server on a port.
--
-- plan 9's devmount. lib/srv.lua is the other half; the protocol and
-- the argument for it are documented there. this side is deliberately
-- boring: every method is the same round trip, so the interesting
-- content is the three things that are NOT a round trip.
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
-- ---- what is missing ----
--
-- walk is one element per round trip because dev.walk is. 9P's Twalk
-- carries up to sixteen names for this exact reason, and dev.walkpath
-- is where that optimisation would go.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")

local M = {}

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
	local function rpc(msg)
		local reply = thread.replyport()

		msg.seq = nextseq()
		msg.reply = { __right = reply }

		-- sys.send RETURNS FALSE for a dead port -- erlang semantics,
		-- the sender learns from a monitor rather than the send -- and
		-- only RAISES for a bad right or an unserializable message.
		-- checking just the pcall missed the first case entirely, so a
		-- request to a server that had already exited was silently
		-- dropped and then waited for forever.
		local ok, sent = pcall(sys.send, right, msg)

		if not ok or sent == false then
			dev.error(dev.Eio)	-- server gone, or right closed
		end

		-- a NON-matching reply belongs to a request this thread
		-- abandoned -- today only possible if an error (a memory cap,
		-- say) unwinds between the send and the recv, but guaranteed
		-- the moment rpcs grow a deadline, which is a listed debt.
		-- dropping it here is the difference between one lost call and
		-- every later call reading the previous one's answer.
		--
		-- note this is NOT a tag: nothing routes on it, no table maps
		-- it to a waiter. it only says "not mine".
		-- ---- and this is where a dead server is noticed ----
		--
		-- while a request is in flight the reply port has TWO rights:
		-- ours, and the one that travelled with the message. the
		-- serializer counts the in-flight one immediately, so the
		-- second right exists from the moment we send.
		--
		-- so if it drops back to one and there is nothing queued,
		-- nobody can ever reply: either the server answered and closed
		-- (drained above), or it died and proc_kill released its
		-- rights. sys.hungup is exactly that question, and it is the
		-- same test lib/srv.lua uses to know its last client left.
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
		while true do
			local got, res = sys.tryrecv(reply)

			if got then
				if type(res) ~= "table" then
					dev.error(dev.Eio)
				end
				if res.seq == msg.seq then
					if res.err then
						dev.error(res.err)
					end
					return res
				end
				-- a NON-matching reply belongs to a request
				-- this thread abandoned -- today only possible
				-- if an error (a memory cap, say) unwinds
				-- between the send and the recv. dropping it is
				-- the difference between one lost call and
				-- every later call reading the previous one's
				-- answer.
				--
				-- note this is NOT a tag: nothing routes on it,
				-- no table maps it to a waiter. it only says
				-- "not mine".
			elseif sys.hungup(reply) then
				dev.error(dev.Eio)	-- nobody left to answer
			else
				thread.park(reply)
			end
		end
	end

	-- a handle is {fid=n}, finalized. clunk clears fid so an explicit
	-- close and a later collection do not clunk twice -- harmless on
	-- the server, but it would send a message per collected handle
	-- forever.
	local fidmt = {
		__gc = function(h)
			if h.fid then
				pcall(sys.send, right,
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

	function B.create(h, name, mode)
		local r = rpc({ op = "create", fid = h.fid, name = name,
		    mode = mode })

		return dev.closable(B, h_of(r.fid))
	end

	function B.read(h, off, n)
		return rpc({ op = "read", fid = h.fid, off = off, n = n }).data
	end

	function B.write(h, off, data)
		return rpc({ op = "write", fid = h.fid, off = off,
		    data = data }).n
	end

	function B.readdir(h)
		return rpc({ op = "readdir", fid = h.fid }).ents
	end

	-- fire and forget, matching dev.clunk's "never fails". no reply
	-- means no round trip, which is what makes it safe from __gc.
	function B.clunk(h)
		if h.fid then
			pcall(sys.send, right, { op = "clunk", fid = h.fid })
			h.fid = nil
		end
	end

	return B
end

return M
