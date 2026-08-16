-- ble: talk to blesrv, which owns the controller.
--
--	ble status | noadv
--	ble scan [SECONDS] [-a]   watch advertisements
--	ble adv NAME              advertise, and serve a chat service
--	ble connect ADDR [-r]     open a link, and hold it

local unistd = require("posix.unistd")
local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local uuid = require("ble.uuid")
local gap = require("ble.gap")

local function out(s)
	unistd.write(1, s)
end

local function die(s)
	unistd.write(2, "ble: " .. s .. "\n")
	os.exit(1)
end

local srv = prog.ble() or die("no bluetooth service here")

-- ask blesrv something and wait for its answer.
local function ask(msg, ms)
	local reply = sys.newport("ble.reply")
	local guard <close> = sys.owned(reply)

	msg.reply = { __right = reply }
	sys.send(srv, msg)

	local m = thread.recvtimeout(reply, ms or 5000)

	if not m then
		die("blesrv did not answer " .. tostring(msg.op))
	end
	if m.err then
		die(m.err)
	end
	return m
end

local what = arg[1] or "status"

if what == "status" then
	local s = ask({ op = "status" })

	out(string.format("advertising %s  scanning %s  %d/%d activities\n",
	    tostring(s.advertising), tostring(s.scanning), s.activities,
	    s.max))
	for _, l in ipairs(s.links or {}) do
		out(string.format("link %d  %s  %s  mtu %d\n", l.handle,
		    l.addr, l.role == 0 and "central" or "peripheral", l.mtu))
	end
	return
end

if what == "noadv" then
	ask({ op = "advertise", on = false })
	out("advertising stopped\n")
	return
end

-- everything below wants to hear events, so a port comes first.
local port = sys.newport("ble.events")
local guard <close> = sys.owned(port)

ask({ op = "watch", port = { __right = port }, want = "all" })

if what == "scan" then
	local secs = tonumber(arg[2]) or 10

	ask({ op = "scan", on = true, active = arg[3] == "-a" })
	out(string.format("scanning for %ds\n", secs))

	local seen = {}
	local deadline = sys.uptime_ms() + secs * 1000

	while sys.uptime_ms() < deadline do
		local m = thread.recvtimeout(port,
		    math.min(500, deadline - sys.uptime_ms()))

		if m and m.kind == "adv" and not seen[m.addr] then
			seen[m.addr] = true
			out(string.format("%s  %4d dBm  %s%s\n", m.addr,
			    m.rssi or 0, m.name or "(no name)",
			    m.uuids and m.uuids[1] and
			    ("  " .. uuid.tostring(m.uuids[1])) or ""))
		end
	end
	ask({ op = "scan", on = false })
	return
end

if what == "adv" then
	local name = arg[2] or "lua-os"

	-- the shape a chat wants: something to write at, something that
	-- notifies back. Registered before advertising, so a peer that
	-- connects immediately finds a database rather than an empty one.
	local h = ask({ op = "serve", port = { __right = port },
	    service = uuid.parse("F47B5E2D-1234-5678-9abc-def012345678"),
	    chars = {
		{ uuid = uuid.parse("F47B5E2E-1234-5678-9abc-def012345678"),
		  props = 0x04 | 0x08 },		-- write
		{ uuid = uuid.parse("F47B5E2F-1234-5678-9abc-def012345678"),
		  props = 0x10 },			-- notify
	    } })

	out(string.format("service at handles %d-%d, write %d, notify %d\n",
	    h.handles.start, h.handles.last, h.handles.chars[1].value,
	    h.handles.chars[2].value))

	ask({ op = "advertise", on = true, name = name })
	out("advertising as '" .. name .. "'; interrupt to stop\n")

	while true do
		local m = thread.recvtimeout(port, 2000)

		if m and m.kind == "link" then
			out(string.format("%s: handle %d %s\n",
			    m.up and "connected" or "disconnected", m.handle,
			    m.addr or ""))
		elseif m and m.kind == "write" then
			out(string.format("write to %d: %q\n", m.attr,
			    m.value or ""))
		end
	end
end

if what == "connect" then
	local addr = arg[2] or die("usage: ble connect ADDR [-r]")
	local c = ask({ op = "connect", addr = addr,
	    random = arg[3] == "-r" }, 15000)

	out(string.format("connected, handle %d\n", c.handle))

	while true do
		local m = thread.recvtimeout(port, 2000)

		if m and m.kind == "link" and not m.up then
			out(string.format("disconnected: reason 0x%02x\n",
			    m.reason or 0))
			return
		elseif m and m.kind == "notify" then
			out(string.format("notify from %d: %d bytes\n",
			    m.attr or 0, #(m.value or "")))
		end
	end
end

die("usage: ble [status|scan|adv|noadv|connect]")
