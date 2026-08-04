-- gefsfs: a mounted gefs volume, presented as a dev backend (lib/dev.lua).
--
-- gefs speaks paths -- walk(path), read(dirent, off, n) -- and dev speaks
-- fids: walk returns a handle, read takes an offset. The gap closes the
-- easy way dev.lua's own header names: a path-shaped backend makes its
-- handle a path and re-walks per call, which is what dev.mem does and
-- what this does. Each op is cheap against gefs's cache, and a re-walk
-- always sees the current tree, so a handle never goes stale after a
-- write changes a length.
--
-- one writer. The volume this wraps has no locks (the port is one thread
-- of control), so task/gefssrv.lua serves it with workers = 1 and every
-- request runs to completion before the next -- see lib/gefs.lua's header
-- and lib/srv.lua's workers note. This file adds no concurrency of its
-- own and assumes none above it.
--
-- create() makes files only: the dev interface's create carries an open
-- mode, not a 9P perm, so DMDIR cannot be asked for through it. Directory
-- creation waits on the interface growing a perm, the same way remove()
-- and wstat() were once absent -- see dev.lua. mkdir on the mount itself
-- still works; it just is not reachable through a served handle yet.

local dev = require("dev")
local gefs = require("gefs")
local dat = gefs.dat

local M = {}

local function isdir(d)
	return d.mode & dat.DMDIR ~= 0
end

local function basename(path)
	if path == "/" then
		return "/"
	end
	return path:match("[^/]+$")
end

local function parentpath(path)
	local p = path:match("^(.*)/[^/]+$")
	if p == nil or p == "" then
		return "/"
	end
	return p
end

local function childpath(path, name)
	if path == "/" then
		return "/" .. name
	end
	return path .. "/" .. name
end

function M.new(mnt)
	local B = {}

	local fs = mnt.fs

	local function h_of(path)
		return { path = path }
	end

	-- walk to a dirent or raise, translating gefs's nil+msg into the
	-- dev error the server turns into an Rerror
	local function direntof(path)
		local d = mnt:walk(path)
		if d == nil then
			dev.error(dev.Enonexist)
		end
		return d
	end

	-- commit the volume. Held here rather than in task/gefssrv.lua so the
	-- server's periodic tick and the explicit /ctl verb below reach it the
	-- same way, and so srv.lua's tick hook can call it through the backend
	-- without knowing what a filesystem is.
	function B.sync()
		fs:sync()
	end

	-- /ctl is synthetic: it is not in the tree, it is the control file a
	-- client writes "sync" to to force a commit, exactly as 9front's gefs
	-- takes "sync" on its own ctl (ctl.c). A real file named ctl in the
	-- root would be shadowed by it; a served volume reserves the name.
	local CTL = "ctl"
	local function isctl(h)
		return h.ctl == true
	end
	local function h_ctl()
		return { ctl = true }
	end

	function B.attach()
		return h_of("/")
	end

	function B.walk(h, name)
		if isctl(h) then
			dev.error(dev.Enotdir)
		end
		local d = direntof(h.path)
		if not isdir(d) then
			dev.error(dev.Enotdir)
		end
		if name == "." then
			return h_of(h.path)
		end
		if name == ".." then
			-- a mount is a boundary: ".." at our root stays put, as it
			-- does for every other backend here.
			return h_of(h.path == "/" and "/" or parentpath(h.path))
		end
		if h.path == "/" and name == CTL then
			return h_ctl()
		end
		local cp = childpath(h.path, name)
		if mnt:walk(cp) == nil then
			dev.error(dev.Enonexist)
		end
		return h_of(cp)
	end

	function B.stat(h)
		if isctl(h) then
			return { name = CTL, size = 0, dir = false }
		end
		local d = direntof(h.path)
		return {
			name = basename(h.path),
			size = d.length,
			dir = isdir(d),
		}
	end

	function B.open(h, mode)
		if isctl(h) then
			return dev.closable(B, h_ctl())
		end
		local d = direntof(h.path)
		if isdir(d) and mode ~= "r" then
			dev.error(dev.Eisdir)
		end
		return dev.closable(B, h_of(h.path))
	end

	function B.create(h, name, mode, dir)
		local d = direntof(h.path)
		if not isdir(d) then
			dev.error(dev.Enotdir)
		end
		local cp = childpath(h.path, name)
		if mnt:walk(cp) ~= nil then
			dev.error(dev.Eexist)
		end
		if dir then
			mnt:mkdir(cp)
		else
			mnt:createfile(cp)
		end
		return dev.closable(B, h_of(cp))
	end

	function B.read(h, off, n)
		if isctl(h) then
			return ""	-- reading ctl says nothing; writing it does
		end
		local d = direntof(h.path)
		if isdir(d) then
			dev.error(dev.Eisdir)
		end
		if off < 0 or n < 0 then
			dev.error(dev.Ebadarg)
		end
		return mnt:read(d, off, n)
	end

	function B.write(h, off, data)
		if isctl(h) then
			-- one verb, "sync", the way 9front's ctl takes it. anything
			-- else is accepted and ignored rather than erroring, so a
			-- client can write a command this build does not know without
			-- its write failing.
			if data:match("^%s*sync") then
				fs:sync()
			end
			return #data
		end
		local d = direntof(h.path)
		if isdir(d) then
			dev.error(dev.Eisdir)
		end
		if off < 0 then
			dev.error(dev.Ebadarg)
		end
		return mnt:write(d, off, data)
	end

	function B.readdir(h)
		local d = direntof(h.path)
		if not isdir(d) then
			dev.error(dev.Enotdir)
		end
		local out = {}
		-- ctl appears in the root listing, so a client can find it
		if h.path == "/" then
			out[#out + 1] = { name = CTL, size = 0, dir = false }
		end
		for _, e in ipairs(mnt:readdir(d)) do
			out[#out + 1] = {
				name = e.name,
				size = e.length,
				dir = e.mode & dat.DMDIR ~= 0,
			}
		end
		return out
	end

	-- remove() is offered (dev.lua marks it optional): gefs can do it, so
	-- a served client can rm. wstat/rename waits on the same interface
	-- growth as directory create.
	function B.remove(h)
		if isctl(h) or h.path == "/" then
			dev.error(dev.Eperm)
		end
		mnt:removepath(h.path)
	end

	function B.clunk(_)
	end

	return B
end

return M
