-- /srv: naming a right, and mounting what the name refers to.
--
-- The thing being proved is that a capability survives the round trip
-- through a NAME. Everything else here already worked: what did not
-- exist was any way to say which server you meant without already
-- holding a right to it, which is what made `mount` impossible at a
-- prompt.

local sys = require("los.sys")
local tap = require("tap")
local ns = require("ns")
local mnt = require("mnt")
local srvc = require("srvc")
local srvfs = require("srvfs")

tap.plan(19)

-- a boot payload has no namespace of its own, so read the registry's
-- source through the C loader rather than through a mount. Dumped
-- because sys.spawn takes a chunk and luaL_loadbuffer accepts either
-- form.
local srvd = select(2, sys.spawn(
    string.dump(assert(loadfile("/lib/srvd.lua"))), { name = "srvtest" }))

tap.ok(srvd ~= nil, "srvd starts")

-- ---- a memfs to publish ----
local server = select(2, sys.spawn([[
	local a = ...
	local dev = require("dev")
	local srv = require("srv")

	srv.main(function()
		return dev.mem({ ["hello"] = "from the named server\n" })
	end)
]], { name = "memsrv" }))

tap.ok(server ~= nil, "a server to publish")

-- ---- post ----
tap.ok(srvc.post(srvd, "mem", sys.sendright(server)), "post a right by name")

local names = srvc.list(srvd)

tap.is(#names, 1, "one name posted")
tap.is(names[1], "mem", "and it is the one posted")

tap.ok(not srvc.post(srvd, "mem", sys.sendright(server)),
    "posting the same name twice is refused")
tap.ok(not srvc.post(srvd, "a/b", sys.sendright(server)),
    "a name with a slash is refused, since /srv walks it as one element")
tap.ok(not srvc.post(srvd, "", sys.sendright(server)),
    "an empty name is refused")

-- ---- open ----
local right, err = srvc.open(srvd, "mem")

tap.ok(right ~= nil, "open the name -> a right: " .. tostring(err))
tap.ok(select(2, srvc.open(srvd, "nope")) ~= nil,
    "opening an unposted name fails")

-- each open is its own send-right, so one client clunking cannot
-- disturb another
local right2 = srvc.open(srvd, "mem")

tap.ok(right2 ~= nil and right2 ~= right,
    "two opens give two distinct handles")

-- ---- the point: mount what the name named ----
local M = ns.new()
local mok, merr = M:mount("/n", mnt.new(right), "mnt",
    { port = { __right = right } })

tap.ok(mok, "mount the right that came from a name: " .. tostring(merr))
tap.is(M:readfile("/n/hello"), "from the named server\n",
    "and the mounted server answers")

-- ---- /srv as a directory ----
local S = ns.new()

tap.ok(S:mount("/srv", srvfs.new(srvd), "srvfs"), "srvfs mounts")

local ents = S:readdir("/srv")
local found = false

for _, e in ipairs(ents or {}) do
	if e.name == "mem" then
		found = true
	end
end
tap.ok(found, "ls /srv shows the posted name")

-- reading a name gives text, NOT the right. This is the honest shape,
-- not an omission: a capability does not fit in a byte stream.
tap.is(S:readfile("/srv/mem"), "mem\n",
    "reading a /srv entry gives a name, not a capability")

-- ---- remove ----
tap.ok(srvc.remove(srvd, "mem"), "remove the name")
tap.is(#srvc.list(srvd), 0, "and it is gone from the listing")
tap.ok(select(2, srvc.open(srvd, "mem")) ~= nil,
    "opening a removed name fails")

tap.done()
