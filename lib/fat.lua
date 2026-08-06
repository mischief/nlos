-- FAT12, FAT16 and FAT32 in pure Lua, as UEFI 13.3.1 fixes them.
--
-- The EFI system partition is FAT and nothing else, and the
-- specification says the format is a fixed target: it does not follow
-- FAT's later errata or a driver's interpretation of them. So this is
-- written to the specification and to the long name rules it points at,
-- and it reads and writes what firmware reads and writes.
--
-- Nothing here does i/o. A volume is opened on a device, which is any
-- table answering read(off, len), write(off, s) and size(); fat.file
-- gives you one over a host file and fat.ram one in memory. That is the
-- whole boundary, and it is what lets the same code sit under an EFI
-- driver, over a USB mass storage device, or inside a test.
--
--      local fat = require "fat"
--
--      local dev = fat.ram.new(64 * 1024 * 1024)
--      local fs  = fat.ream(dev, { label = "ESP" })
--
--      fs:mkdirp("/EFI/BOOT")
--      fs:writefile("/EFI/BOOT/BOOTX64.EFI", image)
--      fs:sync()
--
-- Changes are not on the device until sync(). FAT has no journal, so
-- that is a point where the device holds everything written so far and
-- not a promise about what a crash before it leaves behind -- there is
-- no ordering of sector writes that makes a half-flushed FAT volume
-- consistent, and check() is what says how far off it landed.

local vol = require "fat.vol"

require "fat.blk"
require "fat.fat"
require "fat.dir"
require "fat.fsops"
require "fat.check"

local M = {}

M.dat = require "fat.dat"
M.pack = require "fat.pack"
M.dir = require "fat.dir"
M.fsops = require "fat.fsops"
M.check = require "fat.check"
M.vol = require "fat.vol"
M.ram = require "fat.ram"

M.ream = vol.ream
M.open = vol.open

M.VERSION = "0.1.0"

return M
