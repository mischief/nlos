-- fatsrv: a FAT volume served as an ordinary dev backend.
--
-- Stacks on a block device the way task/gefssrv.lua does: the block
-- server holds the device capability, this holds an ordinary right to
-- it, handed over at spawn.
--
--	local _, f = sys.spawn(src, { name = "fatsrv" })
--	sys.send(f, { blk = { __right = flashright } })
--	N:mount("/", mnt.new(f), "mnt", { port = { __right = f } })
--
-- so f is both how the device reaches this proc and, once serving, the
-- mount right every client holds.
--
-- The device underneath may be the flash partition or the microSD card.
-- Neither is named here: what arrives is a right, and the sectors it
-- reaches are whatever the proc that granted it decided.
--
-- One worker, as gefssrv has. lib/fat has no locks, so a request runs
-- to completion -- across its device round trips -- before the next
-- starts. Many clients may send at once; they queue at the port.
--
-- Writes reach the flash at a sync, so the volume is committed on a
-- clock: srv.serve's tick calls the backend's sync between requests and
-- once more at shutdown, and a client can force it by writing "sync" to
-- /ctl.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local mnt = require("mnt")
local srv = require("srv")
local fat = require("fat")
local fatfs = require("fatfs")
local gefsio = require("gefs.io")

thread.spawn(function()
	local init = thread.recv(sys.SELF)
	local blk = init.blk.__right
	local syncms = init.syncms or 5000

	-- mount the block device and open /data as a seekable file,
	-- exactly as any other client of blksrv would. The filesystem sits
	-- on the file and knows nothing about flash or about SPI.
	local N = ns.new()

	assert(N:mount("/dev", mnt.new(blk), "mnt",
	    { port = { __right = blk } }))

	local ctl = N:readfile("/dev/ctl")
	local size = tonumber(ctl and ctl:match("bytes (%d+)"))

	assert(size and size > 0, "the block device did not report its size")

	local h = assert(N:open("/dev/data", "rw"))
	-- a seekable handle as a device: read(off,len), write(off,s),
	-- size(), sync(). lib/fat and lib/gefs ask for the same four, so
	-- the wrapper serves both.
	local dev = gefsio.wrap(h, size)

	local fs = assert(fat.open(dev))

	srv.serve(fatfs.new(fs), sys.SELF, {
		workers = 1,
		tick = { ms = syncms, fn = function(B) B.sync() end },
	})
end)
thread.run()
