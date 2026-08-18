-- ninep: 9P2000 wire codec and a small server, plan9 flavor.
-- little-endian, size[4] type[1] tag[2] prefix; strings are s[2]+bytes;
-- qids are type[1] vers[4] path[8].

local M = {}

-- message types
M.Tversion, M.Rversion = 100, 101
M.Tauth, M.Rauth = 102, 103
M.Tattach, M.Rattach = 104, 105
M.Rerror = 107
M.Tflush, M.Rflush = 108, 109
M.Twalk, M.Rwalk = 110, 111
M.Topen, M.Ropen = 112, 113
M.Tcreate, M.Rcreate = 114, 115
M.Tread, M.Rread = 116, 117
M.Twrite, M.Rwrite = 118, 119
M.Tclunk, M.Rclunk = 120, 121
M.Tremove, M.Rremove = 122, 123
M.Tstat, M.Rstat = 124, 125
M.Twstat, M.Rwstat = 126, 127

M.NOTAG = 0xffff
M.NOFID = 0xffffffff
M.NONUNAME = 0xffffffff	-- 9P2000.u/.L Tattach's n_uname: "use uname"

-- qid.type bits
M.QTDIR = 0x80
M.QTFILE = 0x00

M.DMDIR = 0x80000000

M.VERSION = "9P2000"
M.MSIZE = 8192

local spack, sunpack = string.pack, string.unpack

local function puts(s)
	return spack("<s2", s)
end

local function putqid(q)
	return spack("<BI4I8", q.type, q.vers or 0, q.path)
end

local function getqid(b, off)
	local t, v, p, noff = sunpack("<BI4I8", b, off)
	return { type = t, vers = v, path = p }, noff
end

