-- partsrv: serve one partition of the block device as its own /data.
--
-- It stacks on blksrv the way gefssrv stacks on this: it takes the blk
-- right, mounts the whole disk, reads the GPT to find a named partition,
-- and serves that window (lib/partfs.lua). A filesystem server mounts the
-- result and never learns there was a partition table -- the block offset
-- lives here and nowhere above.
--
-- protocol: the spawner sends { blk = {__right=}, partition = "gefs" } on
-- the self port, then mounts this proc's spawn right as a dev.
--
-- One worker: the partition is one seekable handle into the disk, and two
-- workers seeking it at once would race the position. gefssrv above is
-- single-threaded anyway, so this serialises nothing that was parallel.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local mnt = require("mnt")
local srv = require("srv")
local gpt = require("gpt")
local partfs = require("partfs")

local a = ...

thread.spawn(function()
	local init, cfg = require("svcarg")(a)
	local blk = init.blk.__right
	local name = cfg.partition or error("partsrv: no partition named", 0)

	local N = ns.new()
	assert(N:mount("/dev", mnt.new(blk), "mnt",
	    { port = { __right = blk } }))

	local h = assert(N:open("/dev/data", "rw"))

	-- a minimal read/size view of the disk for gpt.parse, so this server
	-- depends on the partition table and not on any filesystem
	local disk = {
		read = function(_, off, n)
			h:seek("set", off)
			local s = h:read(n) or ""
			if #s < n then s = s .. string.rep("\0", n - #s) end
			return s
		end,
	}

	local p = assert(gpt.find(disk, name),
	    "partsrv: no partition named " .. name)

	-- the same handle backs the gpt read above and partfs below; partfs
	-- seeks it per request, and there is only ever one request at a time
	srv.serve(partfs.new(h, p.off, p.bytes), sys.SELF, { workers = 1 })
end)
thread.run()
