-- hcitool: raw HCI, for a board with no host stack yet.
--
--	hcitool reset            HCI_Reset, and the event it answers with
--	hcitool ver              the controller's version and manufacturer
--	hcitool addr             its public address
--	hcitool stats            packets, drops, and the SRAM it cost

local unistd = require("posix.unistd")
local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")

local function out(s)
	unistd.write(1, s)
end

local function die(s)
	unistd.write(2, "hcitool: " .. s .. "\n")
	os.exit(1)
end

-- H4 packet types, as the transport prefixes them.
local CMD = 0x01
local EVT = 0x04

-- the events a command can come back as.
local EVT_CMD_COMPLETE = 0x0e
local EVT_CMD_STATUS = 0x0f

local OPCODES = {
	reset = 0x0c03,
	ver = 0x1001,		-- Read Local Version Information
	addr = 0x1009,		-- Read BD_ADDR
}

-- a command packet: type, opcode little-endian, parameter length, and
-- the parameters. No command here takes any.
local function command(op, params)
	params = params or ""
	return string.char(CMD, op & 0xff, (op >> 8) & 0xff, #params) ..
	    params
end

-- Command Complete carries the opcode it answers, so a reply is matched
-- rather than assumed: an unsolicited event can arrive between a
-- command and its answer, and taking the first packet would read one.
local function match(pkt, op)
	if #pkt < 4 or pkt:byte(1) ~= EVT then
		return nil
	end

	local code = pkt:byte(2)

	if code == EVT_CMD_COMPLETE then
		if #pkt < 6 then
			return nil
		end
		local said = pkt:byte(5) | (pkt:byte(6) << 8)

		if said == op then
			return pkt:sub(7)
		end
	elseif code == EVT_CMD_STATUS then
		if #pkt < 7 then
			return nil
		end
		local said = pkt:byte(6) | (pkt:byte(7) << 8)

		if said == op then
			return pkt:sub(4, 4)
		end
	end
	return nil
end

local function hexbytes(s)
	local o = {}

	for i = 1, #s do
		o[i] = string.format("%02x", s:byte(i))
	end
	return table.concat(o, " ")
end

local hci = prog.hci() or die("no bluetooth capability here")
local what = arg[1] or "reset"

if what == "stats" then
	local reply = sys.newport("hcitool.reply")
	local guard <close> = sys.owned(reply)

	sys.send(hci, { op = "stats", reply = { __right = reply } })

	local m = thread.recvtimeout(reply, 2000)

	if not m then
		die("the hci task did not answer")
	end
	out(string.format("packets %d  drops %d  sram %d bytes\n",
	    m.packets or 0, m.drops or 0, m.sram or 0))
	return
end

local op = OPCODES[what] or die("usage: hcitool [reset|ver|addr|stats]")

-- listen before commanding: the answer is an event pushed to a port,
-- and one asked for after the fact has already gone.
local port = sys.newport("hcitool.evt")
local guard <close> = sys.owned(port)
local ack = sys.newport("hcitool.ack")
local guard2 <close> = sys.owned(ack)

sys.send(hci, { op = "listen", port = { __right = port },
    reply = { __right = ack } })
if not thread.recvtimeout(ack, 2000) then
	die("the hci task would not register a listener")
end

local reply = sys.newport("hcitool.reply")
local guard3 <close> = sys.owned(reply)

sys.send(hci, { op = "send", data = command(op),
    reply = { __right = reply } })

local ans = thread.recvtimeout(reply, 2000)

if not ans or not ans.ok then
	die("the controller would not take the command")
end

local deadline = sys.uptime_ms() + 2000
local params

while sys.uptime_ms() < deadline do
	local m = thread.recvtimeout(port, deadline - sys.uptime_ms())

	if not m then
		break
	end
	if m.data then
		params = match(m.data, op)
		if params then
			break
		end
	end
end

if not params then
	die("no answer from the controller")
end

local status = params:byte(1)

if status ~= 0 then
	die(string.format("%s: controller said status 0x%02x", what, status))
end

if what == "reset" then
	out("reset: ok\n")
elseif what == "addr" then
	-- little-endian on the wire, printed high byte first the way every
	-- other tool shows an address.
	local a = params:sub(2, 7)
	local octets = {}

	for i = 6, 1, -1 do
		octets[#octets + 1] = string.format("%02x", a:byte(i))
	end
	out("addr " .. table.concat(octets, ":") .. "\n")
elseif what == "ver" then
	-- status, hci version, hci revision, lmp version, manufacturer,
	-- lmp subversion -- the two revisions are 16-bit, which is what
	-- makes the single-byte versions easy to read one field late.
	out(string.format("hci %d rev %d  lmp %d sub %d  manufacturer %d\n",
	    params:byte(2), params:byte(3) | (params:byte(4) << 8),
	    params:byte(5), params:byte(8) | (params:byte(9) << 8),
	    params:byte(6) | (params:byte(7) << 8)))
end
