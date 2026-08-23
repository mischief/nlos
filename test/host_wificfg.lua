#!/usr/bin/env lua5.4
-- lib/wificfg.lua, the known networks, on the host. No radio in it:
-- what a scan saw is a table the test wrote.
-- TAP direct: lib/tap.lua needs los.sys.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local cfg = require("wificfg")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
end

local function is(got, want, name)
	ok(got == want, ("%s (got %s, want %s)"):format(name, tostring(got),
	    tostring(want)))
end

local function names(list)
	local out = {}

	for i, n in ipairs(list) do
		out[i] = n.ssid
	end
	return table.concat(out, ",")
end

-- ---- reading ----

local one = cfg.parse('return { ssid = "home", psk = "sekrit" }')

is(#one, 1, "a config naming one network is one network")
is(one[1].ssid, "home", "and its ssid is read")
is(one[1].psk, "sekrit", "and its key")

local many = cfg.parse([[return { networks = {
	{ ssid = "home", psk = "a" },
	{ ssid = "phone", psk = "b" },
	{ ssid = "cafe" },
} }]])

is(names(many), "home,phone,cafe", "a list is read in order")
is(many[3].psk, nil, "an open network has no key")

is(#cfg.parse("this is not lua"), 0, "a config that does not parse is none")
is(#cfg.parse("return 7"), 0, "nor is one that is not a table")
is(#cfg.parse(nil), 0, "nor is nothing at all")
is(#cfg.parse('return { networks = { { psk = "x" } } }'), 0,
    "an entry with no ssid is not a network")

-- ---- choosing ----
--
-- Config order is preference, so a weaker network named first still
-- wins: the loudest radio in the room is not the wanted one.

local seen = {
	{ ssid = "phone", rssi = -30 },
	{ ssid = "home", rssi = -70 },
}

is(cfg.pick(many, seen).ssid, "home", "the first known one in range wins")
is(select(2, cfg.pick(many, seen)), -70, "and its signal comes back")
is(cfg.pick(many, { { ssid = "phone", rssi = -30 } }).ssid, "phone",
    "the next one down is taken when the first is absent")
is(cfg.pick(many, { { ssid = "elsewhere", rssi = -20 } }), nil,
    "an unknown network is not joined")
is(cfg.pick(many, {}), nil, "and neither is an empty scan")
is(cfg.pick({}, seen), nil, "a machine that knows none joins none")

-- the same ssid twice in a scan is two access points on one network:
-- the stronger is what it reports.
is(select(2, cfg.pick(many, {
	{ ssid = "home", rssi = -80 },
	{ ssid = "home", rssi = -40 },
})), -40, "two access points on one name report the stronger")

-- ---- writing ----

local list = cfg.remember(many, "cafe", "newkey")

is(names(list), "cafe,home,phone", "joining one makes it preferred")
is(list[1].psk, "newkey", "with the key just given")
is(#list, 3, "and it is not listed twice")

is(names(cfg.remember({}, "first")), "first",
    "the first network remembered is the list")

-- an empty answer to a passphrase prompt is "as before". Overwriting
-- here loses the credential and the link together, leaving nothing to
-- reconnect with -- which is what makes it worse than refusing.
is(cfg.remember(many, "home", nil)[1].psk, "a",
    "no passphrase keeps the saved one")
is(cfg.remember(many, "home", "")[1].psk, "a",
    "and so does an empty one")
is(cfg.remember(many, "new", nil)[1].psk, nil,
    "but a network not known stays open")
is(names(cfg.forget(list, "home")), "cafe,phone", "forgetting drops one")
is(names(cfg.forget(list, "nowhere")), "cafe,home,phone",
    "and forgetting what is not there changes nothing")

-- what is written must read back the same, or a machine loses its
-- network the next time it boots.
local round = cfg.parse(cfg.format(list))

is(names(round), names(list), "a written config reads back")
is(round[1].psk, "newkey", "keys survive the round trip")
is(round[3].psk, "b", "and so do the ones further down")

local odd = cfg.parse(cfg.format({
	{ ssid = 'quote"and\\slash', psk = "x" },
}))

is(odd[1].ssid, 'quote"and\\slash', "a quote in an ssid survives")

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
