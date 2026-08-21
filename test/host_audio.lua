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
		return {
			write = function(_, s) conf = s end,
			close = function() end,
		}
	end
	if not conf then
		return nil, "no such file"
	end
	local sent = false

	return {
		read = function()
			if sent then
				return nil
			end
			sent = true
			return (conf:gsub("\n.*", ""))
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

print("1.." .. n)
os.exit(fails == 0 and 0 or 1)
