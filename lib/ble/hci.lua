-- HCI: the host end of the controller interface, in the H4 framing a
-- uart carries and esp32's VHCI hands over whole.
--
-- Sans-io, as lib/zmodem is: bytes in with :feed(), bytes out with
-- :pull(), decoded packets with :next(). The caller supplies the
-- transport, so a board, a socket and a string all drive this code.

local M = {}

-- H4 packet types, the first byte of every packet either way.
M.CMD, M.ACL, M.SCO, M.EVT = 0x01, 0x02, 0x03, 0x04

-- the events this layer reads itself. Everything else is handed up.
local EVT_CMD_COMPLETE = 0x0e
local EVT_CMD_STATUS = 0x0f
local EVT_NUM_COMPLETE = 0x13
local EVT_LE_META = 0x3e

-- an opcode is a 6-bit group and a 10-bit command. Spelled out because
-- every specification table gives them that way and a reader checking
-- one against the other should not have to convert.
function M.opcode(ogf, ocf)
	return ((ogf & 0x3f) << 10) | (ocf & 0x3ff)
end

-- the groups, for callers building opcodes from a table.
M.OGF_LINK_CTL = 0x01
M.OGF_HOST_CTL = 0x03
M.OGF_INFO = 0x04
M.OGF_STATUS = 0x05
M.OGF_LE = 0x08

local Hci = {}

Hci.__index = Hci

-- how many command packets the controller will take. One until it says
-- otherwise, which is what the specification requires a host to assume.
local START_CREDITS = 1

function M.new()
	return setmetatable({
		inbuf = "",
		cmdq = {},		-- commands waiting on a credit
		dataq = {},		-- acl waiting on a buffer
		events = {},		-- decoded, waiting for :next()
		credits = START_CREDITS,
		aclmax = 0,		-- controller buffers; 0 until told
		aclout = 0,		-- how many it is holding now
	}, Hci)
end

-- ---- outbound ----

-- queue a command. It leaves on a later :pull(), when the controller
-- has room -- sending without a credit is what wedges a controller
-- rather than drawing an error from it.
function Hci:command(opcode, params)
	params = params or ""
	if #params > 255 then
		error("hci: command parameters too long")
	end
	self.cmdq[#self.cmdq + 1] = string.char(M.CMD, opcode & 0xff,
	    (opcode >> 8) & 0xff, #params) .. params
	return opcode
end

-- queue ACL data on a connection. pb is the packet-boundary flag: 0 is
-- a continuation, 2 the first fragment of a higher-layer message.
function Hci:acl(handle, data, pb)
	pb = pb or 2
	self.dataq[#self.dataq + 1] = string.pack("<BI2I2",
	    M.ACL, (handle & 0x0fff) | ((pb & 0x3) << 12), #data) .. data
end

-- how many ACL buffers the controller has, from LE Read Buffer Size.
-- Until a caller says, data is not paced -- a controller that reports
-- none has none of its own to lend.
function Hci:aclbuffers(n)
	self.aclmax = n or 0
end

-- the next packet to write, or nil when nothing may go yet. Commands
-- first: a command is what makes the controller do anything, and data
-- for a connection it has not been told about goes nowhere.
function Hci:pull()
	if self.credits > 0 and #self.cmdq > 0 then
		self.credits = self.credits - 1
		return table.remove(self.cmdq, 1)
	end
	if #self.dataq > 0 and
	    (self.aclmax == 0 or self.aclout < self.aclmax) then
		self.aclout = self.aclout + 1
		return table.remove(self.dataq, 1)
	end
	return nil
end

-- whether anything is waiting to go out, which is not the same as
-- pull() answering: a queue held by credits is still work.
function Hci:pending()
	return #self.cmdq > 0 or #self.dataq > 0
end

-- ---- inbound ----

-- bytes from the transport, whole packets or any part of them. A uart
-- gives fragments, VHCI gives packets, and a socket gives whatever the
-- kernel felt like -- so length is what decides a boundary here, never
-- the size of a read.
function Hci:feed(bytes)
	self.inbuf = self.inbuf .. bytes
	self:_parse()
end

-- how long the packet starting at the front of the buffer is, or nil
-- while too little has arrived to say.
local function framelen(b)
	local t = b:byte(1)

	if t == M.EVT then
		if #b < 3 then
			return nil
		end
		return 3 + b:byte(3)
	elseif t == M.ACL then
		if #b < 5 then
			return nil
		end
		return 5 + (b:byte(4) | (b:byte(5) << 8))
	elseif t == M.SCO then
		if #b < 4 then
			return nil
		end
		return 4 + b:byte(4)
	end
	return -1		-- a type we do not know: unrecoverable
end

function Hci:_parse()
	while #self.inbuf > 0 do
		local n = framelen(self.inbuf)

		if n == -1 then
			self.events[#self.events + 1] = { kind = "desync",
			    type = self.inbuf:byte(1) }
			self.inbuf = ""
			return
		end
		if not n or #self.inbuf < n then
			return
		end

		local pkt = self.inbuf:sub(1, n)

		self.inbuf = self.inbuf:sub(n + 1)
		self:_packet(pkt)
	end
end

function Hci:_packet(pkt)
	local t = pkt:byte(1)

	if t == M.ACL then
		local hf = pkt:byte(2) | (pkt:byte(3) << 8)

		self.events[#self.events + 1] = {
			kind = "acl",
			handle = hf & 0x0fff,
			pb = (hf >> 12) & 0x3,
			bc = (hf >> 14) & 0x3,
			data = pkt:sub(6),
		}
		return
	end
	if t ~= M.EVT then
		self.events[#self.events + 1] = { kind = "other", data = pkt }
		return
	end

	local code = pkt:byte(2)
	local params = pkt:sub(4)

	if code == EVT_CMD_COMPLETE then
		-- credits, then the opcode it answers, then that command's
		-- own return parameters -- which begin with a status.
		self.credits = params:byte(1) or 0
		local opcode = params:byte(2) | (params:byte(3) << 8)
		local ret = params:sub(4)

		self.events[#self.events + 1] = { kind = "complete",
		    opcode = opcode, status = ret:byte(1), params = ret }
	elseif code == EVT_CMD_STATUS then
		self.credits = params:byte(2) or 0
		self.events[#self.events + 1] = { kind = "status",
		    opcode = params:byte(3) | (params:byte(4) << 8),
		    status = params:byte(1) }
	elseif code == EVT_NUM_COMPLETE then
		-- the controller giving buffers back: pairs of handle and
		-- count, and the count is what was freed.
		local nh = params:byte(1) or 0

		for i = 1, nh do
			local at = 2 + (i - 1) * 4
			local n = (params:byte(at + 2) or 0) |
			    ((params:byte(at + 3) or 0) << 8)

			self.aclout = self.aclout - n
			if self.aclout < 0 then
				self.aclout = 0
			end
		end
		self.events[#self.events + 1] = { kind = "complete_packets",
		    outstanding = self.aclout }
	elseif code == EVT_LE_META then
		self.events[#self.events + 1] = { kind = "le",
		    subevent = params:byte(1), params = params:sub(2) }
	else
		self.events[#self.events + 1] = { kind = "event",
		    code = code, params = params }
	end
end

-- the next decoded packet, or nil. Events are queued rather than given
-- to a callback so a caller keeps its own control flow.
function Hci:next()
	if #self.events == 0 then
		return nil
	end
	return table.remove(self.events, 1)
end

-- how many command credits the controller has given us, for a caller
-- pacing itself or a test asserting on it.
function Hci:cmdcredits()
	return self.credits
end

M.Hci = Hci

return M
