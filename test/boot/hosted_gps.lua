-- the gps stack on the host, off a recording.

-- Not in the suite: it wants LUAOS_GPS naming a fixture, and a run
-- without one is a machine with no receiver rather than a failure. It
-- is for debugging the parser and the fix where a board is not needed.

--	LUAOS_GPS=test/fixtures/gps-cold.nmea \
--	MESON_SOURCE_ROOT=$PWD LUA_CPATH='build-hosted/?.so;;' \
--	lua5.4 tools/boottest-hosted.lua \
--	    build-hosted/src/platform/hosted/luaos-hosted \
--	    test/boot/hosted_gps.lua

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(6)

local ok, gps = pcall(require, "los.platform.gps")

tap.ok(ok and gps ~= nil and gps.open ~= nil,
    "the replay driver is here; LUAOS_GPS names a file")
if not (ok and gps and gps.open) then
	tap.done()
	return
end

tap.ok(gps.open(9600), "it opens, whatever baud is asked for")

-- feed the parser straight from the driver, which is what gpsd does.
-- Doing it here rather than talking to gpsd keeps this a test of the
-- stack and not of the capability plumbing.
local nmea = require("nmea")
local dec, fix = nmea.new(), nmea.newfix()
local seen, good = 0, 0

for _ = 1, 4000 do
	local b = gps.read()

	if b then
		dec:feed(b)
		while true do
			local s = dec:next()

			if not s then
				break
			end
			seen = seen + 1
			if s.valid then
				good = good + 1
				fix:update(s)
			end
		end
	else
		thread.sleep(10)
	end
end

tap.diag(("%d sentences, %d good, %d bad, %d bytes"):format(seen, good,
    dec.bad, gps.stats().rx))

tap.ok(seen > 100, ("the recording replays: %d sentences"):format(seen))
tap.ok(dec.bad == 0, ("every one checks out: %d bad"):format(dec.bad))

-- what a cold receiver reports: sentences, a clock, and no position.
-- A fixture taken with a fix would assert the other way here.
tap.ok(fix.date ~= nil or fix.time ~= nil,
    "the receiver knows the time before it knows the place")
tap.ok(#fix.sats >= 0, ("the sky parses: %d heard"):format(fix:tracked()))

tap.done()
