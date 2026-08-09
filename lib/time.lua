-- time: unix seconds to a date, and back. UTC only -- there is no
-- timezone database here, so a local time would be a fiction with a
-- plausible format. Apply an offset to the seconds instead.

local M = {}

local MDAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function leap(y)
	return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local function mdays(y, m)
	if m == 2 and leap(y) then
		return 29
	end
	return MDAYS[m]
end

-- unix seconds -> the fields os.date("*t") answers with.
--
-- wday is 1..7 with Sunday at 1, and yday 1..366, both as lua has them.
-- 1970-01-01 was a Thursday, which is where the wday arithmetic starts.
function M.utc(unix)
	unix = math.floor(unix)

	local days = unix // 86400
	local rem = unix % 86400
	local wday = (days + 4) % 7 + 1
	local y = 1970

	while true do
		local n = leap(y) and 366 or 365

		if days < n then
			break
		end
		days = days - n
		y = y + 1
	end

	local yday = days + 1
	local mon = 1

	while days >= mdays(y, mon) do
		days = days - mdays(y, mon)
		mon = mon + 1
	end

	return {
		year = y, month = mon, day = days + 1,
		hour = rem // 3600, min = (rem % 3600) // 60, sec = rem % 60,
		wday = wday, yday = yday, isdst = false,
	}
end

-- the fields back to unix seconds, as os.time(t) does. Out of range
-- fields carry: { month = 13 } is January of the next year, which is
-- what makes this usable for arithmetic and not only for parsing.
function M.unix(t)
	local y = t.year
	local mon = (t.month or 1) - 1
	local days = 0

	y = y + mon // 12
	mon = mon % 12 + 1

	if y >= 1970 then
		for i = 1970, y - 1 do
			days = days + (leap(i) and 366 or 365)
		end
	else
		for i = y, 1969 do
			days = days - (leap(i) and 366 or 365)
		end
	end
	for i = 1, mon - 1 do
		days = days + mdays(y, i)
	end
	days = days + (t.day or 1) - 1

	return days * 86400 + (t.hour or 12) * 3600 + (t.min or 0) * 60 +
	    (t.sec or 0)
end

local WDAY = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
    "Friday", "Saturday" }
local MONTH = { "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December" }

-- the strftime conversions worth having. An unknown one is left as
-- written rather than raising.
local function conv(c, d)
	if c == "Y" then return ("%04d"):format(d.year) end
	if c == "y" then return ("%02d"):format(d.year % 100) end
	if c == "m" then return ("%02d"):format(d.month) end
	if c == "d" then return ("%02d"):format(d.day) end
	if c == "H" then return ("%02d"):format(d.hour) end
	if c == "M" then return ("%02d"):format(d.min) end
	if c == "S" then return ("%02d"):format(d.sec) end
	if c == "j" then return ("%03d"):format(d.yday) end
	if c == "p" then return d.hour < 12 and "AM" or "PM" end
	if c == "I" then
		local h = d.hour % 12

		return ("%02d"):format(h == 0 and 12 or h)
	end
	if c == "A" then return WDAY[d.wday] end
	if c == "a" then return WDAY[d.wday]:sub(1, 3) end
	if c == "B" then return MONTH[d.month] end
	if c == "b" then return MONTH[d.month]:sub(1, 3) end
	if c == "F" then return ("%04d-%02d-%02d"):format(d.year, d.month, d.day) end
	if c == "T" then return ("%02d:%02d:%02d"):format(d.hour, d.min, d.sec) end
	if c == "c" then
		return ("%s %s %2d %02d:%02d:%02d %04d"):format(
		    WDAY[d.wday]:sub(1, 3), MONTH[d.month]:sub(1, 3), d.day,
		    d.hour, d.min, d.sec, d.year)
	end
	if c == "x" then return ("%02d/%02d/%02d"):format(d.month, d.day, d.year % 100) end
	if c == "X" then return ("%02d:%02d:%02d"):format(d.hour, d.min, d.sec) end
	if c == "%" then return "%" end
	return "%" .. c
end

-- os.date's signature, except that `when` is required: a library cannot
-- know the time, and zero would print 1970 for an unset clock. Whoever
-- binds this as os.date supplies the default.
-- A leading "!" is UTC, which is all there is. "*t" gives the table.
function M.date(fmt, when)
	fmt = fmt or "%c"
	if type(when) ~= "number" then
		error("time.date: no time given", 2)
	end
	if fmt:sub(1, 1) == "!" then
		fmt = fmt:sub(2)
	end

	local d = M.utc(when)

	if fmt == "*t" or fmt == "!*t" then
		return d
	end
	return (fmt:gsub("%%(.)", function(c) return conv(c, d) end))
end

return M