-- stat structure (dir entry). used in Rstat and directory reads.
function M.packstat(st)
	local body = spack("<I2I4", 0, 0) ..	-- type, dev (kernel use)
	    putqid(st.qid) ..
	    spack("<I4I4I4I8", st.mode, st.atime or 0, st.mtime or 0,
		st.length or 0) ..
	    puts(st.name) .. puts(st.uid or "luaos") ..
	    puts(st.gid or "luaos") .. puts(st.muid or "luaos")
	return spack("<I2", #body) .. body
end

-- a stat for Twstat, where every field left out means "do not change
-- it". 9P spells that all-ones for a number and empty for a string, so
-- packstat's zeros would ask to set the mode to zero and the length to
-- nothing. Only what the caller names is asked for.
function M.packwstat(st)
	local q = st.qid or {}
	local body = spack("<I2I4", 0xffff, 0xffffffff) ..
	    spack("<BI4I8", q.type or 0xff, q.vers or 0xffffffff,
		q.path or -1) ..
	    spack("<I4I4I4I8", st.mode or 0xffffffff, st.atime or 0xffffffff,
		st.mtime or 0xffffffff, st.length or -1) ..
	    puts(st.name or "") .. puts(st.uid or "") ..
	    puts(st.gid or "") .. puts(st.muid or "")

	return spack("<I2", #body) .. body
end

-- the inverse of packstat: sb is one stat record's bytes, WITHOUT the
-- outer stat[n2] wrapper length (M.decode's Rstat branch already
-- strips that into m.statbytes; a directory Tread's raw entries are
-- also each one of these, back to back, each still wrapped in its own
-- n2 that the caller strips per-entry).
function M.unpackstat(sb)
	local _typ, _dev, off = sunpack("<I2I4", sb)
	local qid

	qid, off = getqid(sb, off)

	local mode, atime, mtime, length

	mode, atime, mtime, length, off = sunpack("<I4I4I4I8", sb, off)

	local name, uid, gid, muid

	name, off = sunpack("<s2", sb, off)
	uid, off = sunpack("<s2", sb, off)
	gid, off = sunpack("<s2", sb, off)
	muid, off = sunpack("<s2", sb, off)
	return {
		qid = qid, mode = mode, atime = atime, mtime = mtime,
		length = length, name = name, uid = uid, gid = gid, muid = muid,
	}
end

-- ---- decode a T-message into a table ----

function M.decode(msg)
	local size, typ, tag, off = sunpack("<I4BI2", msg)
	local m = { type = typ, tag = tag, size = size }

	if typ == M.Tversion then
		m.msize, m.version = sunpack("<I4s2", msg, off)
	elseif typ == M.Tauth then
		m.afid, m.uname, m.aname = sunpack("<I4s2s2", msg, off)
	elseif typ == M.Tattach then
		m.fid, m.afid, m.uname, m.aname =
		    sunpack("<I4I4s2s2", msg, off)
	elseif typ == M.Tflush then
		m.oldtag = sunpack("<I2", msg, off)
	elseif typ == M.Twalk then
		local n
		m.fid, m.newfid, n, off = sunpack("<I4I4I2", msg, off)
		m.wname = {}
		for i = 1, n do
			m.wname[i], off = sunpack("<s2", msg, off)
		end
	elseif typ == M.Topen then
		m.fid, m.mode = sunpack("<I4B", msg, off)
	elseif typ == M.Tcreate then
		m.fid, m.name, m.perm, m.mode =
		    sunpack("<I4s2I4B", msg, off)
	elseif typ == M.Tread then
		m.fid, m.offset, m.count = sunpack("<I4I8I4", msg, off)
	elseif typ == M.Twrite then
		local count
		m.fid, m.offset, count, off = sunpack("<I4I8I4", msg, off)
		m.data = msg:sub(off, off + count - 1)
	elseif typ == M.Tclunk or typ == M.Tremove or typ == M.Tstat then
		m.fid = sunpack("<I4", msg, off)
	elseif typ == M.Twstat then
		-- fid, then a stat double-wrapped exactly as Rstat's is: an
		-- outer count around a record carrying its own size.
		local n

		m.fid, off = sunpack("<I4", msg, off)
		_, off = sunpack("<I2", msg, off)
		n, off = sunpack("<I2", msg, off)
		if off + n - 1 > #msg then
			return nil
		end
		m.statbytes = msg:sub(off, off + n - 1)

	-- ---- R-messages: the client side's half of decode ----
	elseif typ == M.Rerror then
		m.ename = sunpack("<s2", msg, off)
	elseif typ == M.Rversion then
		m.msize, m.version = sunpack("<I4s2", msg, off)
	elseif typ == M.Rattach then
		m.qid = getqid(msg, off)
	elseif typ == M.Rwalk then
		local n
		n, off = sunpack("<I2", msg, off)
		m.wqid = {}
		for i = 1, n do
			m.wqid[i], off = getqid(msg, off)
		end
	elseif typ == M.Ropen or typ == M.Rcreate then
		m.qid, off = getqid(msg, off)
		m.iounit = sunpack("<I4", msg, off)
	elseif typ == M.Rread then
		local count
		count, off = sunpack("<I4", msg, off)
		m.data = msg:sub(off, off + count - 1)
	elseif typ == M.Rwrite then
		m.count = sunpack("<I4", msg, off)
	elseif typ == M.Rclunk or typ == M.Rremove or typ == M.Rflush then
		-- empty body
	elseif typ == M.Rstat then
		-- Rstat double-wraps: an outer stat[n] count around a
		-- record that ALSO starts with its own size[2]. Strip
		-- both, so statbytes is the bare body unpackstat wants.
		-- The outer count is discarded because qemu marshals it as
		-- a literal zero; the record's own size is the real one.
		local n

		_, off = sunpack("<I2", msg, off)
		n, off = sunpack("<I2", msg, off)
		-- refused rather than truncated, and nil as src/ninep.c
		-- answers: sub would clamp and hand back a short record,
		-- which unpackstat reads as a stat missing fields off the
		-- end rather than as a message that did not arrive whole.
		if off + n - 1 > #msg then
			return nil
		end
		m.statbytes = msg:sub(off, off + n - 1)
	else
		m.unknown = true
	end
	return m
end

-- ---- encode messages: frame() is generic (size+type+tag+body), used
-- for both the server's R-messages below and the client's T-message
-- builders further down.

local function frame(typ, tag, body)
	return spack("<I4BI2", 4 + 1 + 2 + #body, typ, tag) .. body
end

function M.rversion(tag, msize, version)
	return frame(M.Rversion, tag, spack("<I4s2", msize, version))
end

function M.rerror(tag, ename)
	return frame(M.Rerror, tag, puts(ename))
end

function M.rattach(tag, qid)
	return frame(M.Rattach, tag, putqid(qid))
end

function M.rflush(tag)
	return frame(M.Rflush, tag, "")
end

function M.rwalk(tag, qids)
	local b = spack("<I2", #qids)
	for _, q in ipairs(qids) do
		b = b .. putqid(q)
	end
	return frame(M.Rwalk, tag, b)
end

function M.ropen(tag, qid, iounit)
	return frame(M.Ropen, tag, putqid(qid) .. spack("<I4", iounit or 0))
end

-- Rcreate is Ropen's body under a different type: the new file's qid and
-- the iounit for writing it.
function M.rcreate(tag, qid, iounit)
	return frame(M.Rcreate, tag, putqid(qid) .. spack("<I4", iounit or 0))
end

function M.rread(tag, data)
	return frame(M.Rread, tag, spack("<I4", #data) .. data)
end

function M.rwrite(tag, count)
	return frame(M.Rwrite, tag, spack("<I4", count))
end

function M.rclunk(tag)
	return frame(M.Rclunk, tag, "")
end

function M.rstat(tag, statb)
	return frame(M.Rstat, tag, spack("<I2", #statb) .. statb)
end

-- Rwstat has an empty body: it says only that the wstat was accepted.
function M.rwstat(tag)
	return frame(M.Rwstat, tag, "")
end

-- ---- encode T-messages: the client side ----
-- a fid space and NOTAG/tag bookkeeping belong to whoever drives these
-- (see the microvm platform's los.platform.p9-backed client, which
-- talks to the virtio-9p transport one synchronous rpc() at a time and
-- so never needs more than one tag in flight).

function M.tversion(tag, msize, version)
	return frame(M.Tversion, tag, spack("<I4s2", msize, version or M.VERSION))
end

-- n_uname is 9P2000.u/.L's one addition to Tattach (a numeric uid,
-- trailing the base message) -- omit it to speak plain 9P2000 (what
-- M.serve above does); pass M.NONUNAME or a uid to talk to a .u/.L
-- server (e.g. qemu's virtio-9p, which never negotiates plain 9P2000
-- at all -- see hw/9pfs/9p.c).
function M.tattach(tag, fid, afid, uname, aname, n_uname)
	local body = spack("<I4I4s2s2", fid, afid or M.NOFID, uname or "", aname or "")

	if n_uname then
		body = body .. spack("<I4", n_uname)
	end
	return frame(M.Tattach, tag, body)
end

function M.twalk(tag, fid, newfid, wname)
	wname = wname or {}
	local body = spack("<I4I4I2", fid, newfid, #wname)
	for _, name in ipairs(wname) do
		body = body .. puts(name)
	end
	return frame(M.Twalk, tag, body)
end

function M.topen(tag, fid, mode)
	return frame(M.Topen, tag, spack("<I4B", fid, mode or 0))
end

-- 9P2000.u/.L's Tcreate gains a trailing "extension" string (used for
-- symlink targets/device numbers on special files; "" for a plain
-- file) -- same shape as Tattach's n_uname, and for the same reason:
-- qemu's virtio-9p server never negotiates plain 9P2000 (see
-- hw/9pfs/9p.c's v9fs_create, format string "dsdbs" -- fid, name, perm,
-- mode, extension). pass extension=nil to speak plain 9P2000's
-- shorter "dsdb" instead (what lib/p9fs.lua does against a server that
-- negotiated base 9P2000, e.g. this module's own M.serve); anything
-- else, even "", gets the field appended.
function M.tcreate(tag, fid, name, perm, mode, extension)
	local body = spack("<I4", fid) .. puts(name) ..
	    spack("<I4B", perm, mode or 0)

	if extension ~= nil then
		body = body .. puts(extension)
	end
	return frame(M.Tcreate, tag, body)
end

function M.tread(tag, fid, offset, count)
	return frame(M.Tread, tag, spack("<I4I8I4", fid, offset, count))
end

function M.twrite(tag, fid, offset, data)
	return frame(M.Twrite, tag, spack("<I4I8I4", fid, offset, #data) .. data)
end

function M.tclunk(tag, fid)
	return frame(M.Tclunk, tag, spack("<I4", fid))
end

-- abandon a pending request. `tag` is this message's OWN tag, which is
-- what the server echoes back in the Rflush -- not `oldtag`, which
-- names the request being given up on. Getting that backwards routes
-- the Rflush to the very waiter that is being cancelled.
--
-- A Tflush is never answered with an Rerror (see flush(5)), so a client
-- has only two outcomes to handle: the Rflush, or the original reply
-- arriving first. The second is not an error either -- the request may
-- have completed, and a completed Twalk allocated a fid that now has to
-- be accounted for.
function M.tflush(tag, oldtag)
	return frame(M.Tflush, tag, spack("<I2", oldtag))
end

-- Twalk with an empty wname list: 9P's clone-a-fid idiom (walk zero
-- elements, land on newfid pointing at the same file as fid). used to
-- give each attach()/open() its own fid without a second Tattach.
function M.tclone(tag, fid, newfid)
	return M.twalk(tag, fid, newfid, {})
end

function M.tstat(tag, fid)
	return frame(M.Tstat, tag, spack("<I4", fid))
end

-- change what a fid names. `st` carries only the fields to change, so
-- {name = "new"} is a rename within the file's own directory -- which is
-- as far as wstat reaches, the stat having a name and no path.
function M.twstat(tag, fid, st)
	local sb = M.packwstat(st)

	return frame(M.Twstat, tag,
	    spack("<I4", fid) .. spack("<I2", #sb) .. sb)
end

-- ---- synthetic filesystem tree ----
-- node: {name=, qid=, mode=, read=fn(off,n)->data | data=string,
--        children={node...} (dir)}

local nextpath = 0

local function mknode(name, spec)
	nextpath = nextpath + 1
	local n = {
		name = name,
		parent = nil,
	}
	if type(spec) == "table" and spec.children then
		n.qid = { type = M.QTDIR, vers = 0, path = nextpath }
		n.mode = M.DMDIR | 0x1ED	-- dir 755
		n.children = {}
		for cname, cspec in pairs(spec.children) do
			local c = mknode(cname, cspec)
			c.parent = n
			n.children[cname] = c
		end
	else
		n.qid = { type = M.QTFILE, vers = 0, path = nextpath }
		n.mode = 0x1A4			-- file 644
		if type(spec) == "string" then
			n.data = spec
		elseif type(spec) == "function" then
			n.read = spec
		elseif type(spec) == "table" then
			n.data = spec.data
			n.read = spec.read
			n.write = spec.write
			if spec.mode then n.mode = spec.mode end
		end
	end
	return n
end

function M.synth(rootchildren)
	return mknode("/", { children = rootchildren })
end

local function nodedata(n, off, count)
	local data
	if n.read then
		data = n.read(off, count) or ""
		return data	-- read fn handles offsets itself
	end
	data = n.data or ""
	if off >= #data then
		return ""
	end
	return data:sub(off + 1, off + count)
end

local function nodestat(n)
	return M.packstat({
		qid = n.qid,
		mode = n.mode,
		length = n.data and #n.data or 0,
		name = n.name == "/" and "/" or n.name,
	})
end

local function dirdata(n, off, count)
	-- directory read: packed stats, honoring the byte offset protocol
	local all = {}
	for _, c in pairs(n.children) do
		all[#all + 1] = c
	end
	table.sort(all, function(a, b) return a.name < b.name end)
	local b = {}
	for _, c in ipairs(all) do
		b[#b + 1] = nodestat(c)
	end
	local whole = table.concat(b)
	if off >= #whole then
		return ""
	end
	-- 9p requires reads at stat boundaries; trust off from prior reads
	local chunk = whole:sub(off + 1)
	if #chunk <= count then
		return chunk
	end
	-- truncate to whole stat entries within count
	local out, pos = {}, 1
	local used = 0
	while pos <= #chunk do
		if pos + 1 > #chunk then break end
		local sz = sunpack("<I2", chunk, pos) + 2
		if used + sz > count then break end
		out[#out + 1] = chunk:sub(pos, pos + sz - 1)
		used = used + sz
		pos = pos + sz
	end
	return table.concat(out)
end

-- ---- server: per-message dispatch, over a byte stream OR standalone
-- ----
--
-- M.responder(root) is the whole server, minus any transport: it
-- returns one function, msg -> replybytes, with no stream framing or
-- rx/tx involved. that's the shape lib/p9fs.lua's transport (send one
-- request, get one reply) already is, so a self-mount loopback --
-- lib/p9fs.lua's OWN client talking to THIS server, in one process,
-- with no device at all -- is just this function wired straight into
-- p9fs.new()'s transport parameter. M.serve below is the same
-- responder with byte-stream framing wrapped around it, for when the
-- other end is actually a wire.

function M.responder(root)
	local fids = {}
	local msize = M.MSIZE

	local function handle(m)
		if m.type == M.Tversion then
			fids = {}
			if m.msize < msize then msize = m.msize end
			if m.version:sub(1, 2) ~= "9P" then
				return M.rversion(m.tag, msize, "unknown")
			end
			return M.rversion(m.tag, msize, M.VERSION)
		elseif m.type == M.Tauth then
			return M.rerror(m.tag, "authentication not required")
		elseif m.type == M.Tattach then
			fids[m.fid] = root
			return M.rattach(m.tag, root.qid)
		elseif m.type == M.Tflush then
			return M.rflush(m.tag)
		elseif m.type == M.Twalk then
			local n = fids[m.fid]
			if not n then
				return M.rerror(m.tag, "unknown fid")
			end
			local qids = {}
			for _, name in ipairs(m.wname) do
				if name == ".." then
					n = n.parent or n
				elseif n.children and n.children[name] then
					n = n.children[name]
				else
					n = nil
				end
				if not n then break end
				qids[#qids + 1] = n.qid
			end
			if #qids < #m.wname then
				if #qids == 0 then
					return M.rerror(m.tag, "file not found")
				end
				return M.rwalk(m.tag, qids)
			end
			fids[m.newfid] = n
			return M.rwalk(m.tag, qids)
		elseif m.type == M.Topen then
			local n = fids[m.fid]
			if not n then
				return M.rerror(m.tag, "unknown fid")
			end
			return M.ropen(m.tag, n.qid, msize - 24)
		elseif m.type == M.Tread then
			local n = fids[m.fid]
			if not n then
				return M.rerror(m.tag, "unknown fid")
			end
			local count = m.count
			if count > msize - 24 then count = msize - 24 end
			local data
			if n.children then
				data = dirdata(n, m.offset, count)
			else
				data = nodedata(n, m.offset, count)
			end
			return M.rread(m.tag, data)
		elseif m.type == M.Twrite then
			local n = fids[m.fid]
			if not n then
				return M.rerror(m.tag, "unknown fid")
			end
			if not n.write then
				return M.rerror(m.tag, "permission denied")
			end
			n.write(m.offset, m.data)
			return M.rwrite(m.tag, #m.data)
		elseif m.type == M.Tclunk then
			fids[m.fid] = nil
			return M.rclunk(m.tag)
		elseif m.type == M.Tstat then
			local n = fids[m.fid]
			if not n then
				return M.rerror(m.tag, "unknown fid")
			end
			return M.rstat(m.tag, nodestat(n))
		else
			return M.rerror(m.tag, "operation not supported")
		end
	end

	local function respond(msg)
		return handle(M.decode(msg))
	end

	local function getmsize()
		return msize
	end

	return respond, getmsize
end

-- speaks 9P2000 over rx/tx byte streams. rx() -> next chunk of bytes
-- (blocking); tx(bytes). framing (and the resync-on-garbage below) is
-- the only thing this adds over M.responder.
function M.serve(root, rx, tx)
	local respond, getmsize = M.responder(root)
	local buf = ""

	while true do
		buf = buf .. rx()
		while #buf >= 4 do
			local size = sunpack("<I4", buf)
			-- resync rather than flush: a plausible frame is
			-- 7..msize bytes and, once the type byte is visible,
			-- carries an even T-message type in 100..126. on a bad
			-- header (usually a dropped byte upstream) skip a single
			-- byte and retry, so good frames behind the corruption
			-- survive instead of being discarded with buf = "".
			local ok = size >= 7 and size <= getmsize()
			if ok and #buf >= 5 then
				local typ = sunpack("<B", buf, 5)
				ok = typ >= M.Tversion and typ <= M.Twstat and
				    typ % 2 == 0
			end
			if not ok then
				buf = buf:sub(2)	-- drop one, re-align
			elseif #buf < size then
				break			-- header ok, await rest
			else
				local msg = buf:sub(1, size)
				buf = buf:sub(size + 1)
				tx(respond(msg))
			end
		end
	end
end


-- the C codec when this is a lua-os proc, these when it is not.
--
-- Everything above stays reachable as M.pure, so the two can be checked
-- against each other (test/boot/test_ninepc.lua) and so a host tool
-- driving this file under an ordinary lua5.4 still works. Chosen once
-- here rather than branched per call.
M.pure = {
	decode = M.decode,
	packstat = M.packstat,
	unpackstat = M.unpackstat,
	rread = M.rread,
	twrite = M.twrite,
	tread = M.tread,
	twalk = M.twalk,
}

local ok, c = pcall(require, "los.ninep")

if ok and type(c) == "table" then
	for name in pairs(M.pure) do
		if type(c[name]) == "function" then
			M[name] = c[name]
		end
	end
end

return M
