-- /srv: naming a right, and mounting what the name refers to.
--
-- The thing being proved is that a capability survives the round trip
-- through a name. Everything else here already worked: what did not
-- exist was any way to say which server you meant without already
-- holding a right to it, which is what made `mount` impossible at a
-- prompt.

local sys = require("los.sys")
local tap = require("tap")
local ns = require("ns")
local mnt = require("mnt")
local srvc = require("srvc")
local srvfs = require("srvfs")

tap.plan(28)

-- a boot payload has no namespace of its own, so read the registry's
-- source through the C loader rather than through a mount. Dumped
-- because sys.spawn takes a chunk and luaL_loadbuffer accepts either
-- form.
local srvd = select(2, sys.spawn(
    string.dump(assert(loadfile("/task/srvd.lua"))), { name = "srvtest" }))

tap.ok(srvd ~= nil, "srvd starts")

-- ---- a memfs to publish ----
local server = select(2, sys.spawn([[
	local a = ...
	local dev = require("dev")
	local devtree = require("devtree")
	local srv = require("srv")

	srv.main(function()
		return devtree.mem({ ["hello"] = "from the named server\n" })
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

-- reading a name yields a right, as a decimal handle valid in this
-- proc alone. Every read acquires a fresh one, exactly as every open of a
-- Plan 9 /srv file gets its own Chan reference -- so a caller that
-- reads and does not mount owns a handle it should close.
local h1 = tonumber((S:readfile("/srv/mem"):gsub("%s+$", "")))

tap.ok(h1 ~= nil, "reading a /srv entry yields a handle")

local h2 = tonumber((S:readfile("/srv/mem"):gsub("%s+$", "")))

tap.ok(h2 ~= nil and h2 ~= h1, "and each read yields its own")
sys.close(h1)
sys.close(h2)

-- ---- the namespace carries capabilities after all ----
--
-- Plan 9 posts a server by writing a decimal file descriptor to
-- /srv/name: devsrv resolves it against the calling proc's fd table and
-- adopts the Chan. The bytes name a capability the kernel already holds
-- for the caller rather than carrying one.
--
-- The same works here, for the same reason: a right handle is
-- proc-local like an fd, and a local backend runs in the caller's proc,
-- so it can resolve the number where the number means something.
local W = ns.new()

W:mount("/srv", srvfs.new(srvd), "srvfs", { port = { __right = srvd } })

local second = select(2, sys.spawn([[
	local dev = require("dev")
	local devtree = require("devtree")
	local srv = require("srv")

	srv.main(function()
		return devtree.mem({ ["hello"] = "posted by writing a handle\n" })
	end)
]], { name = "memsrv2" }))

local wh = sys.sendright(second)
local wrote, werr = W:writefile("/srv/second", tostring(wh))

tap.ok(wrote, "post by writing a handle to /srv: " .. tostring(werr))

-- and it is a real posting: another proc's registry now has it
local names2 = srvc.list(srvd)
local sawsecond = false

for _, n in ipairs(names2) do
	if n == "second" then
		sawsecond = true
	end
end
tap.ok(sawsecond, "the registry really holds what was written")

-- reading it back gives a handle valid in this proc, the other half
local text = W:readfile("/srv/second")
local got = tonumber((tostring(text):gsub("%s+$", "")))

tap.ok(got ~= nil, "reading /srv/second gives a handle: " .. tostring(text))

local W2 = ns.new()
local m2ok = W2:mount("/n", mnt.new(got), "mnt", { port = { __right = got } })

tap.ok(m2ok, "and that handle is a right this proc can mount")
tap.is(W2:readfile("/n/hello"), "posted by writing a handle\n",
    "the tree it names answers")

-- a number that is not a right here must be refused, not adopted
local bad = W:writefile("/srv/nope", "999999")

tap.ok(not bad, "writing a handle that names nothing is refused")

-- ---- inheritance ----
-- a namespace holding /srv must survive describe/adopt, or every child
-- of the proc that mounted it dies on "unknown backend kind". Building
-- namespaces directly, as the tests above do, never exercises that --
-- and the real init.lua does nothing else, so this is the path that
-- actually runs.
local S2 = ns.new()

S2:mount("/srv", srvfs.new(srvd), "srvfs", { port = { __right = srvd } })

local adopted, aerr = ns.adopt(S2:describe())

tap.ok(adopted ~= nil, "a namespace with /srv can be adopted: " ..
    tostring(aerr))

local ah = adopted and
    tonumber((tostring(adopted:readfile("/srv/mem")):gsub("%s+$", "")))

tap.ok(ah ~= nil, "and /srv still yields a right after the trip")
if ah then
	sys.close(ah)
end

-- ---- remove ----
tap.ok(srvc.remove(srvd, "mem"), "remove the name")

local left = srvc.list(srvd)

-- "second", posted by writing a handle above, is the one still there
tap.is(table.concat(left, ","), "second",
    "and it is gone from the listing")
tap.ok(select(2, srvc.open(srvd, "mem")) ~= nil,
    "opening a removed name fails")

tap.done()
