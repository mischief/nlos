-- A device that is a byte window of another device.
--
-- gefs otherwise owns the whole device from offset zero. On a partitioned
-- disk it owns a partition instead -- a [start, start+len) range of the
-- disk -- so this shifts every offset by start and reports len as the
-- size. lib/gpt.lua finds the start and len; this makes gefs sit on them
-- knowing nothing about partition tables, the same way gefs.io knows
-- nothing about virtio.
--
-- The window is enforced, not merely offset: a read or write past len is
-- a bug in the layer above (gefs never addresses outside its own volume),
-- and catching it here turns a silent stomp on a neighbouring partition
-- into an error at the seam.

local M = {}

local Slice = {}
Slice.__index = Slice

function M.new(dev, off, len)
	assert(off >= 0 and len >= 0, "slice bounds are non-negative")
	assert(off + len <= dev:size(), "slice runs past the device")
	return setmetatable({ dev = dev, off = off, len = len }, Slice)
end

function Slice:size()
	return self.len
end

function Slice:read(o, n)
	assert(o >= 0 and o + n <= self.len, "read outside the slice")
	return self.dev:read(self.off + o, n)
end

function Slice:write(o, s)
	assert(o >= 0 and o + #s <= self.len, "write outside the slice")
	self.dev:write(self.off + o, s)
end

function Slice:sync()
	if self.dev.sync then self.dev:sync() end
end

function Slice:close()
	if self.dev.close then self.dev:close() end
end

return M
