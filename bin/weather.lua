-- weather: what it is doing outside. With no place, wherever the
-- network says this machine is.
--
--   > weather [-1] [Portland | 94107 | muc | 37.77,-122.4]

-- The fetch is lib/weather.lua, so the panel and this print the same
-- reading. What this holds is the network the shell lent it, and it
-- says which piece is missing rather than failing further in.

local prog = require("prog")
local getopt = require("getopt")
local weather = require("weather")

local function die(s)
	io.stderr:write("weather: " .. s .. "\n")
	os.exit(1)
end

local flags, optind = getopt.parse(arg, "1")

if not flags then
	io.stderr:write("usage: weather [-1] [place]\n")
	os.exit(2)
end

local oneline = flags["1"]
local where

for i = optind, #arg do
	where = where and (where .. "+" .. arg[i]) or arg[i]
end

local net = prog.net()

if not net then
	die("no network capability: this shell was lent none")
end

local rand = prog.rand()

if not rand then
	die("no entropy: this shell was lent no seed, and https needs one")
end

local w, err = weather.get({
	net = net,
	dns = prog.dns(),
	rand = rand,
	where = where,
})

if not w then
	die(tostring(err))
end

if oneline then
	io.write(("%s: %s %s\n"):format(w.place, w.cond, w.temp))
	os.exit(0)
end

-- the place first and on its own line: with no argument it is the
-- network's guess at where this machine is, which is worth reading
-- rather than assuming.
io.write(w.place .. "\n")

local rows = {
	{ "condition", w.cond },
	{ "temperature", w.temp .. " (feels " .. w.feels .. ")" },
	{ "humidity", w.humidity },
	{ "wind", w.wind },
	{ "pressure", w.pressure },
	{ "precipitation", w.precip },
}

for _, r in ipairs(rows) do
	if r[2] and r[2] ~= "" then
		io.write(("  %-14s %s\n"):format(r[1], r[2]))
	end
end
