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
		m.fid = sunpack("<I4", msg, off)
	else
		m.unknown = true
	end
	return m
end

-- ---- encode R-messages ----

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

-- ---- server: speaks 9P2000 over rx/tx byte streams ----
-- rx() -> next chunk of bytes (blocking); tx(bytes)

function M.serve(root, rx, tx)
	local fids = {}
	local buf = ""
	local msize = M.MSIZE

	local function reply(r)
		tx(r)
	end

	local function handle(m)
		if m.type == M.Tversion then
			fids = {}
			if m.msize < msize then msize = m.msize end
			if m.version:sub(1, 2) ~= "9P" then
				return reply(M.rversion(m.tag, msize,
				    "unknown"))
			end
			return reply(M.rversion(m.tag, msize, M.VERSION))
		elseif m.type == M.Tauth then
			return reply(M.rerror(m.tag,
			    "authentication not required"))
		elseif m.type == M.Tattach then
			fids[m.fid] = root
			return reply(M.rattach(m.tag, root.qid))
		elseif m.type == M.Tflush then
			return reply(M.rflush(m.tag))
		elseif m.type == M.Twalk then
			local n = fids[m.fid]
			if not n then
				return reply(M.rerror(m.tag, "unknown fid"))
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
					return reply(M.rerror(m.tag,
					    "file not found"))
				end
				return reply(M.rwalk(m.tag, qids))
			end
			fids[m.newfid] = n
			return reply(M.rwalk(m.tag, qids))
		elseif m.type == M.Topen then
			local n = fids[m.fid]
			if not n then
				return reply(M.rerror(m.tag, "unknown fid"))
			end
			return reply(M.ropen(m.tag, n.qid, msize - 24))
		elseif m.type == M.Tread then
			local n = fids[m.fid]
			if not n then
				return reply(M.rerror(m.tag, "unknown fid"))
			end
			local count = m.count
			if count > msize - 24 then count = msize - 24 end
			local data
			if n.children then
				data = dirdata(n, m.offset, count)
			else
				data = nodedata(n, m.offset, count)
			end
			return reply(M.rread(m.tag, data))
		elseif m.type == M.Twrite then
			local n = fids[m.fid]
			if not n then
				return reply(M.rerror(m.tag, "unknown fid"))
			end
			if not n.write then
				return reply(M.rerror(m.tag,
				    "permission denied"))
			end
			n.write(m.offset, m.data)
			return reply(M.rwrite(m.tag, #m.data))
		elseif m.type == M.Tclunk then
			fids[m.fid] = nil
			return reply(M.rclunk(m.tag))
		elseif m.type == M.Tstat then
			local n = fids[m.fid]
			if not n then
				return reply(M.rerror(m.tag, "unknown fid"))
			end
			return reply(M.rstat(m.tag, nodestat(n)))
		else
			return reply(M.rerror(m.tag, "operation not supported"))
		end
	end

	while true do
		buf = buf .. rx()
		while #buf >= 4 do
			local size = sunpack("<I4", buf)
			if size < 7 or size > 0x100000 then
				buf = ""	-- desync, drop
				break
			end
			if #buf < size then
				break
			end
			local msg = buf:sub(1, size)
			buf = buf:sub(size + 1)
			handle(M.decode(msg))
		end
	end
end

return M
