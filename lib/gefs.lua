-- gefs, the good enough file system, in Lua.
--
-- A Bε-tree filesystem: one sorted key-value map holding dirents, file
-- data and snapshots, copy-on-write throughout, with every block
-- checksummed by the pointer that reaches it. This is a port of Ori
-- Bernstein's gefs from 9front, working from the source rather than the
-- paper, and it reads and writes the same on-disk format.
--
-- Nothing here does i/o. A volume is opened on a device, which is any
-- table answering read(off, len), write(off, s) and size(); gefs.io
-- gives you one over a file (a host file, or /data from the block
-- driver through the namespace) and gefs.ram one in memory. That is the
-- whole boundary, and it is what lets the same code sit under a 9P
-- server, over a block device, or inside a test that cuts the power.
--
--      local gefs = require "gefs"
--      local dev  = gefs.io.create("/tmp/disk.img", 64 * 1024 * 1024)
--      gefs.ream(dev, { user = "glenda" })
--
--      local fs = gefs.open(dev)
--      local m  = fs:mount("main")
--      m:createfile("/hello")
--      m:writefile("/hello", "world\n")
--      fs:sync()
--
-- Changes are not on disk until sync(). Between syncs the volume on disk
-- is the last committed one, whole: a crash loses the work since the
-- last sync and never anything older.
--
-- One thread of control. The port collapsed upstream's mutate/read/sync
-- proc set into straight-line Lua with no locks, so a served volume is
-- handled one request at a time (see task/gefssrv.lua and its worker
-- count). Preemption of the serving proc is transparent -- its lua_State
-- is private -- but two cooperative workers sharing one fs would
-- interleave at a device yield and corrupt the unlocked tree.

local vol = require "gefs.vol"

require "gefs.store"
require "gefs.tree"
require "gefs.snap"
require "gefs.fsops"
require "gefs.check"

local M = {}

M.dat = require "gefs.dat"
M.hash = require "gefs.hash"
M.pack = require "gefs.pack"
M.blk = require "gefs.blk"
M.tree = require "gefs.tree"
M.fsops = require "gefs.fsops"
M.check = require "gefs.check"
M.ram = require "gefs.ram"
M.io = require "gefs.io"

M.ream = vol.ream
M.open = vol.open

M.VERSION = "0.1.0"

return M
