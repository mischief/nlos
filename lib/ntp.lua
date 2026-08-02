-- SNTP, RFC 4330: forty-eight bytes out, forty-eight back, and the
-- machine knows what time it is.
--
-- Worth having for more than the demo. microvm has no real-time clock
-- at all -- our launchers pass rtc=off, and vmd's guests have no
-- battery-backed anything either -- so the only notion of time this
-- machine has is a cycle counter since boot. That makes the wall clock
-- something it can only be told, and this is the telling.
--
-- The simple mode of RFC 5905: one request, one reply, take the
-- server's transmit timestamp. No filtering, no discipline, no
-- adjusting a local oscillator. Those matter when you intend to stay in
-- sync; getting the date right once, at boot, needs none of them.
--
-- The awkward part is the epoch. NTP counts seconds from 1900 and unix
-- from 1970, which differ by 2208988800 seconds -- and NTP's era rolls
-- over in 2036, so the top bit of the seconds field is not a sign, it
-- is a date.

local ntp = {}

ntp.PORT = 123
ntp.PKTLEN = 48

-- seconds between 1900-01-01 and 1970-01-01, including the leap days.
ntp.EPOCH_OFFSET = 2208988800

ntp.MODE_CLIENT = 3
ntp.MODE_SERVER = 4

-- leap indicator 0, version 4, mode 3. A version 3 server answers a
-- version 4 request, so this is the safe thing to ask with.
local LI_VN_MODE = (0 << 6) | (4 << 3) | ntp.MODE_CLIENT

-- an unsynchronised server says so, and its time is not to be believed.
ntp.LEAP_UNSYNC = 3

function ntp.request()
	-- everything but the first byte is zero: a client has no
	-- timestamps worth sending, and the server ignores them anyway in
	-- this mode. The transmit timestamp would be echoed back as the
	-- originate timestamp, which matters for computing delay -- we do
	-- not, so it stays zero.
	return string.char(LI_VN_MODE) .. string.rep("\0", ntp.PKTLEN - 1)
end

-- a 64-bit NTP timestamp: 32 bits of seconds, 32 of fraction.
local function timestamp(p, off)
	local secs, frac = string.unpack(">I4I4", p, off)

	return secs, frac
end

-- nil unless it is a server's reply and it claims to know the time.
function ntp.decode(p)
	if type(p) ~= "string" or #p < ntp.PKTLEN then
		return nil, "short packet"
	end

	local b = p:byte(1)
	local leap = b >> 6
	local mode = b & 7
	local stratum = p:byte(2)

	if mode ~= ntp.MODE_SERVER then
		return nil, "not a server reply"
	end

	-- stratum 0 is a kiss-o'-death: the server is refusing, and the
	-- four bytes of reference id say why in ascii.
	if stratum == 0 then
		return nil, "kiss of death: " .. p:sub(13, 16)
	end
	if leap == ntp.LEAP_UNSYNC then
		return nil, "server is not synchronised"
	end

	local secs, frac = timestamp(p, 41)	-- transmit timestamp

	if secs == 0 then
		return nil, "no transmit timestamp"
	end

	return {
		leap = leap,
		stratum = stratum,
		refid = p:sub(13, 16),
		secs = secs,			-- NTP epoch
		frac = frac,
		unix = secs - ntp.EPOCH_OFFSET,	-- may be negative before 1970
		ms = (frac * 1000) // 0x100000000,
	}
end

-- days in each month, non-leap
local MDAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function leapyear(y)
	return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

-- unix seconds -> "YYYY-MM-DD HH:MM:SS", UTC.
--
-- Done here rather than with os.date because there is no libc timezone
-- database on this machine and os.time/os.date have nothing to work
-- from -- the point of fetching the time is that nothing else knows it.
function ntp.utc(unix)
	local days = unix // 86400
	local rem = unix % 86400
	local y = 1970

	while true do
		local n = leapyear(y) and 366 or 365

		if days < n then
			break
		end
		days = days - n
		y = y + 1
	end

	local mon = 1

	while true do
		local n = MDAYS[mon]

		if mon == 2 and leapyear(y) then
			n = 29
		end
		if days < n then
			break
		end
		days = days - n
		mon = mon + 1
	end

	return string.format("%04d-%02d-%02d %02d:%02d:%02d", y, mon, days + 1,
	    rem // 3600, (rem % 3600) // 60, rem % 60)
end

return ntp
