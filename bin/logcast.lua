-- logcast: the kernel transcript over udp, as it is written.
--
--	logcast 192.168.0.12            follow, to port 9998
--	logcast 192.168.0.12:5555       that port
--	socat -u UDP-RECV:9998 -        watch it from the other end
--
-- For a machine whose console cannot be reached: driving the USB port
-- as a host takes it away from the console that shares it.

local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")
local unistd = require("posix.unistd")

local PORT = 9998
local POLL = 200

local function die(s)
	unistd.write(2, "logcast: " .. s .. "\n")
	os.exit(1)
end

local dest = arg[1] or die("usage: logcast HOST[:PORT]")
local host, port = dest:match("^([^:]+):(%d+)$")

host = host or dest
port = tonumber(port) or PORT

local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

if not a then
	die("not an address: " .. host .. " (a name needs a resolver)")
end

local udp = prog.udp() or die("no udp capability: this shell was lent none")
local conn = udp.open(0) or die("cannot open a udp port")
local sa, sb, sc, sd = tonumber(a), tonumber(b), tonumber(c), tonumber(d)

-- -1 is where the ring already is, so what is on screen is not resent.
-- A line is sent whole: the reader is a datagram at a time.
local from = select(2, sys.dmesg(-1, 1))
local tick = sys.newport("logcast.tick")

while true do
	local text, next, dropped = sys.dmesg(from)

	if text ~= "" then
		if dropped > 0 then
			udp.send(conn, sa, sb, sc, sd, port,
			    ("logcast: %d lines lost\n"):format(dropped))
		end
		udp.send(conn, sa, sb, sc, sd, port, text)
		from = next
	else
		thread.recvtimeout(tick, POLL)
	end
end
