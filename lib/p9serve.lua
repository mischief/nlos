-- p9serve: a 9P2000 server over a dev backend (lib/dev.lua).
--
-- The inverse of lib/p9fs.lua, which is the 9P client. lib/ninep.lua's own
-- M.serve serves a static synth tree; this serves a live backend, so
-- anything that answers the dev interface -- gefsfs, an ns wrapped as one
-- -- goes out over the wire. That is plan 9's exportfs: the thing exported
-- is a namespace (a backend), and what the backend is is the caller's
-- choice. task/9pexport.lua is the caller.
--
-- The dev interface is fid-shaped on purpose (see dev.lua's header:
-- "because that is what the 9P server needs"), so the mapping is nearly
-- one to one -- Twalk to walk, Topen to open, Tread to read. What this
-- adds is what 9P has and dev does not: qids, the directory read format,
-- and turning a raised dev error into an Rerror.
--
-- No auth (Tauth is refused, Tattach takes no afid), which is what 9fs and
-- the 9p tool do by default. One request at a time above this: gefs is a
-- single writer, so task/9pexport.lua serves one connection's stream
-- serially.

local p9 = require("ninep")
local dev = require("dev")

local M = {}

-- perms reported in stat: dev knows only file-or-directory, so everything
-- is 0777/0666. A real owner model would come from the backend.
local DIRMODE = p9.DMDIR | 0x1ff
local FILEMODE = 0x1b6

