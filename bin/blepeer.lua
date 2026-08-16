-- blepeer: advertise, accept a connection, and answer ATT.
--
--	blepeer [NAME] [SECONDS]
--
-- The smallest thing that holds a link up: an MTU exchange answered,
-- everything else refused by opcode. Beyond that is gatt.

local unistd = require("posix.unistd")
local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local hcilib = require("ble.hci")
local l2cap = require("ble.l2cap")
local att = require("ble.att")

local function out(s)
	unistd.write(1, s)
end

local function die(s)
	unistd.write(2, "blepeer: " .. s .. "\n")
	os.exit(1)
end

local hci = prog.hci() or die("no bluetooth capability here")
local name = arg[1] or "lua-os"
local secs = tonumber(arg[2]) or 60

local LE_SET_ADV_PARAMS = hcilib.opcode(hcilib.OGF_LE, 0x0006)
local LE_SET_ADV_DATA = hcilib.opcode(hcilib.OGF_LE, 0x0008)
local LE_SET_ADV_ENABLE = hcilib.opcode(hcilib.OGF_LE, 0x000a)
local LE_READ_BUFFER_SIZE = hcilib.opcode(hcilib.OGF_LE, 0x0002)

-- LE meta subevents this answers to.
local SUB_CONN_COMPLETE = 0x01
local EVT_DISCONN = 0x05

local port = sys.newport("blepeer.evt")
local guard <close> = sys.owned(port)
local ack = sys.newport("blepeer.ack")
local guard2 <close> = sys.owned(ack)

sys.send(hci, { op = "listen", port = { __right = port },
    reply = { __right = ack } })
if not thread.recvtimeout(ack, 2000) then
	die("the hci task would not register a listener")
end

local codec = hcilib.new()
local chans = l2cap.new(27)
local mtu = att.DEFAULT_MTU

local function writeout()
	local pkt = codec:pull()

	while pkt do
		local reply = sys.newport("blepeer.tx")
		local rguard <close> = sys.owned(reply)

		sys.send(hci, { op = "send", data = pkt,
		    reply = { __right = reply } })
		if not thread.recvtimeout(reply, 2000) then
			die("the controller would not take a packet")
		end
		pkt = codec:pull()
	end
end

-- an ATT PDU back to the peer, through l2cap and the controller.
local function reply(handle, pdu)
	for _, f in ipairs(chans:frame(handle, l2cap.CID_ATT, pdu)) do
		codec:acl(f.handle, f.data, f.pb)
	end
	writeout()
end

-- what a peer asks, and what this can say about it. Anything beyond an
-- MTU exchange is refused by opcode rather than ignored: a client that
-- is told no moves on, and one that is ignored waits out its timeout.
local function onatt(handle, pdu)
	local m, why = att.decode(pdu)

	if not m then
		out("att: " .. tostring(why) .. "\n")
		return
	end

	if m.op == att.OP_MTU_REQ then
		-- ours is what the controller can carry, and the one in
		-- use is the smaller of the two.
		local mine = 185

		mtu = math.min(m.mtu, mine)
		out(string.format("mtu: peer %d, ours %d, using %d\n",
		    m.mtu, mine, mtu))
		reply(handle, att.mtursp(mine))
	elseif m.op == att.OP_WRITE_CMD then
		out(string.format("write command to 0x%04x: %q\n",
		    m.handle, m.value))
	else
		out(string.format("att op 0x%02x: not supported yet\n", m.op))
		reply(handle, att.error(m.op, m.handle or 0,
		    att.ERR_REQ_NOT_SUPPORTED))
	end
end

local function ask(opcode, params)
	codec:command(opcode, params)
	writeout()

	local deadline = sys.uptime_ms() + 2000

	while sys.uptime_ms() < deadline do
		local m = thread.recvtimeout(port, deadline - sys.uptime_ms())

		if m and m.data then
			codec:feed(m.data)
		end

		local ev = codec:next()

		while ev do
			if ev.kind == "complete" and ev.opcode == opcode then
				writeout()
				return ev
			end
			ev = codec:next()
		end
	end
	die("no answer from the controller")
end

-- the controller's ACL buffers, so nothing is sent in a fragment it
-- cannot hold or faster than it can drain.
local bufs = ask(LE_READ_BUFFER_SIZE)

if bufs.status == 0 and #bufs.params >= 4 then
	local aclmtu, count = string.unpack("<I2B", bufs.params:sub(2))

	if aclmtu > 0 then
		chans:aclmtu(aclmtu)
		codec:aclbuffers(count)
		out(string.format("acl: %d bytes, %d buffers\n", aclmtu, count))
	end
end

ask(LE_SET_ADV_ENABLE, "\0")
ask(LE_SET_ADV_PARAMS, string.pack("<I2I2BBB", 0x00a0, 0x00f0, 0, 0, 0) ..
    string.rep("\0", 6) .. string.char(0x07, 0x00))

local ad = "\2\1\6" .. string.char(#name + 1, 0x09) .. name

ask(LE_SET_ADV_DATA, string.char(#ad) .. ad .. string.rep("\0", 31 - #ad))
ask(LE_SET_ADV_ENABLE, "\1")

out(string.format("advertising as '%s' for %ds\n", name, secs))

local deadline = sys.uptime_ms() + secs * 1000

while sys.uptime_ms() < deadline do
	local m = thread.recvtimeout(port,
	    math.min(1000, deadline - sys.uptime_ms()))

	if m and m.data then
		codec:feed(m.data)
	end

	local ev = codec:next()

	while ev do
		if ev.kind == "acl" then
			local h, cid, payload = chans:acl(ev.handle, ev.pb,
			    ev.data)

			if h and cid == l2cap.CID_ATT then
				onatt(h, payload)
			elseif h then
				out(string.format("l2cap cid 0x%04x: %d bytes\n",
				    cid, #payload))
			end
		elseif ev.kind == "le" and ev.subevent == SUB_CONN_COMPLETE then
			local st, ch = string.unpack("<BI2", ev.params)

			out(string.format("connected: handle %d, status %d\n",
			    ch, st))
		elseif ev.kind == "event" and ev.code == EVT_DISCONN then
			local _, ch = string.unpack("<BI2", ev.params)

			chans:closed(ch)
			out(string.format("disconnected: handle %d\n", ch))
		end
		ev = codec:next()
	end
end

ask(LE_SET_ADV_ENABLE, "\0")
out("done\n")
