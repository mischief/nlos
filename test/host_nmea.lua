#!/usr/bin/env lua5.4
-- lib/nmea.lua on the host. Sans-io, so the whole of it runs here: the
-- bytes are strings and the only thing a board adds is a uart.
-- TAP direct: lib/tap.lua needs los.sys.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local nmea = require("nmea")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
end

local function is(got, want, name)
	ok(got == want, ("%s (got %s, want %s)"):format(name, tostring(got),
	    tostring(want)))
end

-- within a tolerance, since these are degrees carried as floats
local function near(got, want, eps, name)
	ok(type(got) == "number" and math.abs(got - want) < eps,
	    ("%s (got %s, want ~%s)"):format(name, tostring(got),
	    tostring(want)))
end

-- ---- checksums ----

local RMC = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4," ..
    "230394,003.1,W*6A"
local GGA = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M," ..
    "46.9,M,,*47"

is(nmea.checksum(RMC:match("^%$([^*]*)")), 0x6a, "RMC checksum is 6A")
is(nmea.checksum(GGA:match("^%$([^*]*)")), 0x47, "GGA checksum is 47")

-- ---- sentences to send ----
--
-- The reference is LilyGO's own GPSShield sketch, which is what the
-- module on this board is known to answer: if the builder and their
-- literals disagree, one of the two is wrong about the same wire.

is(nmea.sentence("PCAS06,0"), "$PCAS06,0*1B\r\n", "the L76K version query")
is(nmea.sentence("PCAS04,5"), "$PCAS04,5*1C\r\n", "GPS+GLONASS")
is(nmea.sentence("PCAS11,3"), "$PCAS11,3*1E\r\n", "vehicle mode")
is(nmea.sentence("PCAS03,0,0,0,0,0,0,0,0,0,0,,,0,0"),
    "$PCAS03,0,0,0,0,0,0,0,0,0,0,,,0,0*02\r\n", "stop every sentence")

-- ---- one sentence ----

local t = nmea.parse(RMC)

is(t.talker, "GP", "the talker is read")
is(t.type, "RMC", "so is the sentence type")
is(t.valid, true, "a good checksum validates")
is(t.active, true, "status A is a fix")
near(t.lat, 48.1173, 1e-4, "ddmm.mmmm becomes degrees")
near(t.lon, 11.51667, 1e-4, "and so does dddmm.mmmm")
is(t.time, 12 * 3600 + 35 * 60 + 19, "the time is seconds into the day")
is(t.date.year, 1994, "a year below 80 is last century")
is(t.date.month, 3, "the month is read")
is(t.date.day, 23, "and the day")
near(t.speed_knots, 22.4, 1e-6, "speed comes over in knots")

local g = nmea.parse(GGA)

is(g.quality, 1, "GGA carries a fix quality")
is(g.nsats, 8, "and a satellite count")
near(g.alt, 545.4, 1e-6, "and an altitude GGA alone has")

-- ---- the hemispheres that are negative ----

local S = "$GPGLL,3350.000,S,15113.000,W,012345,A"

t = nmea.parse(S)
ok(t.lat < 0, "a southern latitude is negative")
ok(t.lon < 0, "a western longitude is negative")
is(t.valid, true, "a sentence with no checksum is taken as given")
is(t.checked, false, "and says it was not checked")

-- ---- an empty field is absent, not zero ----

t = nmea.parse("$GPRMC,,V,,,,,,,,,,N*53")
is(t.active, false, "status V is no fix")
is(t.lat, nil, "an empty latitude is nil")
is(t.speed_knots, nil, "an empty speed is nil, not 0")

-- ---- the stream ----

local d = nmea.new()

d:feed(RMC .. "\r\n" .. GGA .. "\r\n")
is(d:next().type, "RMC", "the first sentence out of the stream")
is(d:next().type, "GGA", "then the second")
is(d:next(), nil, "and then the input has run dry")

-- a sentence split across feeds is one sentence
d = nmea.new()
d:feed(RMC:sub(1, 20))
is(d:next(), nil, "half a sentence yields nothing")
d:feed(RMC:sub(21) .. "\r\n")
is(d:next().type, "RMC", "the other half completes it")

-- line noise before the $ is dropped, which is what the rom
-- bootloader on this pin leaves behind
d = nmea.new()
d:feed("\0\255rst:0x1 boot:0x8\r\n" .. RMC .. "\n")
local n = d:next()

is(n and n.type, "RMC", "noise ahead of a $ is skipped")

-- ---- what a bad line does ----

d = nmea.new()
d:feed("$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394," ..
    "003.1,W*00\r\n")
t = d:next()
is(t.valid, false, "a wrong checksum is reported, not swallowed")
is(d.bad, 1, "and counted")

