-- srvfs: the names in lib/srvd.lua, as a directory.
--
-- READ-ONLY, and reading a name gives you a line of text, not the
-- right. That is not a limitation being apologised for -- it is the
-- honest shape. A capability does not fit in a byte stream, so
-- acquiring one is a message (see lib/srvc.lua) and this shows what
-- there is to acquire. `ls /srv` answers "what could I mount", and
-- `mount` does the rest.
--
-- Plan 9 puts both faces on one file because its kernel can: devsrv.c's
-- open() returns a dup of a stored Chan. Nothing at this layer can do
-- that, since the dev interface it would have to travel through returns
-- strings.
--
-- Backed by a right to srvd rather than by a shared table, because the
-- registry lives in another proc -- which is the whole point, since a
-- per-proc table would name nothing anyone else could reach.

local dev = require("dev")
local srvc = require("srvc")

local M = {}

function M.new(srv)
	local B = {}

	-- a handle is { kind = "root"|"file", name =, data = }
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

	local function content(name)
		return name .. "\n"
	end

	function B.attach()
		return { kind = "root" }
	end

	function B.walk(h, name)
		if h.kind ~= "root" then
			dev.error(dev.Enotdir)
		end
		if name == "." then
			return { kind = "root" }
		end
		if name == ".." then
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
		return { name = h.name, dir = false, size = #content(h.name) }
	end

	function B.open(h, mode)
		if mode ~= "r" then
			-- posting is srvc.post, not a write: a write carries
			-- bytes and posting carries a right.
			dev.error(dev.Eperm)
		end
		if h.kind == "root" then
			return { kind = "root" }
		end
		if not has(h.name) then
			dev.error(dev.Enonexist)
		end
		-- a fresh handle owning its own lifetime, per dev.lua: the
		-- walked handle must survive this one being clunked.
		return { kind = "file", name = h.name,
		    data = content(h.name) }
	end

	function B.create(_, _, _)
		dev.error(dev.Eperm)
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

	function B.write(_, _, _)
		dev.error(dev.Eperm)
	end

	function B.readdir(h)
		if h.kind ~= "root" then
			dev.error(dev.Enotdir)
		end

		local out = {}

		for _, n in ipairs(names()) do
			out[#out + 1] = { name = n, dir = false,
			    size = #content(n) }
		end
		return out
	end

	function B.clunk(_)
	end

	return B
end

return M
