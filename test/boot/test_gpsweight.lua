-- what a gps service would weigh, before one is written.
--
-- Four probes running the same chunk, differing only in what they
-- require and hold. The number that matters is the last minus the
-- first: a receiver emitting once a second does not justify a resident
-- proc unless that difference is small.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(4)

local rp = sys.newport("gpsweight.r")

-- A second of a receiver's output, which is what the decoder is asked
-- to hold: one fix, one view of the sky, and the sentences around them.
local RUN = table.concat({
	"$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A",
	"$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47",
	"$GPGSA,A,3,04,05,,09,12,,,24,,,,,2.5,1.3,2.1*39",
	"$GPGSV,3,1,11,03,03,111,00,04,15,270,00,06,01,010,00,13,06,292,00*74",
	"$GPGSV,3,2,11,14,25,170,00,16,57,208,39,18,67,296,40,19,40,246,00*74",
	"$GPGSV,3,3,11,22,42,067,42,24,14,311,43,27,05,244,00*4D",
	"$GPVTG,054.7,T,034.4,M,005.5,N,010.2,K*48",
}, "\r\n") .. "\r\n"

-- Each probe parks when it is done, so what is measured is a proc at
-- rest holding its working set rather than one mid-allocation.
local PROBE = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)
	local keep

	%s

	sys.send(m.reply.__right, { ready = true })
	thread.recv(sys.SELF)
]]

local function weigh(what, body)
	local pid, ch = sys.spawn(PROBE:format(body), { name = what })

	sys.send(ch, { reply = { __right = rp }, run = RUN })
	thread.recv(rp)

	local used = sys.meminfo(pid)

	sys.close(ch)
	return pid, used or 0
end

local _, bare = weigh("bare", "")
local _, lib = weigh("lib", 'keep = require("nmea")')
local _, decode = weigh("decode", [[
	local nmea = require("nmea")
	local d, f = nmea.new(), nmea.newfix()

	for _ = 1, 8 do
		d:feed(m.run)
		while true do
			local s = d:next()

			if not s then
				break
			end
			f:update(s)
		end
	end
	keep = { d, f }
]])
local _, full = weigh("full", [[
	local nmea = require("nmea")
	local srv = require("srv")
	local dev = require("dev")
	local d, f = nmea.new(), nmea.newfix()

	for _ = 1, 8 do
		d:feed(m.run)
		while true do
			local s = d:next()

			if not s then
				break
			end
			f:update(s)
		end
	end

	local B = {}

	function B.attach() return { name = nil } end
	function B.walk(h, name) return { name = name } end
	function B.open(h) return dev.closable(B, { name = h.name }) end
	function B.read(h, off, n)
		local s = ("lat %s\nlon %s\n"):format(tostring(f.lat),
		    tostring(f.lon))

		return off >= #s and "" or s:sub(off + 1, off + n)
	end

	keep = { d, f, B, srv }
]])

tap.diag(("bare   %6d bytes"):format(bare))
tap.diag(("+nmea  %6d bytes  (+%d)"):format(lib, lib - bare))
tap.diag(("+state %6d bytes  (+%d)"):format(decode, decode - lib))
tap.diag(("+srv   %6d bytes  (+%d)"):format(full, full - decode))
tap.diag(("a gpsd would cost %d bytes over a bare proc"):format(full - bare))

tap.ok(bare > 0, "a bare proc reports its memory")
tap.ok(lib > bare, "requiring the parser costs something")

-- The parser holds a buffer, a fix and a view of the sky, all bounded:
-- MAXLINE caps the buffer and the sky is swapped rather than grown, so
-- eight runs through must not read differently from one.
tap.ok(decode - lib < 24 * 1024,
    ("the decoder's working set stays small: %d"):format(decode - lib))

-- The ceiling a service has to fit under to be worth leaving resident.
tap.ok(full - bare < 96 * 1024,
    ("a gpsd fits in 96K over bare: %d"):format(full - bare))

sys.close(rp)
tap.done()
