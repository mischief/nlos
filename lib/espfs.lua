-- espfs: the ESP as a dev backend (see lib/dev.lua for the interface).
--
-- EVERYTHING goes through los.fs -- enumeration, metadata and file data
-- alike. espfs is the ESP driver, so it reaches the platform directly
-- rather than through io, which is itself built on that platform; and
-- keeping all of ESP access behind one module is what lets that module
-- later belong to a single owning task.
--
-- writes are gated on the disk capability inside los.fs.open, so a proc
-- without it raises Eperm from create()/open() and everything else still
-- works. that is deliberate: the gate belongs where the risk is, and
-- reading the esp is not the risk.
--
-- failures are raised, not returned; see lib/dev.lua on why, and catch
-- with pcall at whatever counts as an entry point.
--
-- this is a plain backend, not a task. making it an exclusive task that
-- owns the esp outright -- so no other proc holds the disk capability at
-- all, and enumeration stops being ambient -- is a refinement worth
-- doing later, and it needs no change here: the same eight methods move
-- behind a port. see docs/shell-namespace-draft.md.

local fs = require("los.fs")
local dev = require("dev")

local M = {}

local err = dev.error

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
			err(dev.Enonexist)
		end
		return h_of(root, st.dir)
	end

	function B.walk(h, name)
		if not h.dir then
			err(dev.Enotdir)
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
			err(dev.Enonexist)
		end
		return h_of(path, st.dir)
	end

	function B.stat(h)
		local st = fs.stat(h.path)

		if not st then
			err(dev.Enonexist)
		end
		-- report the element name, not the full path: that is what
		-- 9P's stat carries and what a listing wants.
		st.name = h.path:match("[^/]+$") or "/"
		return st
	end

	-- open returns a NEW handle and never mutates the one it was given.
	--
	-- that is not tidiness, it is required. this used to set h.f and
	-- hand h straight back, so the walked handle and the opened handle
	-- were one object. locally that is survivable; through lib/srv.lua
	-- it is not, because the server gives the result a second fid and
	-- the two then alias. clunking either -- and mnt's handles clunk
	-- themselves from __gc, so the walked one always eventually does --
	-- ran h.f:close() and left the OTHER fid holding a handle whose
	-- file was gone, which surfaced as Ebadusefd on a perfectly good
	-- read, at whatever moment the collector happened to run.
	--
	-- so: a handle returned by open owns its own lifetime.
	function B.open(h, mode)
		if h.dir then
			if mode ~= "r" then
				err(dev.Eisdir)
			end
			-- a directory needs no open file behind it, but it
			-- must still come back closable: otherwise
			-- `local h <close> = open(...)` works for a file and
			-- raises "got a non-closable value" for a directory,
			-- which is a difference no caller should have to know
			-- about. mem's open makes everything closable, so
			-- this is also the two backends agreeing.
			return dev.closable(B, h_of(h.path, true))
		end

		local f = fs.open(h.path, mode == "r" and "r" or "w")

		if not f then
			-- write mode without the disk capability lands here,
			-- and so does a genuinely missing file
			err(mode == "r" and dev.Enonexist or dev.Eperm)
		end

		local nh = h_of(h.path, false)

		nh.f = f
		return dev.closable(B, nh)
	end

	-- create and open in one step, like 9P's Tcreate. fs.open in write
	-- mode does both, so this is also where the disk capability is
	-- checked -- a proc without it gets nil plus a message here rather
	-- than a half-made file.
	function B.create(h, name, mode)
		if not h.dir then
			err(dev.Enotdir)
		end

		local path = join(h.path, name)
		local f = fs.open(path, "w")

		if not f then
			-- no disk capability, or an unwritable path
			err(dev.Eperm)
		end

		local nh = h_of(path, false)

		nh.f = f
		if mode == "r" then
			-- asked to create then read: reopen read-only so the
			-- handle behaves the way the mode says it should
			f:close()
			nh.f = fs.open(path, "r")
			if not nh.f then
				err(dev.Eio)
			end
		end
		return dev.closable(B, nh)
	end

	function B.read(h, off, n)
		if h.dir then
			err(dev.Eisdir)
		end
		if not h.f then
			err(dev.Ebadusefd)
		end
		if not h.f:seek(off) then
			err(dev.Eio)
		end
		return h.f:read(n)		-- "" at eof, which is the contract
	end

	function B.write(h, off, data)
		if h.dir then
			err(dev.Eisdir)
		end
		if not h.f then
			err(dev.Ebadusefd)
		end
		if not h.f:seek(off) then
			err(dev.Eio)
		end
		if not h.f:write(data) then
			err(dev.Eio)
		end
		return #data
	end

	function B.readdir(h)
		if not h.dir then
			err(dev.Enotdir)
		end
		local ents = fs.readdir(h.path)

		if not ents then
			err(dev.Eio)
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
