-- p9fs: a dev backend (see lib/dev.lua) over a real 9P2000.u
-- connection -- los.platform.p9's virtio-9p transport, decoded with
-- lib/ninep.lua's client half.
--
-- lib/p9srv.lua serves this on a port (lib/srv.lua) exactly the way
-- lib/espsrv.lua serves the esp. there is no bridging to do here
-- beyond speaking the wire and re-presenting it as the same dev
-- interface every other backend already uses: virtio-9p IS a 9P
-- server, at the wire level, before any of our code runs. mnt.lua
-- neither knows nor cares what is on the other end -- there is only
-- ever one namespace mechanism, this is just another backend for it.
--
-- one virtio-9p CONNECTION (fid 0, attached once in M.new) serves
-- every client of this task's port; each dev handle gets its OWN
-- cloned fid (a zero-element Twalk) so that clunking a handle -- which
-- happens constantly, e.g. every __gc on the mnt.lua side -- can never
-- take down the shared root fid every other session also depends on.

local ninep = require("ninep")
local dev = require("dev")

local M = {}

local TAG = 1
local err = dev.error

local function checkreply(rep, wanttype, what)
	local m = ninep.decode(rep)

	if m.type == ninep.Rerror then
		err(m.ename)
	end
	if m.type ~= wanttype then
		err(what .. ": unexpected reply type " .. tostring(m.type))
	end
	return m
end

