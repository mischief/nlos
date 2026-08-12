-- A device backed by a file, through stock Lua io.
--
-- The only module in the tree that does i/o, and it needs nothing but a
-- seekable file handle: seek, read, write, flush. That is deliberately
-- the smallest possible floor, because the same handle shape is what
-- io.open hands back on a host and what a namespace open of /data hands
-- back on the target (see lib/blkfs.lua on why /data is an ordinary
-- seekable file). So one device sits over a disk image under test and
-- over the real block driver, and neither end knows which.
--
-- luaposix is not required and not used: the gefs device contract is
-- read(off,len)/write(off,s)/size()/sync(), which is seek plus read,
-- seek plus write, and flush -- all of which a plain file handle has.
-- pread/pwrite and a true fsync would only matter to a shared or a
-- durability-critical fd, and the filesystem above is single-threaded.

local M = {}

local File = {}
File.__index = File

-- wrap an already-open seekable handle: the block device's /data handle
-- on the target, or any io handle. size is the device length in bytes;
-- if not given it is read off the end of the handle.
function M.wrap(handle, size)
  if size == nil then
    size = handle:seek("end") or 0
  end
  return setmetatable({ f = handle, nbytes = size }, File)
end

-- open a path. mode "r" is read-only; anything else is read-write on an
-- existing file. "b" is forced: a disk image is bytes, not text, and on
-- a host that does not distinguish it costs nothing.
function M.open(path, mode)
  local m = (mode == "r") and "rb" or "r+b"
  local f, err = io.open(path, m)
  if f == nil then return nil, err end
  return M.wrap(f)
end

-- create a file of exactly this size, which is what ream wants: a
-- regular file long enough to hold the volume it is about to describe.
-- The single byte written at the end leaves a sparse hole before it,
-- read back as zeroes, which is the blank device ream expects.
function M.create(path, size)
  local f, err = io.open(path, "w+b")
  if f == nil then return nil, err end
  if size > 0 then
    f:seek("set", size - 1)
    f:write("\0")
    f:flush()
  end
  return M.wrap(f, size)
end

function File:size() return self.nbytes end

function File:read(off, len)
  self.f:seek("set", off)
  local s = self.f:read(len)
  if s == nil then s = "" end
  -- a read that runs off the end (or into a sparse hole past what was
  -- written) is zero-filled to the length asked for, the same answer a
  -- blank block gives
  if #s < len then s = s .. string.rep("\0", len - #s) end
  return s
end

-- All of s or an error. A chan handle answers with a count, and a
-- short count is a write that never fully reached the device: raising
-- keeps the sector dirty above rather than losing it silently.
function File:write(off, s)
  -- fat hands the sector out as it holds it, which is a los.buf. A stock
  -- lua file handle takes a string, so ask the buffer for its bytes.
  if type(s) ~= "string" then s = tostring(s.str and s:str() or s) end
  self.f:seek("set", off)
  local n, err = self.f:write(s)
  if not n then error("write failed: " .. tostring(err), 0) end
  if type(n) == "number" and n ~= #s then
    error(("short write at %d: %d of %d"):format(off, n, #s), 0)
  end
end

-- flush is as durable as this floor gets: it hands the bytes to the
-- layer below (the OS, or the block driver), which is what "the write
-- happened" means to everything above. A file handle has no fsync;
-- where real durability matters the device below the handle provides it.
--
-- a namespace handle over the block device has no flush and needs none:
-- each write is a synchronous round trip through the mount to the block
-- server, so it is already at the device when write() returns. The flush
-- is for a host io handle, which buffers.
function File:sync()
  if self.f.flush then
    self.f:flush()
  end
end

function File:close()
  self.f:close()
  self.f = nil
end

return M
