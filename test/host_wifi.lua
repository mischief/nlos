#!/usr/bin/env lua5.4
-- lib/wifi's parsing, against a namespace made of strings.
--
-- The format is task/wifisrv.lua's, and both faces read it through
-- here, so a change to either file cannot drift from the other.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local wifi = require("wifi")

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

-- a namespace of canned files, which is all lib/wifi asks for
local function fakens(files)
	return {
		stat = function(_, p) return files[p] ~= nil end,
		readfile = function(_, p) return files[p] end,
		writefile = function(_, p, data)
			files.written = { path = p, data = data }
			return true
		end,
	}
end

ok(wifi.new(nil) == nil, "no namespace means no radio")
ok(wifi.new(fakens({})) == nil, "and neither does a namespace without one")

local W = wifi.new(fakens({
	["/net/wifi/ctl"] = "",
	["/net/wifi/status"] = "state joined\nssid labratory\nreason 0\n",
	["/net/wifi/scan"] = "-58 psk labratory\n-71 open guest wifi\n",
	["/net/wifi/known"] = "psk labratory\nopen guest wifi\n",
}))

ok(W ~= nil, "a namespace with /net/wifi/ctl has one")

local st = W:status()

ok(st.state == "joined" and st.ssid == "labratory",
    "status reports the state and the network")

local aps = W:scan()

ok(#aps == 2, "a scan lists what is in range")
ok(aps[1].ssid == "labratory" and aps[1].rssi == -58 and not aps[1].open,
    "with its strength and whether it is open")
ok(aps[2].ssid == "guest wifi" and aps[2].open,
    "and an ssid holding a space survives")

-- the divergence this module exists to end: a scan that could not run
-- answers with a reason, and a reader that drops it shows an empty
-- list, which reads as nothing being out there.
local busy = wifi.new(fakens({
	["/net/wifi/ctl"] = "",
	["/net/wifi/scan"] = "-- another scan is running\n",
}))

local none, why = busy:scan()

ok(none == nil and why == "another scan is running",
    "a refused scan says why rather than looking empty")

local saved = W:known()

ok(#saved == 2 and saved[1].ssid == "labratory" and not saved[1].open,
    "known lists what is saved, best first")

-- one field a line, so a passphrase may hold spaces
local files = {
	["/net/wifi/ctl"] = "",
}
local J = wifi.new(fakens(files))

J:join("labratory", "a pass phrase")
ok(files.written.data == "join\nlabratory\na pass phrase\n",
    "join writes one field a line")

J:join("guest wifi")
ok(files.written.data == "join\nguest wifi\n\n",
    "an open network joins with an empty passphrase")

J:forget("labratory")
ok(files.written.data == "forget\nlabratory\n", "and forget names one")

print("1.." .. n)
os.exit(fails == 0 and 0 or 1)
