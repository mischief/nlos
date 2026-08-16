-- hcitool: raw HCI, for a board with no host stack yet.
--
--	hcitool reset | ver | addr | stats
--	hcitool adv [NAME]       go on the air as NAME, default lua-os
--	hcitool noadv            stop

local unistd = require("posix.unistd")
local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local hcilib = require("ble.hci")

local function out(s)
	unistd.write(1, s)
end

local function die(s)
	unistd.write(2, "hcitool: " .. s .. "\n")
	os.exit(1)
end

local OPCODES = {
	reset = 0x0c03,
	ver = 0x1001,		-- Read Local Version Information
	addr = 0x1009,		-- Read BD_ADDR
}

local LE_SET_ADV_PARAMS = hcilib.opcode(hcilib.OGF_LE, 0x0006)
local LE_SET_ADV_DATA = hcilib.opcode(hcilib.OGF_LE, 0x0008)
local LE_SET_ADV_ENABLE = hcilib.opcode(hcilib.OGF_LE, 0x000a)

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

-- the codec is sans-io, so this is the whole of the transport: what
-- pull gives goes to the driver task, what the driver pushes is fed
-- back. The same module drives a socket in test/host_ble.lua.
local codec = hcilib.new()

local function writeout()
	local pkt = codec:pull()

	while pkt do
		local reply = sys.newport("hcitool.tx")
		local rguard <close> = sys.owned(reply)

		sys.send(hci, { op = "send", data = pkt,
		    reply = { __right = reply } })

		local ans = thread.recvtimeout(reply, 2000)

		if not ans or not ans.ok then
			die("the controller would not take the command")
		end
		pkt = codec:pull()
	end
end

local function ask(opcode, params)
	codec:command(opcode, params)
	writeout()

	local deadline = sys.uptime_ms() + 2000

	while sys.uptime_ms() < deadline do
		local m = thread.recvtimeout(port, deadline - sys.uptime_ms())

		if not m then
			break
		end
		if m.data then
			codec:feed(m.data)
		end

		local ev = codec:next()

		while ev do
			if ev.kind == "complete" and ev.opcode == opcode then
				-- a credit came back with it, so anything
				-- queued behind this can go now.
				writeout()
				return ev
			end
			ev = codec:next()
		end
	end
	die("no answer from the controller")
end

local function must(name, opcode, params)
	local ev = ask(opcode, params)

	if ev.status ~= 0 then
		die(string.format("%s: status 0x%02x", name, ev.status))
	end
	return ev
end

if what == "adv" then
	local name = arg[2] or "lua-os"

	-- off first, and the answer ignored: parameters may not be set
	-- while advertising is enabled -- the controller answers Command
	-- Disallowed -- so running this twice would fail on the second.
	ask(LE_SET_ADV_ENABLE, "\0")

	-- 100ms to 150ms, connectable undirected, public address, all
	-- three advertising channels, no filtering.
	must("adv params", LE_SET_ADV_PARAMS,
	    string.pack("<I2I2BBB", 0x00a0, 0x00f0, 0, 0, 0) ..
	    string.rep("\0", 6) .. string.char(0x07, 0x00))

	-- flags: general discoverable, no BR/EDR. Then the local name.
	-- The data field is always 31 bytes however much is significant.
	local ad = "\2\1\6" .. string.char(#name + 1, 0x09) .. name

	if #ad > 31 then
		die("name too long for one advertisement")
	end
	must("adv data", LE_SET_ADV_DATA,
	    string.char(#ad) .. ad .. string.rep("\0", 31 - #ad))
	must("adv enable", LE_SET_ADV_ENABLE, "\1")
	out("advertising as '" .. name .. "'\n")
	return
elseif what == "noadv" then
	must("adv disable", LE_SET_ADV_ENABLE, "\0")
	out("advertising stopped\n")
	return
end

local opcode = OPCODES[what] or
    die("usage: hcitool [reset|ver|addr|stats|adv|noadv]")
local ev = must(what, opcode)
local params = ev.params

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