-- transport defaults to the real device (los.platform.p9, PRIV_P9
-- only); pass one explicitly to talk to anything else that answers
-- {rpc = function(reqbytes) return replybytes end} -- e.g. a self-mount
-- loopback straight into lib/ninep.lua's OWN M.responder(), which is
-- how test/boot/test_ninep_selfmount.lua exercises the base-9P2000
-- code path with no virtio-9p device at all (qemu's is .u-only).
function M.new(transport)
	local p9 = transport or require("los.platform.p9")
	local B = {}
	local next_fid = 1

	-- propose .u (what qemu's virtio-9p always negotiates down to
	-- anyway); a server that only speaks base 9P2000 -- this module's
	-- own M.serve, or any generic 9P2000 fileserver -- replies
	-- "9P2000" instead, per ordinary 9P version negotiation, and dotu
	-- below drives every place after this that the two dialects
	-- differ (Tattach's n_uname, Tcreate's extension). anything else
	-- (including "unknown") is a server we can't drive at all.
	local vm = ninep.decode(p9.rpc(ninep.tversion(ninep.NOTAG, 8192, "9P2000.u")))

	if vm.type ~= ninep.Rversion or
	    (vm.version ~= "9P2000.u" and vm.version ~= "9P2000") then
		error("p9fs: version negotiation failed (" ..
		    tostring(vm.version) .. ")")
	end

	local dotu = (vm.version == "9P2000.u")

	checkreply(p9.rpc(ninep.tattach(TAG, 0, ninep.NOFID, "root", "",
	    dotu and ninep.NONUNAME or nil)), ninep.Rattach, "attach")

	local function newfid()
		local f = next_fid

		next_fid = next_fid + 1
		return f
	end

	-- clone fid via a zero-element walk: every handle this backend
	-- ever hands out owns an independently-clunkable fid.
	local function clone(fid)
		local nfid = newfid()

		checkreply(p9.rpc(ninep.tclone(TAG, fid, nfid)), ninep.Rwalk, "clone")
		return nfid
	end

	local function h_of(fid, isdir, name)
		return { fid = fid, isdir = isdir, name = name }
	end

	function B.attach()
		return h_of(clone(0), true, "/")
	end

	function B.walk(h, name)
		if not h.isdir then
			err(dev.Enotdir)
		end

		local nfid = newfid()
		local m = checkreply(p9.rpc(ninep.twalk(TAG, h.fid, nfid, { name })),
		    ninep.Rwalk, "walk")

		if #m.wqid ~= 1 then
			err(dev.Enonexist)
		end
		return h_of(nfid, (m.wqid[1].type & 0x80) ~= 0, name)
	end

	function B.stat(h)
		local m = checkreply(p9.rpc(ninep.tstat(TAG, h.fid)),
		    ninep.Rstat, "stat")
		local st = ninep.unpackstat(m.statbytes)

		return {
			name = h.name,
			size = st.length,
			dir = (st.mode & 0x80000000) ~= 0,
		}
	end

	-- open never mutates the handed-in handle -- it clones a fresh
	-- fid, same rule as lib/espfs.lua's open() and for the same
	-- reason: the walked handle and the opened one get separate
	-- lifetimes (separate __gc clunks) on the mnt.lua side.
	function B.open(h, mode)
		local nfid = clone(h.fid)

		if h.isdir then
			if mode ~= "r" then
				err(dev.Eisdir)
			end
			return dev.closable(B, h_of(nfid, true, h.name))
		end

		local m9mode = (mode == "r") and 0 or 1
		local ok = pcall(checkreply, p9.rpc(ninep.topen(TAG, nfid, m9mode)),
		    ninep.Ropen, "open")

		if not ok then
			pcall(p9.rpc, ninep.tclunk(TAG, nfid))
			err(mode == "r" and dev.Enonexist or dev.Eperm)
		end
		return dev.closable(B, h_of(nfid, false, h.name))
	end

	-- Tcreate makes AND opens in one step, like espfs.lua's create()
	-- over fs.open(path, "w"). the dev interface gives us no
	-- permission bits, so this always asks for a plain 0644 file;
	-- directory creation (perm's DMDIR bit) isn't exposed by this
	-- interface either and so isn't reachable from here.
	local PERM_0644 = 0x1A4

	function B.create(h, name, mode)
		if not h.isdir then
			err(dev.Enotdir)
		end

		local nfid = clone(h.fid)
		local m9mode = (mode == "r") and 0 or 1
		local ok = pcall(checkreply,
		    p9.rpc(ninep.tcreate(TAG, nfid, name, PERM_0644, m9mode,
		        dotu and "" or nil)),
		    ninep.Rcreate, "create")

		if not ok then
			pcall(p9.rpc, ninep.tclunk(TAG, nfid))
			err(dev.Eperm)
		end
		return dev.closable(B, h_of(nfid, false, name))
	end

	function B.read(h, off, n)
		if h.isdir then
			err(dev.Eisdir)
		end
		local m = checkreply(p9.rpc(ninep.tread(TAG, h.fid, off, n)),
		    ninep.Rread, "read")
		return m.data
	end

	function B.write(h, off, data)
		if h.isdir then
			err(dev.Eisdir)
		end
		local m = checkreply(p9.rpc(ninep.twrite(TAG, h.fid, off, data)),
		    ninep.Rwrite, "write")
		return m.count
	end

	-- directories need their own Topen before Tread, same as files,
	-- but readdir()'s contract (lib/dev.lua) doesn't require a prior
	-- open() -- so this opens (and clunks) its OWN cloned fid rather
	-- than touching h, matching open()'s never-mutate rule.
	function B.readdir(h)
		if not h.isdir then
			err(dev.Enotdir)
		end

		local fid = clone(h.fid)
		local ok = pcall(checkreply, p9.rpc(ninep.topen(TAG, fid, 0)),
		    ninep.Ropen, "readdir")

		if not ok then
			pcall(p9.rpc, ninep.tclunk(TAG, fid))
			err(dev.Eio)
		end

		local out, off = {}, 0

		while true do
			local m = checkreply(p9.rpc(ninep.tread(TAG, fid, off, 4096)),
			    ninep.Rread, "readdir")

			if #m.data == 0 then
				break
			end

			local pos = 1

			while pos <= #m.data do
				local n = string.unpack("<I2", m.data, pos)
				local rec = m.data:sub(pos + 2, pos + 1 + n)
				local st = ninep.unpackstat(rec)

				-- drop "." and ".." the same way lib/espfs.lua's
				-- readdir does: a listing lists CONTENTS, and
				-- ns.lua/dev.walkall already handle ".." itself.
				if st.name ~= "." and st.name ~= ".." then
					out[#out + 1] = {
						name = st.name,
						size = st.length,
						dir = (st.mode & 0x80000000) ~= 0,
					}
				end
				pos = pos + 2 + n
			end
			off = off + #m.data
		end
		p9.rpc(ninep.tclunk(TAG, fid))
		table.sort(out, function(a, b) return a.name < b.name end)
		return out
	end

	function B.clunk(h)
		pcall(p9.rpc, ninep.tclunk(TAG, h.fid))
	end

	return B
end

return M
