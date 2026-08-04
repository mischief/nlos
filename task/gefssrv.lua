-- gefssrv: a gefs volume served as an ordinary dev backend.
--
-- Unlike task/blksrv.lua this owns no raw device -- it stacks on one. The
-- block server holds PRIV_BLK; this holds an ordinary right to it, handed
-- over at spawn the way task/dns.lua is handed a udp right:
--
--	local _, g = sys.spawn(io.open("/task/gefssrv.lua"):read("a"),
--	    { name = "gefssrv" })
--	sys.send(g, { blk = { __right = blkright }, label = "main" })
--	N:mount("/n/g", mnt.new(g), "mnt", { port = { __right = g } })
--
-- so g is both how the volume label reaches this proc and, once serving,
-- the mount right every client holds. The init message arrives first on
-- sys.SELF and is consumed before the serve loop, which then answers the
-- attach that mount sends next.
--
-- One worker, always. The port is one thread of control with no locks
-- (see lib/gefs.lua and lib/gefsfs.lua): served one request at a time,
-- each runs to completion -- across its device yields -- before the next,
-- so the unlocked tree is never interleaved. A second worker would
-- corrupt it. Many clients may still send at once; they queue at the
-- port and are answered in turn, which is upstream gefs's single-mutator
-- funnel by another name.
--
-- Writes only reach the disk at a sync, so the volume is committed on a
-- clock: srv.serve's tick calls the backend's sync between requests,
-- never beside one, at most every syncms and once more as the server
-- shuts down. A client can also force it by writing "sync" to /ctl. This
-- is 9front gefs's runtasks timer and ctl "sync" in one, and the reason
-- the tick runs in the serve loop rather than a thread of its own is the
-- same one worker: a second thread syncing would interleave with a
-- request. Default 5s, as upstream; the spawner may ask for less.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local mnt = require("mnt")
local srv = require("srv")
local gefs = require("gefs")
local gefsfs = require("gefsfs")

-- the freestanding kernel has no os.time; uptime is the monotonic clock
-- this machine has, in nanoseconds for the on-disk mtime field.
local function clock()
	return sys.uptime_ms() * 1000000
end

-- srv.serve directly rather than srv.main, so the sync interval can come
-- from the init message (build() runs after it, too late to shape opts).
thread.spawn(function()
	local init = thread.recv(sys.SELF)
	local blk = init.blk.__right
	local label = init.label or "main"
	local syncms = init.syncms or 5000
	-- a cached block is the parsed Blk, ~2x its 16KiB on disk, so the
	-- library's 512-block default is ~16MiB -- too much to hand one
	-- filesystem on a 128-256MiB machine, and mostly empty ceiling for
	-- the small files served here. 128 (~4MiB) holds the tree metadata
	-- and a working set with room to spare; the spawner may ask for more.
	local cachesz = init.cachesz or 128

	-- mount the block device and open /data as a seekable file, exactly
	-- as a client of blksrv would -- gefs sits on the file, not on virtio
	local N = ns.new()
	assert(N:mount("/dev", mnt.new(blk), "mnt",
	    { port = { __right = blk } }))

	local ctl = N:readfile("/dev/ctl")
	local size = tonumber(ctl and ctl:match("bytes (%d+)"))
	assert(size and size > 0, "the block device did not report its size")

	local h = assert(N:open("/dev/data", "rw"))
	local dev = gefs.io.wrap(h, size)

	local fs = gefs.open(dev, { clockfn = clock, cachesz = cachesz })
	local backend = gefsfs.new(fs:mount(label))

	srv.serve(backend, sys.SELF, {
		workers = 1,
		tick = { ms = syncms, fn = function(B) B.sync() end },
	})
end)
thread.run()
