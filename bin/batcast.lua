-- batcast: shout the battery over udp, one line a datagram.
--
--	batcast 192.168.0.12            every 10s to port 9999
--	batcast 192.168.0.12:5555 60    that port, once a minute
--	socat -u UDP-RECV:9999 -        watch it from the other end

-- The console is USB, and a battery measurement is exactly the case
-- where USB cannot be plugged in, so the radio is the only way to watch
-- a machine running on its pack. Send only: nothing is read back, so
-- no listener need exist and none is waited for.

local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")
local battery = require("battery")

local function die(s)
	io.stderr:write("batcast: " .. s .. "\n")
	os.exit(1)
end

local dest = arg[1]
local every = tonumber(arg[2]) or 10

if not dest then
	die("usage: batcast HOST[:PORT] [SECONDS]")
end

local host, port = dest:match("^([^:]+):(%d+)$")

host = host or dest
port = tonumber(port) or 9999

local sa, sb, sc, sd = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

if not sa then
	die("not an address: " .. host .. " (a name needs a resolver)")
end
sa, sb, sc, sd = tonumber(sa), tonumber(sb), tonumber(sc), tonumber(sd)

local udp = prog.udp()

if not udp then
	die("no udp capability: this shell was lent none")
end

local conn = udp.open(0)

if not conn then
	die("cannot open a udp port")
end

-- the meter rather than the plain reading: this polls, so it is the
-- caller the plug-in transient guard exists for.
local meter = battery.meter()

-- a port to wait on. Nothing sends to it -- the wait is the interval.
local tick = sys.newport("batcast.tick")

while true do
	local mv, pct, chg = meter()
	local line

	if mv then
		-- the millivolts go out either way, since a charging trace
		-- is still worth watching; only the charge is withheld,
		-- because on the charger the pin is not reading the pack.
		line = string.format("battery mv=%d pct=%s chg=%d up=%d\n",
		    mv, pct and tostring(pct) or "?", chg and 1 or 0,
		    sys.uptime_ms())
	else
		line = string.format("battery none up=%d\n", sys.uptime_ms())
	end

	-- a failed send is not fatal: the radio drops when the machine
	-- roams or a lease lapses, and a meter that quit on the first
	-- miss would fail at exactly the long unattended run it is for.
	udp.send(conn, sa, sb, sc, sd, port, line)
	thread.recvtimeout(tick, every * 1000)
end