-- a $ with no terminator cannot grow without bound
d = nmea.new()
d:feed("$" .. string.rep("A", nmea.MAXLINE * 3))
is(d:next(), nil, "an unterminated line yields nothing")
ok(d.overrun > 0, "and is counted as an overrun")
ok(#d.buf <= nmea.MAXLINE + 1, "leaving the buffer bounded")

-- ---- the sky, across several GSV ----

local f = nmea.newfix()
local GSV = {
	"$GPGSV,3,1,11,03,03,111,00,04,15,270,00,06,01,010,00,13,06,292,00*74",
	"$GPGSV,3,2,11,14,25,170,00,16,57,208,39,18,67,296,40,19,40,246,00*74",
	"$GPGSV,3,3,11,22,42,067,42,24,14,311,43,27,05,244,00*4D",
}

for i, s in ipairs(GSV) do
	local sen = nmea.parse(s)

	is(sen.valid, true, "GSV " .. i .. " checks out")
	f:update(sen)
end
is(#f.sats, 11, "the whole view arrives as one list")
is(f.sats[1].prn, 3, "with the first satellite's prn")
is(f.sats[11].snr, 0, "and an snr of 00, which is a reading and not a gap")

-- a tuple cut short by the end of the sentence: the fields that are
-- there are read and the ones that are not stay nil
local short = nmea.parse("$GPGSV,1,1,01,22,42,067,*4F")

is(#short.sats, 1, "a short last tuple is still a satellite")
is(short.sats[1].azim, 67, "with what it carries")
is(short.sats[1].snr, nil, "and an absent snr left absent")

-- a partial run does not publish a shrinking sky
f = nmea.newfix()
f:update(nmea.parse(GSV[1]))
is(#f.sats, 0, "one message of three publishes nothing")

-- ---- more than one constellation ----
--
-- A u-blox M10Q sends GPGSV, then GAGSV, then GBGSV and GQGSV, each
-- run numbered from one. Keyed by number alone the sky would be
-- whichever talker reported last.

f = nmea.newfix()
for _, s in ipairs(GSV) do
	f:update(nmea.parse(s))
end
is(#f.sats, 11, "one constellation's run is the sky so far")

local GA = {
	"$GAGSV,2,1,05,02,40,100,35,03,20,200,30,05,60,300,40,07,10,050,00*XX",
	"$GAGSV,2,2,05,09,75,120,45*XX",
}

for i, s in ipairs(GA) do
	local body = s:match("^%$([^*]*)")

	GA[i] = nmea.sentence(body):gsub("\r\n$", "")
end
for _, s in ipairs(GA) do
	f:update(nmea.parse(s))
end
is(#f.sats, 16, "a second talker adds to the sky, it does not replace it")

-- and a fresh run from one talker replaces only that talker's
f:update(nmea.parse(nmea.sentence(
    "GAGSV,1,1,01,02,40,100,35"):gsub("\r\n$", "")))
is(#f.sats, 12, "a talker's new run replaces its own and no other")

-- in view is not being received: a satellite with snr 0 is up there
-- and not heard, which is what an indoor receiver reports
-- four of the eleven GPS have a reading, and the one Galileo left
is(f:tracked(), 5, "only the ones with signal are tracked")

-- ---- the fix ----

f = nmea.newfix()
is(f:has(), false, "a fresh fix has no position")
f:update(nmea.parse(RMC))
is(f:has(), true, "an active RMC is a position")
near(f.lat, 48.1173, 1e-4, "which the fix carries")
f:update(nmea.parse(GGA))
near(f.alt, 545.4, 1e-6, "GGA adds the altitude RMC has not")
near(f.lat, 48.1173, 1e-4, "without disturbing the position")

-- a sentence that carries no altitude does not erase one
f:update(nmea.parse(RMC))
near(f.alt, 545.4, 1e-6, "and a later RMC leaves the altitude alone")

-- ---- time, without a clock ----

is(f:epoch(), 764426119, "date and time make a unix second")
is(nmea.epoch({ year = 2026, month = 8, day = 20 }, 0), 1787184000,
    "and so does a date this century")
is(nmea.epoch({ year = 1980, month = 1, day = 6 }, 0), 315964800,
    "and the gps epoch itself")

-- ---- a run of one of everything ----

d = nmea.new()
d:feed(table.concat({
	RMC, GGA, GSV[1], GSV[2], GSV[3],
	"$GPGSA,A,3,04,05,,09,12,,,24,,,,,2.5,1.3,2.1*39",
	"$GPVTG,054.7,T,034.4,M,005.5,N,010.2,K*48",
	"$GPZDA,201530.00,04,07,2002,00,00*60",
	"$GPTXT,01,01,02,u-blox ag - www.u-blox.com*50",
}, "\r\n") .. "\r\n")

f = nmea.newfix()

local seen, bad = 0, 0

while true do
	local s = d:next()

	if not s then
		break
	end
	seen = seen + 1
	if not s.valid then
		bad = bad + 1
	end
	f:update(s)
end

is(seen, 9, "every sentence in the run came out")
is(bad, 0, "and every one of them checked out")
is(f.fixtype, 3, "GSA gives the 3d fix type")
near(f.vdop, 2.1, 1e-6, "and the vertical dilution")
near(f.speed_kph, 10.2, 1e-6, "VTG gives speed over ground in km/h")
is(f.date.year, 2002, "ZDA gives a four-digit year straight")

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
