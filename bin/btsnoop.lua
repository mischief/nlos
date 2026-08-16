-- btsnoop: record HCI traffic for btmon and Wireshark to read.
--
--	btsnoop /config/trace.btsnoop [S] record, S seconds or until stopped
--	btsnoop 192.168.0.10 9999         stream to a listener instead
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
local sink, closesink, flush
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
	local c, cerr = N:create(where, "w")

	if not c then
		c, cerr = N:open(where, "w")
	end
	if not c then
		die("create " .. where .. ": " .. tostring(cerr))
	end

	-- buffered, then flushed: a write is a round trip to the file
	-- server and one per packet would pace the trace rather than
	-- record it. Flushed on a bound and whenever the line goes quiet,
	-- so what an interrupt can lose is a partial window and never the
	-- whole recording.
	local buf, held = {}, 0

	flush = function()
		if held == 0 then
			return
		end
		local w, werr = c:write(table.concat(buf))

		if not w then
			die("write " .. where .. ": " .. tostring(werr))
		end
		buf, held = {}, 0
	end
	sink = function(s)
		buf[#buf + 1] = s
		held = held + #s
		if held >= 4096 then
			flush()
		end
	end
	closesink = function()
		flush()
		c:close()
	end
end

local port = sys.newport("btsnoop.evt")
local guard <close> = sys.owned(port)
local ack = sys.newport("btsnoop.ack")
local guard2 <close> = sys.owned(ack)

-- what the driver refused for want of a slot. The record format keeps
-- a cumulative count for this, and writing 0 into it would be the one
-- lie a reader cannot catch: a gap and a quiet line look identical.
local function drops()
	local reply = sys.newport("btsnoop.stat")
	local rguard <close> = sys.owned(reply)

	sys.send(hci, { op = "stats", reply = { __right = reply } })

	local m = thread.recvtimeout(reply, 1000)

	return m and m.drops or 0
end

sys.send(hci, { op = "listen", port = { __right = port },
    reply = { __right = ack } })
if not thread.recvtimeout(ack, 2000) then
	die("the hci task would not register a listener")
end

sink(btsnoop.header())
if flush then
	flush()
end

-- an optional stop, for a recording nobody is standing over. Without
-- one this runs until interrupted, which the periodic flush makes safe.
local secs = (not tostream) and tonumber(arg[2]) or nil
local deadline = secs and (sys.uptime_ms() + secs * 1000) or math.huge

out(secs and string.format("recording %d seconds\n", secs) or
    "recording; interrupt to stop\n")

-- only what the controller sends is seen here. A command going the
-- other way is the sender's to record, so this trace says so rather
-- than pretending to be both halves.
local n = 0
local lost = drops()

while sys.uptime_ms() < deadline do
	local wait = deadline == math.huge and 1000 or
	    math.min(1000, deadline - sys.uptime_ms())
	local m = thread.recvtimeout(port, wait)

	if m and m.data then
		sink(btsnoop.packet(m.data, btsnoop.RECV,
		    sys.uptime_ms() * 1000, lost))
		n = n + 1
	else
		-- the line is quiet: the cheapest moment to pay for a
		-- write, to bound what a kill can take with it, and to
		-- ask what was dropped while we were not looking.
		lost = drops()
		if flush then
			flush()
		end
	end
end

closesink()
out(string.format("%d packets\n", n))
