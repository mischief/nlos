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
-- a dead server parks the caller forever: thread.recv has no deadline
-- and there is nothing else to wake it. the right fix is hangup
-- detection on the reply port, not a timeout -- a slow backend is not a
-- broken one -- and it is not written yet.
--
-- walk is one element per round trip because dev.walk is. 9P's Twalk
-- carries up to sixteen names for this exact reason, and dev.walkpath
-- is where that optimisation would go.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")

local M = {}

-- new(right) -> a dev backend speaking to the server holding `right`.
function M.new(right)
	local B = {}

	-- one reply port for the whole mount, reused. concurrent callers
	-- inside one proc are serialised by the lock rather than
	-- demultiplexed by a tag, which is what plan 9's Mnt does with its
	-- own lock and queue. outside thread.run() the lock never blocks,
	-- because without threads there is no second caller.
	local reply = sys.newport()
	local lock = thread.qlockcreate()

	local function rpc(msg)
		msg.reply = { __right = reply }

		lock:lock()
		local ok, res = pcall(function()
			sys.send(right, msg)
			return thread.recv(reply)
		end)

		lock:unlock()
		if not ok then
			dev.error(dev.Eio)	-- server gone, or right closed
		end
		if type(res) ~= "table" then
			dev.error(dev.Eio)
		end
		if res.err then
			dev.error(res.err)
		end
		return res
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
