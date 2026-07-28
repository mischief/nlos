-- espfs: the ESP as a dev backend (see lib/dev.lua for the interface).
--
-- reads and enumeration go through los.fs, which is ambient for the same
-- reason io.open's read path is. WRITES go through io.open in write
-- mode, which is gated on the disk capability -- so a proc without it
-- gets a clean "permission denied" from write() and everything else
-- still works. that is deliberate: the gate belongs where the risk is,
-- and reading the esp is not the risk.
--
-- this is a plain backend, not a task. making it an exclusive task that
-- owns the esp outright -- so no other proc holds the disk capability at
-- all, and enumeration stops being ambient -- is a refinement worth
-- doing later, and it needs no change here: the same eight methods move
-- behind a port. see docs/shell-namespace-draft.md.

local fs = require("los.fs")

local M = {}

-- join a parent path and one element, keeping exactly one slash and no
-- trailing one. "/" .. "lib" must not become "//lib": EFI's Open() is
-- given these verbatim (with / rewritten to \) and a doubled separator
-- is not portable across firmware.
local function join(base, name)
	if base == "/" then
		return "/" .. name
	end
	return base .. "/" .. name
end

-- strip the last element. used only for "..", which ns.lua normally
-- resolves before we see it -- this is the fallback for a 9P client
-- walking ".." directly.
local function parent(path)
	local up = path:match("^(.*)/[^/]+$")

	if not up or up == "" then
		return "/"
	end
	return up
end

function M.new(root)
	root = root or "/"

	local B = {}

	-- a handle is { path = , dir = , f = }. f is the open file object,
	-- present only between open() and clunk() and only for files.
	local function h_of(path, isdir)
		return { path = path, dir = isdir }
	end

	function B.attach()
		local st = fs.stat(root)

		if not st then
			return nil, "cannot stat " .. root
		end
		return h_of(root, st.dir)
	end

	function B.walk(h, name)
		if not h.dir then
			return nil, "not a directory"
		end
		if name == ".." then
			local up = parent(h.path)

			-- never walk above our own root: a mount is a
			-- boundary, and a client must not escape it by
			-- climbing.
			if #up < #root then
				up = root
			end
			return h_of(up, true)
		end

		local path = join(h.path, name)
		local st = fs.stat(path)

		if not st then
			return nil, "no such file"
		end
		return h_of(path, st.dir)
	end

	function B.stat(h)
		local st = fs.stat(h.path)

		if not st then
			return nil, "cannot stat " .. h.path
		end
		-- report the element name, not the full path: that is what
		-- 9P's stat carries and what a listing wants.
		st.name = h.path:match("[^/]+$") or "/"
		return st
	end

	function B.open(h, mode)
		if h.dir then
			if mode ~= "r" then
				return nil, "is a directory"
			end
			return h		-- readdir needs no open file
		end

		local f, err = io.open(h.path, mode == "r" and "r" or "w")

		if not f then
			-- write mode without the disk capability lands here,
			-- and so does a genuinely missing file
			return nil, tostring(err or ("cannot open " .. h.path))
		end
		h.f = f
		return h
	end

	-- create and open in one step, like 9P's Tcreate. io.open in write
	-- mode does both, so this is also where the disk capability is
	-- checked -- a proc without it gets nil plus a message here rather
	-- than a half-made file.
	function B.create(h, name, mode)
		if not h.dir then
			return nil, "not a directory"
		end

		local path = join(h.path, name)
		local f, err = io.open(path, "w")

		if not f then
			return nil, tostring(err or ("cannot create " .. path))
		end

		local nh = h_of(path, false)

		nh.f = f
		if mode == "r" then
			-- asked to create then read: reopen read-only so the
			-- handle behaves the way the mode says it should
			f:close()
			nh.f = io.open(path, "r")
			if not nh.f then
				return nil, "created but cannot reopen " .. path
			end
		end
		return nh
	end

	function B.read(h, off, n)
		if h.dir then
			return nil, "is a directory"
		end
		if not h.f then
			return nil, "not open"
		end
		if not h.f:seek("set", off) then
			return nil, "seek failed"
		end
		return h.f:read(n) or ""	-- nil at eof; "" is the contract
	end

	function B.write(h, off, data)
		if h.dir then
			return nil, "is a directory"
		end
		if not h.f then
			return nil, "not open"
		end
		if not h.f:seek("set", off) then
			return nil, "seek failed"
		end
		local ok, err = h.f:write(data)

		if not ok then
			return nil, tostring(err or "write failed")
		end
		return #data
	end

	function B.readdir(h)
		if not h.dir then
			return nil, "not a directory"
		end
		local ents, err = fs.readdir(h.path)

		if not ents then
			return nil, err
		end
		-- los.fs already returns {name=, size=, dir=}, which is the
		-- stat shape; drop "." and ".." so callers do not have to.
		local out = {}

		for _, e in ipairs(ents) do
			if e.name ~= "." and e.name ~= ".." then
				out[#out + 1] = e
			end
		end
		table.sort(out, function(a, b) return a.name < b.name end)
		return out
	end

	function B.clunk(h)
		if h.f then
			h.f:close()
			h.f = nil
		end
	end

	return B
end

return M
