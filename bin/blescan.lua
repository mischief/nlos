-- blescan: list what is advertising nearby.
--
--	blescan [SECONDS]        passive, 10 seconds by default
--	blescan -a [SECONDS]     active: ask each advertiser for more
--
-- The controller filters no duplicates, so a peer is counted not listed twice.

local unistd = require("posix.unistd")
local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local hcilib = require("ble.hci")
local gap = require("ble.gap")
local ad = require("ble.ad")
local uuid = require("ble.uuid")

local function out(s)
	unistd.write(1, s)
end

local function die(s)
	unistd.write(2, "blescan: " .. s .. "\n")
	os.exit(1)
end

local hci = prog.hci() or die("no bluetooth capability here")
local active = arg[1] == "-a"
local secs = tonumber(active and arg[2] or arg[1]) or 10

local port = sys.newport("blescan.evt")
local guard <close> = sys.owned(port)
local ack = sys.newport("blescan.ack")
local guard2 <close> = sys.owned(ack)

sys.send(hci, { op = "listen", port = { __right = port },
    reply = { __right = ack } })
if not thread.recvtimeout(ack, 2000) then
	die("the hci task would not register a listener")
end

local codec = hcilib.new()

local function writeout()
	local pkt = codec:pull()

	while pkt do
		local reply = sys.newport("blescan.tx")
		local rguard <close> = sys.owned(reply)

		sys.send(hci, { op = "send", data = pkt,
		    reply = { __right = reply } })
		if not thread.recvtimeout(reply, 2000) then
			die("the controller would not take a command")
		end
		pkt = codec:pull()
	end
end

-- a command and the event that answers it. Reports arriving in the
-- middle are handled here rather than dropped: a scan is already
-- running by the time it is switched off.
local seen = {}
local order = {}

local function note(r)
	local key = gap.addrstr(r.addr)
	local f = ad.parse(r.data)
	local e = seen[key]

	if not e then
		e = { addr = key, n = 0 }
		seen[key] = e
		order[#order + 1] = e
	end
	e.n = e.n + 1
	e.rssi = r.rssi
	e.name = f.name or e.name
	e.connectable = r.evtype == gap.ADV_IND or
	    r.evtype == gap.ADV_DIRECT_IND or e.connectable
	if #f.uuids > 0 then
		e.uuids = f.uuids
	end
	if not e.said and e.name then
		e.said = true
		out(string.format("%s  %4d dBm  %s\n", e.addr, e.rssi or 0,
		    e.name))
	end
end

local function drain()
	local ev = codec:next()

	while ev do
		if ev.kind == "le" and ev.subevent == gap.SUB_ADV_REPORT then
			for _, r in ipairs(gap.advreports(ev.params)) do
				note(r)
			end
		end
		ev = codec:next()
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
			elseif ev.kind == "le" and
			    ev.subevent == gap.SUB_ADV_REPORT then
				for _, r in ipairs(gap.advreports(ev.params)) do
					note(r)
				end
			end
			ev = codec:next()
		end
	end
	die("no answer from the controller")
end

-- parameters may not change while a scan is running, so it goes off
-- first and the answer is ignored.
ask(gap.scanenable(false, false))

local st = ask(gap.scanparams({ active = active, interval_ms = 60,
    window_ms = 30 }))

if st.status ~= 0 then
	die(string.format("scan parameters: status 0x%02x", st.status))
end

st = ask(gap.scanenable(true, false))
if st.status ~= 0 then
	die(string.format("scan enable: status 0x%02x", st.status))
end

out(string.format("scanning %s for %ds\n", active and "actively" or
    "passively", secs))

local deadline = sys.uptime_ms() + secs * 1000

while sys.uptime_ms() < deadline do
	local m = thread.recvtimeout(port,
	    math.min(500, deadline - sys.uptime_ms()))

	if m and m.data then
		codec:feed(m.data)
	end
	drain()
end

ask(gap.scanenable(false, false))

-- the ones that never named themselves, which is most of them: a
-- phone advertising for a nearby-device protocol says nothing else.
out(string.format("\n%d seen\n", #order))
for _, e in ipairs(order) do
	local what = e.name or "(no name)"

	if e.uuids and #e.uuids > 0 then
		what = what .. "  " .. uuid.tostring(e.uuids[1])
	end
	out(string.format("%s  %4d dBm  %3d  %s%s\n", e.addr, e.rssi or 0,
	    e.n, e.connectable and "" or "(broadcast) ", what))
end
