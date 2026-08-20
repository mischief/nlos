-- gps: where this machine is, and what the receiver is doing.
--
--	> gps            the position, once
--	> gps -w         wait for a fix, then print it
--	> gps -s         the receiver's counters
--	> gps -r         the sentences, as they arrive

local unistd = require("posix.unistd")
local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")

local function out(s)
	unistd.write(1, s)
end

local function die(s)
	unistd.write(2, "gps: " .. s .. "\n")
	os.exit(1)
end

local gps = prog.gps() or die("no receiver on this machine")

local function ask(msg, ms)
	local reply = sys.newport("gps.reply")
	local guard <close> = sys.owned(reply)

	msg.reply = { __right = reply }
	sys.send(gps, msg)
	return thread.recvtimeout(reply, ms or 2000)
end

local function show(f)
	if not f.has then
		out(("no fix yet: %d in view, %d with signal\n"):format(
		    f.sats or 0, f.tracked or 0))
		return
	end
	out(("%.6f %.6f"):format(f.lat, f.lon))
	if f.alt then
		out(("  %.0fm"):format(f.alt))
	end
	if f.speed_knots then
		out(("  %.1fkn"):format(f.speed_knots))
	end
	out(("\n%d satellites in view, %s used, hdop %s, %sd fix\n"):format(
	    f.sats or 0, tostring(f.nsats or 0), tostring(f.hdop or "?"),
	    tostring(f.fixtype or "?")))
	if f.date and f.time then
		out(("%04d-%02d-%02d %02d:%02d:%02.0f UTC\n"):format(
		    f.date.year, f.date.month, f.date.day,
		    f.time // 3600, (f.time % 3600) // 60, f.time % 60))
	end
end

local mode = arg[1]

if mode == "-s" then
	local st = ask({ op = "stats" }) or die("the gps task did not answer")

	out(("baud %s  rx %d bytes  %d sentences, %d good, %d bad, " ..
	    "%d overrun\n"):format(tostring(st.baud), st.rx or 0,
	    st.sentences or 0, st.good or 0, st.bad or 0, st.overrun or 0))
	os.exit(0)
end

if mode == "-r" then
	local port = sys.newport("gps.raw")
	local guard <close> = sys.owned(port)
	local r = ask({ op = "raw", port = { __right = port } })

	if not (r and r.ok) then
		die("the gps task refused a listener")
	end
	while true do
		local m = thread.recv(port)

		if type(m) == "table" and m.line then
			local s = m.line

			out(("%s%s %s\n"):format(s.talker or "??",
			    s.type or "???",
			    s.lat and ("%.5f %.5f"):format(s.lat, s.lon) or
			    ""))
		end
	end
end

-- -w: a cold receiver needs a minute of sky before it knows where it
-- is, so waiting is the normal case rather than an error.
if mode == "-w" then
	for _ = 1, 120 do
		local f = ask({ op = "fix" })

		if f and f.has then
			show(f)
			os.exit(0)
		end
		thread.sleep(1000)
	end
	die("no fix after two minutes")
end

show(ask({ op = "fix" }) or die("the gps task did not answer"))
