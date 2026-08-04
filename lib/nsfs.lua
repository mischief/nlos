-- nsfs: a namespace, presented as one dev backend.
--
-- This is what a whole namespace looks like from the outside -- one tree,
-- walks crossing mount points and unions the way NS resolves them -- so
-- task/9pexport.lua handed this exports the entire tree, /proc and /srv
-- and /n/gefs together, which is exactly plan 9's exportfs. gefsfs
-- exports one filesystem; this exports the composition of all of them.
--
-- It is the fid-shaped face of the path-shaped NS: a handle is a path,
-- re-resolved through the namespace on each walk and stat (so a mount
-- appearing underneath it is seen), and once opened it carries the Chan
-- NS handed back, whose position an explicit 9P offset drives. Re-walking
-- per element is not free, but exportfs is not a hot path, and correctness
-- across mounts is the whole point.

local dev = require("dev")

local M = {}

local function basename(path)
	if path == "/" then return "/" end
	return path:match("[^/]+$")
end

local function parentpath(path)
	local p = path:match("^(.*)/[^/]+$")
	if p == nil or p == "" then return "/" end
	return p
end

local function childpath(path, name)
	if path == "/" then return "/" .. name end
	return path .. "/" .. name
end

-- raise NS's nil+err returns into the dev error the server turns into an
-- Rerror; NS:walk already raises, so only the returning calls need this.
local function must(v, err)
	if v == nil then dev.error(tostring(err)) end
	return v
end

-- new(namespace) -> a dev backend over that namespace.
function M.new(ns)
	local B = {}

	local function h_of(path)
		return { path = path }
	end

	function B.attach()
		return h_of("/")
	end

	function B.walk(h, name)
		if h.chan then dev.error(dev.Enotdir) end	-- an open file
		if name == "." then
			return h_of(h.path)
		end
		if name == ".." then
			return h_of(h.path == "/" and "/" or parentpath(h.path))
		end
		local cp = childpath(h.path, name)
		-- NS:walk raises Enonexist if the element is not there; the
		-- chan it returns is only to prove the walk, so let it close
		local c <close> = ns:walk(cp)
		return h_of(cp)
	end

	function B.stat(h)
		local st = must(ns:stat(h.path))
		return { name = basename(h.path), size = st.size, dir = st.dir }
	end

	function B.open(h, mode)
		local c = must(ns:open(h.path, mode))
		return dev.closable(B, { path = h.path, chan = c })
	end

	function B.create(h, name, mode, dir)
		local cp = childpath(h.path, name)
		local c = must(ns:create(cp, mode, dir))
		return dev.closable(B, { path = cp, chan = c })
	end

	function B.read(h, off, n)
		if not h.chan then dev.error(dev.Ebadusefd) end
		h.chan:seek("set", off)
		local s, err = h.chan:read(n)
		return must(s, err)
	end

	function B.write(h, off, data)
		if not h.chan then dev.error(dev.Ebadusefd) end
		h.chan:seek("set", off)
		local w, err = h.chan:write(data)
		return must(w, err)
	end

	function B.readdir(h)
		local ents = must(ns:readdir(h.path))
		local out = {}
		for _, e in ipairs(ents) do
			out[#out + 1] = { name = e.name, size = e.size or 0,
			    dir = e.dir }
		end
		return out
	end

	function B.clunk(h)
		if h.chan then
			pcall(h.chan.close, h.chan)
			h.chan = nil
		end
	end

	return B
end

return M
