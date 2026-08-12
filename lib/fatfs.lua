-- fatfs: a mounted FAT volume, presented as a dev backend (lib/dev.lua).
--
-- The same shape as lib/gefsfs.lua, and for the same reason: lib/fat
-- speaks paths and dev speaks handles, so a handle here is a path and
-- every op re-walks it. A re-walk always sees the current tree, so a
-- handle never goes stale after a write changes a length.
--
-- One writer. lib/fat holds no locks, so task/fatsrv.lua serves it with
-- workers = 1 and each request runs to completion before the next. This
-- file adds no concurrency and assumes none above it.
--
-- lib/fat reports a failure as nil plus a message; dev raises. fail()
-- below is where the two meet, and it is why no op here returns an
-- error to its caller.

local dev = require("dev")
local buf = require("los.buf")
local fat = require("fat")
local dat = fat.dat

local M = {}

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

-- what lib/fat returns, as what dev raises. The message is dropped: dev
-- carries a code, and the codes it has are the ones a 9P client can act
-- on.
local function fail(v, code)
	if v == nil then
		dev.error(code or dev.Eio)
	end
	return v
end

function M.new(fs)
	local B = {}

	local function h_of(path)
		return { path = path }
	end

	-- A fid is the file it was walked to, so the entry is resolved
	-- once and kept on the handle. Re-walking the whole path from the
	-- root per operation measured 22ms for a one-byte read, against
	-- 2.4ms for the sector the bytes were already in.

	-- gen is bumped by anything that can move an entry or change its
	-- length, so a cached one is dropped rather than trusted across a
	-- write made through another fid.
	local gen = 0

	local function entof(h)
		if h.ent ~= nil and h.gen == gen then
			return h.ent
		end
		h.ent = fail(fs:walk(h.path), dev.Enonexist)
		h.gen = gen
		return h.ent
	end

	local function isdir(ent)
		return (ent.attr & dat.Adir) ~= 0
	end

	-- Changes are not on the device until this runs. lib/srv.lua's tick
	-- calls it between requests, never beside one, so a commit never
	-- interleaves with a write.
	function B.sync()
		fs:sync()
	end

	-- /ctl is synthetic, as it is on a served gefs volume: a client
	-- writes "sync" to it to force a commit. A real file named ctl in
	-- the root is shadowed by it; a served volume reserves the name.
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

	-- A step from a directory we already hold, not a fresh resolve of
	-- the whole path: fs:walk starts at the root every time, so
	-- walking a path of n elements cost n(n+1)/2 lookups.
	function B.walk(h, name)
		if isctl(h) then
			dev.error(dev.Enotdir)
		end

		local pe = entof(h)

		if not isdir(pe) then
			dev.error(dev.Enotdir)
		end
		if name == "." then
			return h_of(h.path)
		end
		-- a mount is a boundary: ".." at our root stays put.
		if name == ".." then
			return h_of(h.path == "/" and "/" or parentpath(h.path))
		end
		if h.path == "/" and name == CTL then
			return h_ctl()
		end

		local cp = childpath(h.path, name)
		local e = fs:lookup(fs:dirent(pe), name)

		if e == nil then
			dev.error(dev.Enonexist)
		end

		-- the walk that proved it exists is the one the next
		-- operation would otherwise repeat
		local nh = h_of(cp)

		nh.ent, nh.gen = e, gen
		return nh
	end

	function B.stat(h)
		if isctl(h) then
			return { name = CTL, size = 0, dir = false }
		end

		local ent = entof(h)

		return {
			name = basename(h.path),
			size = ent.size,
			dir = isdir(ent),
		}
	end

	-- "w" truncates, "rw" does not.
	--
	-- 9P's OTRUNC by another name, and the same split POSIX makes
	-- between O_WRONLY|O_TRUNC and O_RDWR: opening to write means
	-- replacing the contents, opening to read and write means editing
	-- them in place. Without it, rewriting a file with a shorter one
	-- leaves the tail of the old behind -- which for a config file is
	-- a syntax error at the end of something that otherwise looks
	-- right.
	function B.open(h, mode)
		if isctl(h) then
			return dev.closable(B, h_ctl())
		end

		local ent = entof(h)

		if isdir(ent) and mode ~= "r" then
			dev.error(dev.Eisdir)
		end
		local nh = h_of(h.path)

		if mode == "w" and not isdir(ent) and ent.size > 0 then
			fail(fs:truncate(h.path, 0))
			gen = gen + 1
		else
			nh.ent, nh.gen = ent, gen
		end
		return dev.closable(B, nh)
	end

	function B.create(h, name, mode, dir)
		if not isdir(entof(h)) then
			dev.error(dev.Enotdir)
		end

		local cp = childpath(h.path, name)

		if fs:walk(cp) ~= nil then
			dev.error(dev.Eexist)
		end
		if dir then
			fail(fs:mkdir(cp))
		else
			fail(fs:createfile(cp))
		end
		gen = gen + 1
		return dev.closable(B, h_of(cp))
	end

	-- read answers with a string, as dev says it does. readbuf is the
	-- optional form lib/mnt.lua also offers: bytes of our own, which
	-- lib/srv.lua hands to the client instead of copying them into the
	-- reply.
	function B.read(h, off, n)
		local d = B.readbuf(h, off, n)

		return buf.is(d) and d:str() or d
	end

	function B.readbuf(h, off, n)
		if isctl(h) then
			return ""	-- reading ctl says nothing; writing it does
		end

		local ent = entof(h)

		if isdir(ent) then
			dev.error(dev.Eisdir)
		end
		if off < 0 or n < 0 then
			dev.error(dev.Ebadarg)
		end
		-- bytes of our own, which lib/srv.lua hands to the client
		-- rather than copying into the reply. A caller wanting a
		-- string gets one from the buffer.
		return fail(fs:readbuf(ent, off, n))
	end

	-- The length lives in the directory entry, and fs:write only grows
	-- the copy it was handed. flushent against the parent is what puts
	-- it on the device, and without it a file written here reads back
	-- at its old size -- the clusters are allocated, and nothing says
	-- the file reaches them.
	function B.write(h, off, data)
		if isctl(h) then
			-- one verb, "sync". Anything else is accepted and
			-- ignored, so a client may write a command this build
			-- does not know without its write failing.
			if data:match("^%s*sync") then
				fs:sync()
			end
			return #data
		end

		local ent = entof(h)

		if isdir(ent) then
			dev.error(dev.Eisdir)
		end
		if off < 0 then
			dev.error(dev.Ebadarg)
		end

		local n = fail(fs:write(ent, off, data))
		local d = fail(fs:walkparent(h.path), dev.Enonexist)

		fs:flushent(d, ent)
		-- the entry on the device has a new length now, and another
		-- fid may be holding the old one
		gen = gen + 1
		h.ent, h.gen = ent, gen
		return n
	end

	function B.readdir(h)
		local ent = entof(h)

		if not isdir(ent) then
			dev.error(dev.Enotdir)
		end

		local out = {}

		-- ctl appears in the root listing, so a client can find it
		if h.path == "/" then
			out[#out + 1] = { name = CTL, size = 0, dir = false }
		end
		for _, e in ipairs(fail(fs:ls(h.path))) do
			out[#out + 1] = {
				name = e.name,
				size = e.size,
				dir = (e.attr & dat.Adir) ~= 0,
			}
		end
		return out
	end

	function B.remove(h)
		if isctl(h) or h.path == "/" then
			dev.error(dev.Eperm)
		end
		fail(fs:remove(h.path))
		gen = gen + 1
	end

	function B.clunk(_)
	end

	return B
end

return M
