-- blegatt: connect to a peer and walk its attribute database.
--
--	blegatt AA:BB:CC:DD:EE:FF [-r]   -r for a random address
--
-- The central half: connect outward, exchange an MTU, then discover
-- services, characteristics and descriptors the way any client does.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local hcilib = require("ble.hci")
local l2cap = require("ble.l2cap")
local att = require("ble.att")
local gattc = require("ble.gattc")
local gap = require("ble.gap")
local uuid = require("ble.uuid")

local function out(s)
	io.write(s)
end

local function die(s)
	io.stderr:write("blegatt: " .. s .. "\n")
	os.exit(1)
end

local hci = prog.hci() or die("no bluetooth capability here")
local addr = gap.parseaddr(arg[1] or "") or
    die("usage: blegatt AA:BB:CC:DD:EE:FF [-r]")
local random = arg[2] == "-r"

local port = sys.newport("blegatt.evt")
local guard <close> = sys.owned(port)
local ack = sys.newport("blegatt.ack")
local guard2 <close> = sys.owned(ack)

sys.send(hci, { op = "listen", port = { __right = port },
    reply = { __right = ack } })
if not thread.recvtimeout(ack, 2000) then
	die("the hci task would not register a listener")
end

local codec = hcilib.new()
local chans = l2cap.new(27)
local conn, mtu = nil, att.DEFAULT_MTU
local pending = {}		-- att responses, in arrival order

local function writeout()
	local pkt = codec:pull()

	while pkt do
		local reply = sys.newport("blegatt.tx")
		local rguard <close> = sys.owned(reply)

		sys.send(hci, { op = "send", data = pkt,
		    reply = { __right = reply } })
		if not thread.recvtimeout(reply, 2000) then
			die("the controller would not take a packet")
		end
		pkt = codec:pull()
	end
end

-- One reader of the event queue, and everything it finds is filed
-- where its waiter will look. Two consumers would race: whichever
-- drained first would throw away what the other was waiting for.
local answers = {}		-- opcode -> the event that answered it
local tosend = {}		-- att pdus this owes the peer

