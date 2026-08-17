-- balltest: name the buttons in each pointer record.
--
--	> balltest [SECONDS]
--
-- Motion with no buttons is not printed: it is most of the records.

local prog = require("prog")
local mouse = require("mouse")
local sys = require("los.sys")
local unistd = require("posix.unistd")

local m = prog.mouse()

if not m then
	io.stderr:write("balltest: no pointer here\n")
	os.exit(1)
end

local NAME = {
	[1] = "button1", [2] = "button2", [4] = "button3",
	[mouse.WHEELUP] = "up", [mouse.WHEELDOWN] = "down",
	[mouse.WHEELLEFT] = "left", [mouse.WHEELRIGHT] = "right",
}

local function name(b)
	local out = {}

	for bit = 0, 7 do
		local v = 1 << bit

		if (b & v) ~= 0 then
			out[#out + 1] = NAME[v] or ("bit" .. v)
		end
	end
	if #out == 0 then
		return "none"
	end
	return table.concat(out, "+")
end

local secs = tonumber(arg[1] or "") or 20
local stop = sys.uptime_ms() + secs * 1000

unistd.write(1, ("roll the ball: %d seconds\n"):format(secs))

while sys.uptime_ms() < stop do
	local x, y, b = m.read()

	if not x then
		break
	end
	if b ~= 0 then
		local s = ("%4d %4d  %3d  %s\n"):format(x, y, b, name(b))

		unistd.write(1, s)
		sys.log("balltest: " .. b .. " " .. name(b))
	end
end
