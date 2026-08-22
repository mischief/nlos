#!/usr/bin/env lua5.4
-- lib/audio: which device the samples go to, and what asking costs.
--
-- Starting the USB host is one way, and on a board whose console
-- shares that port the console is gone until the next boot. So listing
-- the sinks must not call it, and a stub that raises is the only way
-- to tell a query from an act.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local n, fails = 0, 0

local function ok(cond, name)
	n = n + 1
	if cond then
		print(string.format("ok %d - %s", n, name))
	else
		fails = fails + 1
		print(string.format("not ok %d - %s", n, name))
	end
end

-- the machine, as lib/audio sees it: an amplifier, a usb controller
-- that must not be started, and a config file in memory.
local started = false
local conf = nil

package.loaded["los.sys"] = {
	i2shave = function() return true end,
	usbhave = function() return true end,
	usbhost = function()
		started = true
		error("usbhost started the controller", 0)
	end,
	usbconsole = function() return true end,
	uptime_ms = function() return 0 end,
	i2splay = function() return true end,
	i2swrite = function(s) return #s end,
	i2sstop = function() end,
	i2sunderruns = function() return 0 end,
}
package.loaded["los.thread"] = { sleep = function() end }

local audio = require("audio")

-- io.open, so the setting is a file this test owns
local realopen = io.open

io.open = function(path, mode)
	if path ~= audio.CONF then
		return realopen(path, mode)
	end
	if (mode or "r"):find("w") then
		conf = ""
		return {
			write = function(_, ...)
				for _, s in ipairs({ ... }) do
					conf = conf .. tostring(s)
				end
			end,
			close = function() end,
		}
	end
	if not conf then
		return nil, "no such file"
	end

	local rest = conf

	local function nextline()
		if rest == "" then
			return nil
		end

		local at = rest:find("\n", 1, true)

		if not at then
			local all = rest

			rest = ""
			return all
		end

		local l = rest:sub(1, at - 1)

		rest = rest:sub(at + 1)
		return l
	end

	return {
		read = function(_, fmt)
			if fmt == "a" then
				local all = rest

				rest = ""
				return all
			end
			return nextline()
		end,
		lines = function()
			return nextline
		end,
		close = function() end,
	}
end

-- ---- listing must not start anything ----

local sinks = audio.sinks()
local names = table.concat(sinks, ",")

ok(not started, "sinks() does not start the usb host to list it")
ok(names:find("i2s") ~= nil, "the amplifier is listed: " .. names)
ok(names:find("usb") ~= nil, "so is the port, without claiming it")

-- ---- the setting round trips ----

ok(audio.sink() == "auto", "no file means auto")
ok(audio.setsink("i2s") == true, "a sink can be chosen")
ok(audio.sink() == "i2s", "and is remembered")
ok(select(1, audio.setsink("nonsense")) == nil, "a name that is not a sink is refused")

-- ---- auto, where the port is also the console ----
--
-- The amplifier answers, so nothing should reach for the port. It
-- raises if anything does.

conf = "auto\n"

local dev, why = audio.open(48000, 2, 16)

ok(dev ~= nil and dev.kind == "i2s",
    "auto takes the amplifier: " .. tostring(dev and dev.kind or why))
ok(not started, "and does not touch the console's port on the way")

-- ---- the volume ----

conf = nil
ok(audio.volume() == 100, "no setting means full volume")
audio.setsink("i2s")
ok(audio.setvolume(40) == true, "the volume can be set")
ok(audio.volume() == 40, "and is remembered")
ok(audio.sink() == "i2s", "without disturbing the sink beside it")
audio.setvolume(500)
ok(audio.volume() == 100, "a volume above the scale is clamped to it")
audio.setvolume(-10)
ok(audio.volume() == 0, "and below it to zero")

-- the cycle a tap walks: whole fifths, wrapping at the top, and an
-- odd value rounds onto them rather than carrying its offset around
local step = {}
local v = 0

for _ = 1, 6 do
	step[#step + 1] = v
	v = audio.nextvolume(v)
end
ok(table.concat(step, ",") == "0,20,40,60,80,100",
    "the volume cycles in fifths: " .. table.concat(step, ","))
ok(audio.nextvolume(100) == 0, "and wraps at the top")
ok(audio.nextvolume(25) == 40, "an odd value rounds onto the steps")

-- silence is what a caller asked for, not something to skip
local loud = string.pack("<i2i2i2", 20000, -20000, 0)

ok(audio.gain(loud, 0) == string.pack("<i2i2i2", 0, 0, 0),
    "zero gain is silence")
ok(audio.gain(loud, 256) == loud, "full gain is the samples untouched")
ok(audio.gain(loud, 128) == string.pack("<i2i2i2", 10000, -10000, 0),
    "half gain halves them")

-- a q that would take a sample past the end of the range
local peak = string.pack("<i2i2", 32000, -32000)
local hot = audio.gain(peak, 512)
local a, b = string.unpack("<i2i2", hot)

ok(a == 32767 and b == -32768, "amplification clamps instead of wrapping")

-- an odd tail is half a sample: a chunk boundary, not something to
-- scale or to drop
local odd = loud .. "\x7f"

ok(#audio.gain(odd, 128) == #odd, "an odd trailing byte survives")

print("1.." .. n)
os.exit(fails == 0 and 0 or 1)