-- The peer is a client too and sends requests of its own, so only a
-- response answers what we asked. A request of theirs is answered
-- here, because ignoring one stalls them until their timeout.
function onatt(handle, pdu)
	local kind = att.kind(pdu:byte(1) or 0)

	if kind == "response" then
		pending[#pending + 1] = pdu
	elseif kind == "request" then
		local m = att.decode(pdu)

		if m and m.op == att.OP_MTU_REQ then
			out(string.format("peer asked for mtu %d\n", m.mtu))
			tosend[#tosend + 1] = att.mtursp(185)
		else
			tosend[#tosend + 1] = att.error(m and m.op or 0,
			    m and m.handle or 0, att.ERR_REQ_NOT_SUPPORTED)
		end
	elseif kind == "notify" or kind == "indicate" then
		local h2, v = gattc.update(pdu)

		out(string.format("notify from handle %d: %d bytes\n",
		    h2 or 0, #(v or "")))
		if kind == "indicate" then
			tosend[#tosend + 1] = att.confirm()
		end
	end
end

local function drain()
	local ev = codec:next()

	while ev do
		if ev.kind == "acl" then
			local h, cid, payload = chans:acl(ev.handle, ev.pb,
			    ev.data)

			if h and cid == l2cap.CID_ATT then
				onatt(h, payload)
			end
		elseif ev.kind == "complete" or ev.kind == "status" then
			answers[ev.opcode] = ev
		elseif ev.kind == "le" and
		    (ev.subevent == gap.SUB_CONN_COMPLETE or
		     ev.subevent == gap.SUB_ENHANCED_CONN_COMPLETE) then
			-- both forms begin with the same eleven bytes; the
			-- enhanced one only adds addresses after them.
			conn = gap.connreport(ev.params)
		elseif ev.kind == "event" and
		    ev.code == gap.EVT_DISCONN_COMPLETE then
			-- status, handle, reason. 0x13 is the peer choosing
			-- to end it, 0x08 a supervision timeout, 0x3e a
			-- connection that never really established.
			local _, ch, why = string.unpack("<BI2B", ev.params)

			out(string.format("disconnected: handle %d, reason 0x%02x\n",
			    ch, why))
			conn = nil
		elseif ev.kind == "le" then
			out(string.format("le subevent 0x%02x, %d bytes\n",
			    ev.subevent, #ev.params))
		elseif ev.kind == "event" then
			out(string.format("event 0x%02x, %d bytes\n",
			    ev.code, #ev.params))
		end
		ev = codec:next()
	end
end

local function sendatt(pdu)
	for _, f in ipairs(chans:frame(conn.handle, l2cap.CID_ATT, pdu)) do
		codec:acl(f.handle, f.data, f.pb)
	end
	writeout()
end

local function pump(ms)
	local m = thread.recvtimeout(port, ms)

	if m and m.data then
		codec:feed(m.data)
	end
	drain()

	-- what the peer is owed goes out here rather than from inside the
	-- reader, so nothing is sent while a packet is half decoded.
	while conn and #tosend > 0 do
		sendatt(table.remove(tosend, 1))
	end
end

local function command(opcode, params, ms)
	answers[opcode] = nil
	codec:command(opcode, params)
	writeout()

	local deadline = sys.uptime_ms() + (ms or 3000)

	while sys.uptime_ms() < deadline do
		pump(math.min(200, deadline - sys.uptime_ms()))

		local ev = answers[opcode]

		if ev then
			answers[opcode] = nil
			-- a credit came back with it, so anything queued
			-- behind this may go now.
			writeout()
			return ev
		end
	end
	return nil
end

-- one ATT request and the response to it. ATT is one outstanding
-- request per connection, so waiting for the next arrival is right.
local function transact(pdu, ms)
	if not conn then
		return nil, "not connected"
	end

	-- ATT carries no request id: one request is outstanding at a time
	-- and the answer is whatever comes back next. So a reply to a
	-- request that already timed out has to be dropped here, or the
	-- next request will take it for its own.
	if #pending > 0 then
		out(string.format("dropping %d late response(s)\n", #pending))
		pending = {}
	end

	for _, f in ipairs(chans:frame(conn.handle, l2cap.CID_ATT, pdu)) do
		codec:acl(f.handle, f.data, f.pb)
	end
	writeout()

	local deadline = sys.uptime_ms() + (ms or 12000)

	while sys.uptime_ms() < deadline do
		if #pending > 0 then
			return table.remove(pending, 1)
		end
		if not conn then
			return nil, "the peer disconnected"
		end
		pump(math.min(200, deadline - sys.uptime_ms()))
	end
	return nil, "no answer"
end

local bufs = command(gap.READ_BUFFER_SIZE)

if bufs and bufs.status == 0 and #bufs.params >= 4 then
	local aclmtu, count = string.unpack("<I2B", bufs.params:sub(2))

	if aclmtu > 0 then
		chans:aclmtu(aclmtu)
		codec:aclbuffers(count)
	end
end

out("connecting to " .. gap.addrstr(addr) .. "\n")

-- Create Connection answers with Command Status and completes later,
-- unlike every command so far: the controller has to find the peer
-- first, and that takes as long as the peer's advertising interval.
local st = command(gap.connect(addr, { addr_type = random and
    gap.ADDR_RANDOM or gap.ADDR_PUBLIC, timeout_ms = 8000 }))

if not st or st.status ~= 0 then
	die(string.format("create connection: %s", st and
	    string.format("status 0x%02x", st.status) or
	    "the controller never answered the command"))
end
out(string.format("create connection accepted (%s)\n", st.kind))

local deadline = sys.uptime_ms() + 10000

while not conn and sys.uptime_ms() < deadline do
	pump(200)
end

if not conn then
	command(gap.CREATE_CONN_CANCEL)
	die("the peer never answered")
end
if conn.status ~= 0 then
	die(string.format("connection failed: status 0x%02x", conn.status))
end

out(string.format("connected: handle %d, role %s, interval %gms, timeout %gms\n",
    conn.handle, conn.role == 0 and "central" or "peripheral",
    conn.interval_ms, conn.timeout_ms))

-- ask for a bigger mtu before discovery, since every response after
-- this is bounded by it.
local mrsp = transact(att.mtureq(185))

if mrsp then
	local m = att.decode(mrsp)

	if m and m.op == att.OP_MTU_RSP then
		mtu = math.min(185, m.mtu)
		out(string.format("mtu %d\n", mtu))
	end
end

local walk = gattc.walk()
local turns = 0

while not walk:done() and turns < 64 do
	local req = walk:next()

	if not req then
		break
	end

	local rsp, err = transact(req)

	if not rsp then
		die(tostring(err))
	end

	local okw, werr = walk:feed(rsp)

	if not okw then
		die("discovery: " .. tostring(werr))
	end
	turns = turns + 1
end

out(string.format("\n%d services in %d round trips\n", #walk.services, turns))
for _, s in ipairs(walk.services) do
	out(string.format("service %s  handles %d-%d\n", uuid.tostring(s.uuid),
	    s.start, s.last))
	for _, c in ipairs(s.chars) do
		local props = {}

		if c.props & 0x02 ~= 0 then props[#props + 1] = "read" end
		if c.props & 0x04 ~= 0 then props[#props + 1] = "write-nr" end
		if c.props & 0x08 ~= 0 then props[#props + 1] = "write" end
		if c.props & 0x10 ~= 0 then props[#props + 1] = "notify" end
		if c.props & 0x20 ~= 0 then props[#props + 1] = "indicate" end
		out(string.format("  char %s  handle %d  %s%s\n",
		    uuid.tostring(c.uuid), c.value,
		    table.concat(props, ","),
		    c.cccd and ("  cccd " .. c.cccd) or ""))
	end
end

command(gap.disconnect(conn.handle))
out("disconnected\n")
