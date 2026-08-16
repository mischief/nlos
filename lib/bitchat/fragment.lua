-- A packet too big for a link, split and put together again.
--
-- Sans-io like the relay beside it. What is cut up is the whole encoded
-- packet, signature and all, so what comes out is the packet that was
-- sent rather than a reconstruction of it.

local M = {}

-- id(8) index(2) total(2) type(1), then the slice.
M.HEADER = 13

-- what a receiver will hold. 256 parts is the ceiling other clients
-- were built against; the slots and the window bound what a peer that
-- never finishes a set can make us keep.
M.MAXPARTS = 256
M.SLOTS = 4
M.MAXAGE = 30

-- the packet header, both ids and the fragment header. What is left of
-- a link's frame after this is what one fragment may carry.
M.OVERHEAD = 48

function M.cut(mtu)
	return math.max(64, mtu - M.OVERHEAD)
end

-- split(frame, ptype, cut, id) -> a list of fragment payloads, or nil
-- where it would take more parts than a receiver will hold. `frame` is
-- an encoded packet and `id` is eight bytes naming this set.
function M.split(frame, ptype, cut, id)
	local total = math.max(1, math.ceil(#frame / cut))

	if total > M.MAXPARTS then
		return nil, "too many fragments"
	end

	local out = {}

	for i = 0, total - 1 do
		local chunk = frame:sub(i * cut + 1, (i + 1) * cut)

		out[#out + 1] = id .. string.pack(">I2I2B", i, total, ptype) ..
		    chunk
	end
	return out
end

local Asm = {}

Asm.__index = Asm

function M.new(o)
	return setmetatable({
		now = (o and o.now) or function() return 0 end,
		sets = {},
	}, Asm)
end

-- feed(sender, payload) -> the assembled frame once the last part
-- arrives, or nil. `sender` is the eight bytes the fragment came from:
-- two peers may be sending sets at once and an id is only theirs.
function Asm:feed(sender, payload)
	if #payload < M.HEADER then
		return nil, "short fragment"
	end

	local id = payload:sub(1, 8)
	local index, total, ptype = string.unpack(">I2I2B", payload, 9)

	if total == 0 or index >= total or total > M.MAXPARTS then
		return nil, "fragment out of range"
	end

	local at = self.now()
	local key = sender .. id

	-- a set nobody finished is not kept forever, and the oldest goes
	-- when there is no room: a peer that stops halfway must not be
	-- able to fill this.
	for k, s in pairs(self.sets) do
		if at - s.started > M.MAXAGE then
			self.sets[k] = nil
		end
	end

	local set = self.sets[key]

	if not set then
		local n = 0
		local oldest, oldkey

		for k, s in pairs(self.sets) do
			n = n + 1
			if not oldest or s.started < oldest.started then
				oldest, oldkey = s, k
			end
		end
		if n >= M.SLOTS then
			self.sets[oldkey] = nil
		end
		set = { parts = {}, got = 0, total = total, ptype = ptype,
		    started = at }
		self.sets[key] = set
	end

	-- the same part twice is the mesh doing its job, not an error.
	if set.parts[index] then
		return nil
	end
	set.parts[index] = payload:sub(M.HEADER + 1)
	set.got = set.got + 1
	if set.got < set.total then
		return nil
	end

	self.sets[key] = nil
	return table.concat(set.parts, "", 0, set.total - 1), set.ptype
end

M.Asm = Asm

return M
