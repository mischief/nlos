-- NMEA 0183, the sentences a gps emitter sends.
--
-- Sans-io: nothing here reads, writes, sleeps or knows what a port is.
-- Bytes go in with :feed(), one parsed sentence comes out of each
-- :next(). A Fix folds those into one position, because a caller wants
-- where it is rather than a run of GSV.

local M = {}

-- A sentence is 82 bytes at most, delimiters included. Anything longer
-- is a line that lost its terminator -- the pin this receiver sits on
-- carries the rom bootloader's chatter before our code runs -- so the
-- decoder drops it and resyncs on the next $ rather than growing.
local MAXLINE = 82

-- ---- fields ----

local function xorsum(s)
	local c = 0

	for i = 1, #s do
		c = c ~ s:byte(i)
	end
	return c
end

-- An empty field is absent, not zero: a receiver with no fix sends
-- ",,," and a caller must be able to tell that from a real 0.
local function num(s)
	if s == nil or s == "" then
		return nil
	end
	return tonumber(s)
end

local function str(s)
	if s == nil or s == "" then
		return nil
	end
	return s
end

-- ddmm.mmmm with the hemisphere in its own field, which is degrees
-- plus minutes and not a decimal fraction: 4807.038 is 48 degrees and
-- 7.038 minutes, so the split is by position rather than by arithmetic.
local function coord(v, hemi)
	if v == nil or v == "" or hemi == nil or hemi == "" then
		return nil
	end

	local dot = v:find(".", 1, true) or (#v + 1)
	local deg = tonumber(v:sub(1, dot - 3))
	local min = tonumber(v:sub(dot - 2))

	if not deg or not min then
		return nil
	end

	local d = deg + min / 60

	if hemi == "S" or hemi == "W" then
		d = -d
	end
	return d
end

-- hhmmss.sss UTC, as seconds since midnight. The fraction is kept:
-- a receiver that emits it is saying when the fix was taken.
local function tod(s)
	if s == nil or #s < 6 then
		return nil
	end

	local h = tonumber(s:sub(1, 2))
	local m = tonumber(s:sub(3, 4))
	local sec = tonumber(s:sub(5))

	if not h or not m or not sec then
		return nil
	end
	return h * 3600 + m * 60 + sec
end

-- ddmmyy. Two digits of year, so the century is a window: NMEA is not
-- older than 1980 and this reading is not the far future.
local function date(s)
	if s == nil or #s ~= 6 then
		return nil
	end

	local d = tonumber(s:sub(1, 2))
	local mo = tonumber(s:sub(3, 4))
	local y = tonumber(s:sub(5, 6))

	if not d or not mo or not y then
		return nil
	end
	return { day = d, month = mo, year = y < 80 and 2000 + y or 1900 + y }
end

-- ---- one sentence ----

M.MAXLINE = MAXLINE

function M.checksum(body)
	return xorsum(body)
end

-- A sentence to send, checksum and terminator added: a receiver is
-- configured with the same grammar it answers in, and the L76K on this
-- board wants $PCAS before it will say which module it is.
function M.sentence(body)
	return ("$%s*%02X\r\n"):format(body, xorsum(body))
end

function M.split(body)
	local f = {}

	for s in (body .. ","):gmatch("([^,]*),") do
		f[#f + 1] = s
	end
	return f
end

local parse = {}

function parse.RMC(f, t)
	t.time = tod(f[2])
	t.active = f[3] == "A"
	t.lat = coord(f[4], f[5])
	t.lon = coord(f[6], f[7])
	t.speed_knots = num(f[8])
	t.track = num(f[9])
	t.date = date(f[10])
	t.mode = str(f[13])
end

function parse.GGA(f, t)
	t.time = tod(f[2])
	t.lat = coord(f[3], f[4])
	t.lon = coord(f[5], f[6])
	t.quality = num(f[7])
	t.nsats = num(f[8])
	t.hdop = num(f[9])
	t.alt = num(f[10])
	t.geoid = num(f[12])
end

function parse.GSA(f, t)
	t.select = str(f[2])
	t.fixtype = num(f[3])

	local prns = {}

	for i = 4, 15 do
		local p = num(f[i])

		if p then
			prns[#prns + 1] = p
		end
	end
	t.prns = prns
	t.pdop = num(f[16])
	t.hdop = num(f[17])
	t.vdop = num(f[18])
end

-- one of several: nmsg says how many make a full view, msg which this
-- is. The tuples run to the end of the sentence and the last one is
-- short where the count is not a multiple of four.
function parse.GSV(f, t)
	t.nmsg = num(f[2])
	t.msg = num(f[3])
	t.inview = num(f[4])

	local sats = {}

	for i = 5, #f - 3, 4 do
		local prn = num(f[i])

		if prn then
			sats[#sats + 1] = { prn = prn, elev = num(f[i + 1]),
			    azim = num(f[i + 2]), snr = num(f[i + 3]) }
		end
	end
	t.sats = sats
end

function parse.VTG(f, t)
	t.track = num(f[2])
	t.track_mag = num(f[4])
	t.speed_knots = num(f[6])
	t.speed_kph = num(f[8])
	t.mode = str(f[10])
end

function parse.GLL(f, t)
	t.lat = coord(f[2], f[3])
	t.lon = coord(f[4], f[5])
	t.time = tod(f[6])
	t.active = f[7] == "A"
	t.mode = str(f[8])
end

function parse.ZDA(f, t)
	t.time = tod(f[2])

	local d, mo, y = num(f[3]), num(f[4]), num(f[5])

	if d and mo and y then
		t.date = { day = d, month = mo, year = y }
	end
end

function parse.TXT(f, t)
	t.text = str(f[5])
end

-- Parse one complete sentence, $ and checksum included. A sentence
-- with a bad or absent checksum still comes back: `valid` says which,
-- and a caller counting line noise wants to see them.
function M.parse(line)
	local body = line:match("^%$([^*]*)")

	if not body then
		return nil, "no $"
	end

	local want = line:match("%*(%x%x)%s*$")
	-- the line as it arrived, so a reader can log what it was given
	-- rather than something rebuilt out of the fields
	local t = {
		raw = line,
		talker = body:sub(1, 2),
		type = body:sub(3, 5),
		valid = want == nil or tonumber(want, 16) == xorsum(body),
		checked = want ~= nil,
	}

	if not t.valid then
		return t
	end

	local f = M.split(body)

	t.fields = f

	local p = parse[t.type]

	if p then
		p(f, t)
	end
	return t
end

-- ---- the stream ----

local Dec = {}

Dec.__index = Dec

function M.new()
	return setmetatable({ buf = "", overrun = 0, bad = 0 }, Dec)
end

function Dec:feed(s)
	if s and s ~= "" then
		self.buf = self.buf .. s
	end
end

-- The next sentence, or nil where the input has run dry. Bytes before
-- a $ are line noise and are dropped; a $ with no terminator within
-- MAXLINE is a lost line and is dropped with it.
function Dec:next()
	while true do
		local s = self.buf:find("$", 1, true)

		if not s then
			self.buf = ""
			return nil
		end
		if s > 1 then
			self.buf = self.buf:sub(s)
		end

		local e = self.buf:find("[\r\n]")

		if not e then
			if #self.buf > MAXLINE then
				self.overrun = self.overrun + 1
				self.buf = self.buf:sub(2)
			else
				return nil
			end
		else
			local line = self.buf:sub(1, e - 1)

			self.buf = self.buf:sub(e + 1)

			local t = M.parse(line)

			if t then
				if not t.valid then
					self.bad = self.bad + 1
				end
				return t
			end
		end
	end
end

-- ---- where we are ----

local Fix = {}

Fix.__index = Fix

-- view is the latest complete run per talker; gsv is the one being
-- received. sats is every view together, which is what a caller reads.
function M.newfix()
	return setmetatable({ nsen = 0, sats = {}, gsv = {}, view = {} },
	    Fix)
end

-- days since the epoch from a civil date, so a logger can stamp a line
-- without a clock. Proleptic gregorian, March-based years: see Hinnant.
local function days(y, m, d)
	y = m <= 2 and y - 1 or y

	local era = (y >= 0 and y or y - 399) // 400
	local yoe = y - era * 400
	local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy

	return era * 146097 + doe - 719468
end

function M.epoch(d, t)
	if not d or not t then
		return nil
	end
	return days(d.year, d.month, d.day) * 86400 + math.floor(t)
end

-- Fold one sentence in. Only what the sentence carries is written, so
-- a GGA with no altitude does not erase the last one that had it.
function Fix:update(t)
	if not t or not t.valid then
		return false
	end
	self.nsen = self.nsen + 1

	local ty = t.type

	if ty == "RMC" or ty == "GLL" then
		self.active = t.active
	end
	if t.lat and t.lon then
		self.lat, self.lon = t.lat, t.lon
	end
	if t.time then
		self.time = t.time
	end
	if t.date then
		self.date = t.date
	end
	if t.speed_knots then
		self.speed_knots = t.speed_knots
	end
	if t.speed_kph then
		self.speed_kph = t.speed_kph
	end
	if t.track then
		self.track = t.track
	end
	if t.alt then
		self.alt = t.alt
	end
	if t.quality then
		self.quality = t.quality
	end
	if t.nsats then
		self.nsats = t.nsats
	end
	if t.fixtype then
		self.fixtype = t.fixtype
	end
	if t.hdop then
		self.hdop = t.hdop
	end
	if t.pdop then
		self.pdop = t.pdop
	end
	if t.vdop then
		self.vdop = t.vdop
	end

	-- A run per talker, and they interleave: a multi-constellation
	-- receiver sends GPGSV, then GAGSV, then GBGSV, each numbered
	-- from one. Merging them by number alone leaves the sky as
	-- whichever constellation reported last. Each run is swapped in
	-- whole, because a partial one reports a shrinking view.
	if ty == "GSV" and t.msg and t.nmsg then
		local who = t.talker

		if t.msg == 1 then
			self.gsv[who] = {}
		end

		local run = self.gsv[who]

		if run then
			for _, s in ipairs(t.sats or {}) do
				s.talker = who
				run[#run + 1] = s
			end
			if t.msg == t.nmsg then
				self.view[who] = run
				self.gsv[who] = nil
				self:resky()
			end
		end
	end
	return true
end

-- the whole sky, every constellation's latest complete run together.
function Fix:resky()
	local all = {}

	for _, run in pairs(self.view) do
		for _, s in ipairs(run) do
			all[#all + 1] = s
		end
	end
	self.sats = all
end

-- how many are actually being received, which is not how many are up
-- there: a satellite in view with no signal reports snr 0 or none.
function Fix:tracked()
	local n = 0

	for _, s in ipairs(self.sats) do
		if (s.snr or 0) > 0 then
			n = n + 1
		end
	end
	return n
end

-- A fix is a position this receiver stands behind: RMC said active, or
-- GGA gave a quality above zero. Without one the coordinates are the
-- last that were, and saying so is the point.
function Fix:has()
	return (self.active == true or (self.quality or 0) > 0) and
	    self.lat ~= nil and self.lon ~= nil
end

function Fix:epoch()
	return M.epoch(self.date, self.time)
end

return M
