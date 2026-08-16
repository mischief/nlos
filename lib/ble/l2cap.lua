-- L2CAP over LE: fixed channels, reassembly and fragmentation.
--
-- LE has no dynamic channels until credit-based ones, so this is a
-- demultiplexer and a pair of length games. Sans-io: ACL packets in,
-- complete frames out, and the fragments to send back.

local M = {}

-- the fixed channels LE defines. ATT is the one a gatt client speaks.
M.CID_ATT = 0x0004
M.CID_SIG = 0x0005
M.CID_SMP = 0x0006

-- ACL packet-boundary flags. A message begins with FIRST and every
-- fragment after it says CONT, which is the only way to tell a new
-- message from the middle of one.
M.PB_CONT = 0x01
M.PB_FIRST = 0x02

local L2cap = {}

L2cap.__index = L2cap

-- `mtu` is the controller's ACL data length, from LE Read Buffer Size.
-- Nothing may be sent in a bigger fragment than the controller holds.
function M.new(mtu)
	return setmetatable({
		mtu = mtu or 27,
		partial = {},		-- per connection handle
	}, L2cap)
end

function L2cap:aclmtu(n)
	if n and n > 0 then
		self.mtu = n
	end
end

-- an ACL packet in. Returns a frame as handle, cid, payload once one is
-- whole, or nil while it is not. A frame arriving in one packet and a
-- frame arriving in five are the same to a caller.
function L2cap:acl(handle, pb, data)
	if pb == M.PB_FIRST then
		-- a new message replaces whatever was half-read: the peer
		-- has moved on, and keeping the old bytes would splice two
		-- messages into one.
		self.partial[handle] = data
	elseif pb == M.PB_CONT then
		local held = self.partial[handle]

		if not held then
			return nil, "continuation with nothing to continue"
		end
		self.partial[handle] = held .. data
	else
		return nil, "unexpected packet boundary flag"
	end

	local buf = self.partial[handle]

	-- the header is two lengths of its own, so it may itself be split.
	if #buf < 4 then
		return nil
	end

	local plen, cid = string.unpack("<I2I2", buf)

	if #buf < 4 + plen then
		return nil
	end

	-- exactly one frame per message: a fragment carries no more than
	-- what its header claims, and the rest would be a new message.
	self.partial[handle] = nil
	return handle, cid, buf:sub(5, 4 + plen)
end

-- a frame out, as the list of ACL fragments that carry it. The first
-- says FIRST and the rest say CONT, which is what lets the far side
-- put them back together.
function L2cap:frame(handle, cid, payload)
	local buf = string.pack("<I2I2", #payload, cid) .. payload
	local out = {}
	local pb = M.PB_FIRST
	local at = 1

	while at <= #buf do
		local part = buf:sub(at, at + self.mtu - 1)

		out[#out + 1] = { handle = handle, pb = pb, data = part }
		at = at + #part
		pb = M.PB_CONT
	end
	return out
end

-- forget a connection's half-read message. A handle is reused after a
-- disconnect, and the next owner must not inherit those bytes.
function L2cap:closed(handle)
	self.partial[handle] = nil
end

M.L2cap = L2cap

return M
