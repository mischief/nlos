-- srvfs: /srv, where a right has a name and a path.
--
-- This is Plan 9's devsrv, including the trick that makes it work.
--
-- A capability cannot be sent as bytes -- but it does not have to be.
-- Plan 9 posts a server by WRITING A DECIMAL FILE DESCRIPTOR to
-- /srv/name, and the number is meaningless as data: devsrv's write()
-- resolves it against the calling proc's own fd table and adopts the
-- Chan behind it. open() later hands that Chan back. The bytes name a
-- capability the kernel already holds on the caller's behalf; they do
-- not carry one.
--
-- The same two halves exist here. A right handle is proc-local exactly
-- as an fd is, and a local dev backend runs IN THE CALLER'S PROC -- see
-- the note in procfs.lua, where "self" is resolved by whoever is
-- reading. So this backend can call sys.sendright on a number the
-- caller wrote and get the caller's right, and can hand back a handle
-- number that is already valid in the reader.
--
--   echo 5 >/srv/thing     posts the right at handle 5
--   h = read /srv/thing    h is a right in the reading proc
--
-- What travels between procs is still a message -- lib/srvd.lua holds
-- the registry and rights reach it the only way rights move. What this
-- adds is that the namespace is a legitimate way to reach it, so
-- nothing needs a srvd right in hand to name a server.
--
-- The one thing that does NOT work, and does not in Plan 9 either: this
-- mounted from another machine. A handle number means nothing on the
-- far side of a wire. /srv is per-machine in both systems for exactly
-- this reason.

local sys = require("los.sys")
local dev = require("dev")
local srvc = require("srvc")

local M = {}

function M.new(srv)
	local B = {}

	local function names()
		local list, err = srvc.list(srv)

		if not list then
			-- the registry is gone or not answering. Eio rather
			-- than an empty listing, so a caller cannot read
			-- "nothing is posted" out of "I could not ask".
			dev.error(dev.Eio .. ": " .. tostring(err))
		end
		return list
	end

	local function has(name)
		for _, n in ipairs(names()) do
			if n == name then
				return true
			end
		end
		return false
	end

	function B.attach()
		return { kind = "root" }
	end

	function B.walk(h, name)
		if h.kind ~= "root" then
			dev.error(dev.Enotdir)
		end
		if name == "." or name == ".." then
			return { kind = "root" }	-- /srv is its own parent
		end
		if not has(name) then
			dev.error(dev.Enonexist)
		end
		return { kind = "file", name = name }
	end

	function B.stat(h)
		if h.kind == "root" then
			return { name = "srv", dir = true, size = 0 }
		end
		-- size is the width of the handle a read would return, which
		-- is not knowable before opening. 0 is honest; a reader takes
		-- what read gives it.
		return { name = h.name, dir = false, size = 0 }
	end

	function B.open(h, mode)
		if h.kind == "root" then
			return { kind = "root" }
		end
		if not has(h.name) then
			dev.error(dev.Enonexist)
		end
		if mode == "w" or mode == "rw" then
			-- reposting over a live name would silently swap what
			-- everyone holding it thinks they have
			dev.error(dev.Eperm)
		end

		-- the acquisition. This runs in the reading proc, so the
		-- right lands there and the number below is valid there --
		-- which is the whole mechanism.
		local right, err = srvc.open(srv, h.name)

		if not right then
			dev.error(dev.Eio .. ": " .. tostring(err))
		end
		-- a fresh handle owning its own lifetime, per dev.lua
		return { kind = "file", name = h.name,
		    data = tostring(right) .. "\n" }
	end

	-- create-then-write is how a name comes into being, as in 9P's
	-- Tcreate and Plan 9's own `create("/srv/x"); write(fd, "3")`.
	-- Nothing is posted until the write: the name exists only in this
	-- handle until then.
	function B.create(h, name, mode)
		if h.kind ~= "root" then
			dev.error(dev.Enotdir)
		end
		if name == "" or name == "." or name == ".." or
		    name:find("[/%z]") then
			dev.error("srv: bad name")
		end
		if has(name) then
			dev.error(dev.Eexist)
		end
		return { kind = "file", name = name, pending = true }
	end

	function B.read(h, off, n)
		if h.kind ~= "file" then
			dev.error(dev.Eisdir)
		end
		if not h.data then
			dev.error(dev.Ebadusefd)
		end
		return h.data:sub(off + 1, off + n)
	end

	-- the post. `data` is a decimal handle in the WRITER's proc, and
	-- sys.sendright resolves it there -- this code is running in that
	-- proc. A number naming nothing is a bad write, not a leak.
	function B.write(h, off, data)
		if h.kind ~= "file" then
			dev.error(dev.Eisdir)
		end

		local handle = tonumber((tostring(data):gsub("%s+$", "")))

		if not handle then
			dev.error("srv: write a decimal right handle")
		end

		local ok, right = pcall(sys.sendright, handle)

		if not ok or not right then
			dev.error("srv: " .. handle .. " is not a right here")
		end

		local posted, err = srvc.post(srv, h.name, right)

		if not posted then
			sys.close(right)
			dev.error("srv: " .. tostring(err))
		end
		h.pending = nil
		return #data
	end

	function B.readdir(h)
		if h.kind ~= "root" then
			dev.error(dev.Enotdir)
		end

		local out = {}

		for _, n in ipairs(names()) do
			out[#out + 1] = { name = n, dir = false, size = 0 }
		end
		return out
	end

	-- removing the name drops the registry's right, which is what lets
	-- a served port finally die.
	function B.remove(h)
		if h.kind ~= "file" then
			dev.error(dev.Eperm)
		end

		local ok, err = srvc.remove(srv, h.name)

		if not ok then
			dev.error("srv: " .. tostring(err))
		end
		return true
	end

	function B.clunk(_)
	end

	return B
end

return M
