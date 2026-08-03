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

srv.main(function()
	local init = thread.recv(sys.SELF)
	local blk = init.blk.__right
	local label = init.label or "main"

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

	local fs = gefs.open(dev, { clockfn = clock })
	return gefsfs.new(fs:mount(label))
end, { workers = 1 })
