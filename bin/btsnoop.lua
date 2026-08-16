-- btsnoop: record HCI traffic for btmon and Wireshark to read.
--
--	btsnoop /config/trace.btsnoop [S] record S seconds, then write
--	btsnoop 192.168.0.10 9999         stream until interrupted
--
-- Runs beside whatever else is using the controller.

local unistd = require("posix.unistd")
local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local btsnoop = require("ble.btsnoop")

local function out(s)
	unistd.write(1, s)
end

local function die(s)
	unistd.write(2, "btsnoop: " .. s .. "\n")
	os.exit(1)
end

local hci = prog.hci() or die("no bluetooth capability here")
local where = arg[1] or die("usage: btsnoop FILE | btsnoop HOST PORT")

-- a sink is anything that takes bytes: a file through the namespace, or
-- a tcp connection. Nothing below here knows which.
local sink, closesink
local tostream = arg[2] and tonumber(arg[2]) and tonumber(arg[2]) > 1024

if tostream then
	local net = prog.net() or die("no network on this machine")
	local c, err = net:dial(where, tonumber(arg[2]))

	if not c then
		die("dial: " .. tostring(err))
	end
	sink = function(s) c:write(s) end
	closesink = function() c:close() end
else
	local N = prog.ns() or die("no namespace")
	local buf = {}

	-- collected and written whole: a namespace write is a round trip
	-- to the file server, and one per packet would pace the trace
	-- rather than record it.
	sink = function(s) buf[#buf + 1] = s end
	closesink = function()
		local okw, werr = N:writefile(where, table.concat(buf))

		if not okw then
			die("write " .. where .. ": " .. tostring(werr))
		end
	end
end

local port = sys.newport("btsnoop.evt")
local guard <close> = sys.owned(port)
local ack = sys.newport("btsnoop.ack")
local guard2 <close> = sys.owned(ack)

sys.send(hci, { op = "listen", port = { __right = port },
    reply = { __right = ack } })
if not thread.recvtimeout(ack, 2000) then
	die("the hci task would not register a listener")
end

sink(btsnoop.header())

-- a file is written whole at the end, so recording into one has to
-- stop by itself: an interrupted proc writes nothing at all.
local secs = (not tostream) and tonumber(arg[2]) or nil
local deadline = tostream and math.huge or
    (sys.uptime_ms() + (secs or 20) * 1000)

out(tostream and "streaming; interrupt to stop\n" or
    string.format("recording %d seconds\n", secs or 20))

-- only what the controller sends is seen here. A command going the
-- other way is the sender's to record, so this trace says so rather
-- than pretending to be both halves.
local n = 0

while sys.uptime_ms() < deadline do
	local m = thread.recvtimeout(port,
	    tostream and 60000 or (deadline - sys.uptime_ms()))

	if m and m.data then
		sink(btsnoop.packet(m.data, btsnoop.RECV,
		    sys.uptime_ms() * 1000))
		n = n + 1
	end
end

closesink()
out(string.format("%d packets\n", n))