-- responder(backend) -> respond(msgbytes) -> replybytes, getmsize().
-- The message level, with no framing, matching ninep.M.responder so a
-- loopback (p9fs's client straight onto this) needs no wire.
function M.responder(backend)
	local msize = p9.MSIZE
	local fids = {}			-- fid -> { h, path, dir, dirrecs? }
	local qidn = {}			-- path -> a stable, unique qid.path
	local nextq = 0

	local function qidpath(path)
		local q = qidn[path]
		if not q then
			nextq = nextq + 1
			q = nextq
			qidn[path] = q
		end
		return q
	end

	local function qidof(path, st)
		return {
			type = st.dir and p9.QTDIR or p9.QTFILE,
			vers = 0,
			path = qidpath(path),
		}
	end

	local function statbytes(path, st)
		return p9.packstat({
			qid = qidof(path, st),
			mode = st.dir and DIRMODE or FILEMODE,
			atime = 0, mtime = 0,
			length = st.dir and 0 or (st.size or 0),
			name = st.name,
			uid = "glenda", gid = "glenda", muid = "glenda",
		})
	end

	local function childpath(path, name)
		if path == "/" then
			return "/" .. name
		end
		return path .. "/" .. name
	end

	local function err(tag, e)
		return p9.rerror(tag, (tostring(e):gsub("^.-:%d+: ", "")))
	end

	-- a directory read serves whole stat records from a byte offset, the
	-- offset being the sum of the records already sent. Build the list
	-- once, on the read at zero, and hand back whole records that fit.
	local function dirread(f, offset, count)
		if not f.dirrecs then
			local ents = backend.readdir(f.h)
			local recs, at = {}, 0

			for _, e in ipairs(ents) do
				local b = statbytes(childpath(f.path, e.name), e)

				recs[#recs + 1] = { at = at, bytes = b }
				at = at + #b
			end
			f.dirrecs = recs
		end

		local out = {}
		local got = 0

		for _, r in ipairs(f.dirrecs) do
			if r.at >= offset then
				if got + #r.bytes > count then
					break
				end
				out[#out + 1] = r.bytes
				got = got + #r.bytes
			end
		end
		return table.concat(out)
	end

	local function handle(m)
		if m.type == p9.Tversion then
			fids = {}
			if m.msize < msize then msize = m.msize end
			if m.version:sub(1, 2) ~= "9P" then
				return p9.rversion(m.tag, msize, "unknown")
			end
			return p9.rversion(m.tag, msize, p9.VERSION)

		elseif m.type == p9.Tauth then
			return p9.rerror(m.tag, "authentication not required")

		elseif m.type == p9.Tattach then
			local ok, h = pcall(backend.attach)
			if not ok then return err(m.tag, h) end
			local ok2, st = pcall(backend.stat, h)
			if not ok2 then return err(m.tag, st) end
			fids[m.fid] = { h = h, path = "/", dir = st.dir }
			return p9.rattach(m.tag, qidof("/", st))

		elseif m.type == p9.Tflush then
			return p9.rflush(m.tag)

		elseif m.type == p9.Twalk then
			local f = fids[m.fid]
			if not f then return p9.rerror(m.tag, dev.Ebadfid) end

			-- clone: no names, newfid becomes a fresh handle at the
			-- same place. Re-walk from the root rather than walk "."
			-- -- a file is not a directory and refuses ".", and a 9P
			-- client clones a file's fid before opening it (9pfuse
			-- does, every read). A fresh handle also avoids aliasing
			-- one mnt fid under two, which dev.lua warns against.
			if #m.wname == 0 then
				local ok, nh = pcall(function()
					return dev.walknames(backend, backend.attach(),
					    dev.elements(f.path))
				end)
				if not ok then return err(m.tag, nh) end
				fids[m.newfid] = { h = nh, path = f.path, dir = f.dir }
				return p9.rwalk(m.tag, {})
			end

			local cur, path = f.h, f.path
			local qids, dir = {}, f.dir

			for _, name in ipairs(m.wname) do
				local ok, nh = pcall(backend.walk, cur, name)
				if not ok then break end
				cur = nh
				path = childpath(path, name)
				local ok2, st = pcall(backend.stat, cur)
				if not ok2 then break end
				dir = st.dir
				qids[#qids + 1] = qidof(path, st)
			end

			if #qids < #m.wname then
				if #qids == 0 then
					return p9.rerror(m.tag, dev.Enonexist)
				end
				return p9.rwalk(m.tag, qids)	-- partial walk
			end
			fids[m.newfid] = { h = cur, path = path, dir = dir }
			return p9.rwalk(m.tag, qids)

		elseif m.type == p9.Topen then
			local f = fids[m.fid]
			if not f then return p9.rerror(m.tag, dev.Ebadfid) end
			local lo = m.mode & 3
			local mode = lo == 0 and "r" or lo == 1 and "w" or "rw"
			local ok, oh = pcall(backend.open, f.h, mode)
			if not ok then return err(m.tag, oh) end
			f.h = oh
			local ok2, st = pcall(backend.stat, oh)
			local q = qidof(f.path, ok2 and st or { dir = f.dir })
			return p9.ropen(m.tag, q, msize - 24)

		elseif m.type == p9.Tcreate then
			-- create names a new file in the directory the fid holds
			-- and leaves the fid pointing at it, open. The backend's
			-- create makes files only (gefsfs does), so DMDIR in the
			-- perm is not honoured -- a directory create waits on the
			-- dev interface growing one (see dev.lua and gefsfs).
			local f = fids[m.fid]
			if not f then return p9.rerror(m.tag, dev.Ebadfid) end
			local lo = m.mode & 3
			local mode = lo == 0 and "r" or lo == 1 and "w" or "rw"
			-- DMDIR in the perm asks for a directory; the backend
			-- honours it if it can (gefsfs does), else makes a file
			local dir = (m.perm & p9.DMDIR) ~= 0
			local ok, nh = pcall(backend.create, f.h, m.name, mode, dir)
			if not ok then return err(m.tag, nh) end
			pcall(backend.clunk, f.h)	-- the directory handle is spent
			f.h = nh
			f.path = childpath(f.path, m.name)
			f.dir = dir
			local ok2, st = pcall(backend.stat, nh)
			local q = qidof(f.path, ok2 and st or { dir = dir })
			return p9.rcreate(m.tag, q, msize - 24)

		elseif m.type == p9.Tread then
			local f = fids[m.fid]
			if not f then return p9.rerror(m.tag, dev.Ebadfid) end
			local count = m.count
			if count > msize - 24 then count = msize - 24 end
			if f.dir then
				local ok, data = pcall(dirread, f, m.offset, count)
				if not ok then return err(m.tag, data) end
				return p9.rread(m.tag, data)
			end
			local ok, data = pcall(backend.read, f.h, m.offset, count)
			if not ok then return err(m.tag, data) end
			return p9.rread(m.tag, data)

		elseif m.type == p9.Twrite then
			local f = fids[m.fid]
			if not f then return p9.rerror(m.tag, dev.Ebadfid) end
			local ok, n = pcall(backend.write, f.h, m.offset, m.data)
			if not ok then return err(m.tag, n) end
			return p9.rwrite(m.tag, n)

		elseif m.type == p9.Tclunk then
			local f = fids[m.fid]
			fids[m.fid] = nil
			if f then pcall(backend.clunk, f.h) end
			return p9.rclunk(m.tag)

		elseif m.type == p9.Tstat then
			local f = fids[m.fid]
			if not f then return p9.rerror(m.tag, dev.Ebadfid) end
			local ok, st = pcall(backend.stat, f.h)
			if not ok then return err(m.tag, st) end
			return p9.rstat(m.tag, statbytes(f.path, st))

		elseif m.type == p9.Twstat then
			-- accepted and ignored: the dev interface has no wstat,
			-- so mode, mtime and rename cannot be applied yet. A
			-- client that sets them (tar's utime and chmod) needs the
			-- accept not to fail; truncate and rename over 9P wait on
			-- dev growing wstat, the same way directory create waited
			-- on create growing a flag.
			if not fids[m.fid] then
				return p9.rerror(m.tag, dev.Ebadfid)
			end
			return p9.rwstat(m.tag)

		else
			return p9.rerror(m.tag, "operation not supported")
		end
	end

	return function(msg) return handle(p9.decode(msg)) end,
	    function() return msize end
end

-- speak 9P over rx/tx byte streams, framing as ninep.M.serve does. rx() ->
-- next bytes (blocking, "" or nil at eof); tx(bytes).
function M.serve(backend, rx, tx)
	local respond, getmsize = M.responder(backend)
	local buf = ""

	while true do
		local chunk = rx()
		if not chunk or chunk == "" then
			return
		end
		buf = buf .. chunk
		while #buf >= 4 do
			local size = string.unpack("<I4", buf)
			local ok = size >= 7 and size <= getmsize()
			if ok and #buf >= 5 then
				local typ = string.unpack("<B", buf, 5)
				ok = typ >= p9.Tversion and typ <= p9.Twstat and
				    typ % 2 == 0
			end
			if not ok then
				buf = buf:sub(2)	-- resync, one byte
			elseif #buf < size then
				break			-- await the rest
			else
				local msg = buf:sub(1, size)
				buf = buf:sub(size + 1)
				tx(respond(msg))
			end
		end
	end
end

return M
