-- gpsd: the sole task holding los.platform.gps (a gnss receiver).
-- Others hold a send right to this mailbox and talk by message:
--
--   {op="fix", reply=}                    -> the position, or has=false
--   {op="raw", port={__right=}, reply=}   -> {ok=}, then sentences
--   {op="stats", reply=} {op="baud", baud=, reply=}

-- No threads. This alts over two ports -- the kernel's wakeup and its
-- own mailbox -- so the whole task is one loop and the proc carries no
-- scheduler. A reply is never waited on: a reader that has stopped
-- reading loses a fix rather than stalling the receiver behind it.

local sys = require("los.sys")
local gps = require("los.platform.gps")
local nmea = require("nmea")

-- the kernel's wakeup, granted at spawn. Carries no data: it means
-- only "bytes arrived, read them".
local RAWGPS = 1

-- An L76K runs at this and a u-blox M10Q at the other. Which is fitted
-- is settled by reading: a receiver at the wrong rate answers with
-- framing noise, and noise has no checksum that agrees.
local BAUDS = { 9600, 38400 }

-- how long to give one rate before trying the next. A cold receiver
-- emits sentences long before it has a fix, so this waits on bytes
-- that parse rather than on a position.
local PROBE_MS = 1500
local ROUNDS = 3

local dec = nmea.new()
local fix = nmea.newfix()
local listeners = {}
local baud, good, sentences = nil, 0, 0
local said = false

local function reply(m, msg)
	local h = type(m.reply) == "table" and m.reply.__right or nil

	if h then
		pcall(sys.send, h, msg)
		pcall(sys.close, h)
	end
end

-- What is being received, and not what the almanac says is overhead:
-- a satellite with no signal is the same list in a basement as under
-- open sky, and it is the heard ones that decide whether there is a
-- fix and that change when the receiver is moved.
local function sky()
	local out = {}

	for _, s in ipairs(fix.sats) do
		if (s.snr or 0) > 0 then
			out[#out + 1] = { prn = s.prn, snr = s.snr,
			    elev = s.elev, azim = s.azim, talker = s.talker }
		end
	end
	return out
end

local function position()
	return {
		sky = sky(),
		has = fix:has(), lat = fix.lat, lon = fix.lon,
		alt = fix.alt, speed_knots = fix.speed_knots,
		track = fix.track, nsats = fix.nsats, hdop = fix.hdop,
		fixtype = fix.fixtype, heard = fix:tracked(),
		time = fix.time, date = fix.date, epoch = fix:epoch(),
	}
end

-- Said once, so a log shows when the sky became usable. The clock is
-- not set here: this task holds no capability to move it, and
-- task/timed.lua asks for a fix and decides.
local function announce()
	if said or not fix:has() then
		return
	end
	said = true
	sys.log("gpsd: a fix, %d satellites heard", fix:tracked())
end

-- Every sentence goes to every listener, as hci.lua does with packets:
-- a logger and a panel can want the same stream, and one that saw only
-- what the other ignored would be no use.
local function push(line)
	if #listeners == 0 then
		return
	end

	local live = {}

	for _, h in ipairs(listeners) do
		local ok, why = sys.send(h, { line = line })

		if ok or why == "full" then
			live[#live + 1] = h
		else
			pcall(sys.close, h)
		end
	end
	listeners = live
end

local function drain()
	while true do
		local bytes = gps.read()

		if not bytes then
			return
		end
		dec:feed(bytes)
		while true do
			local s = dec:next()

			if not s then
				break
			end
			sentences = sentences + 1
			if s.valid then
				good = good + 1
				fix:update(s)
				push(s)
				announce()
			end
		end
	end
end

-- Try each rate in turn and keep the one that parses. Nothing here
-- blocks on the receiver: the wakeup port says when bytes are in, and
-- a timer bounds how long a silent rate is given. Several rounds,
-- because a module powered on with the rail is still starting.
local function probe()
	for _ = 1, ROUNDS do
		for _, b in ipairs(BAUDS) do
			if gps.open(b) then
				baud = b

				local deadline = sys.timer(PROBE_MS)
				local before = good

				while deadline do
					local which = sys.alt({ RAWGPS, deadline })

					if which == 1 then
						drain()
						if good > before then
							sys.close(deadline)
							return true
						end
					else
						break
					end
				end
				pcall(sys.close, deadline)
			end
		end
	end
	return false
end

if probe() then
	sys.log("gpsd: a receiver at %d baud", baud)
else
	-- bytes but no sentence is a rate this does not try or a module
	-- that speaks something else; no bytes at all is no module.
	sys.log("gpsd: no sentences after %dms; %d bytes seen, %d lines, " ..
	    "%d bad", ROUNDS * #BAUDS * PROBE_MS, gps.stats().rx, sentences,
	    dec.bad)
end

while true do
	local which, m = sys.alt({ RAWGPS, sys.SELF })

	if which == 1 then
		drain()
	elseif type(m) ~= "table" then
	elseif m.op == "fix" then
		reply(m, position())
	elseif m.op == "raw" then
		local h = type(m.port) == "table" and m.port.__right or nil

		if h then
			listeners[#listeners + 1] = h
			reply(m, { ok = true })
		else
			reply(m, { ok = false, err = "raw needs a port right" })
		end
	elseif m.op == "stats" then
		local st = gps.stats()

		reply(m, { rx = st.rx, sentences = sentences, good = good,
		    bad = dec.bad, overrun = dec.overrun, baud = baud,
		    listeners = #listeners })
	elseif m.op == "baud" then
		local b = tonumber(m.baud)

		if b and gps.open(b) then
			baud = b
			reply(m, { ok = true, baud = b })
		else
			reply(m, { ok = false, baud = baud })
		end
	else
		reply(m, { err = "unknown op" })
	end
end
