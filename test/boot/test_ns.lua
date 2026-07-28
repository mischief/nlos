-- ns.lua: names to backends.
--
-- the three things worth proving: longest-prefix resolution actually
-- routes to the right backend, ".." is resolved lexically so it cannot
-- escape a mount, and a namespace survives being described and rebuilt
-- in another proc -- which is what makes it a capability rather than a
-- global.
local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local ns = require("ns")
local espfs = require("espfs")
local tap = require("tap")

tap.plan(30)

-- ---- path cleaning, before any backend is involved ----
tap.is(ns.clean("/a/b/../c"), "/a/c", "clean resolves ..")
tap.is(ns.clean("/a/./b"), "/a/b", "clean drops .")
tap.is(ns.clean("/a//b"), "/a/b", "clean collapses empty elements")
tap.is(ns.clean("/"), "/", "clean of root is root")
tap.is(ns.clean("/.."), "/", "cannot climb above root")
tap.is(ns.clean("/a/../../.."), "/", "cannot climb past root by repeating")

-- ---- a two-mount namespace ----
local N = ns.new()

tap.ok(N:mount("/", dev.mem({
	["hello.txt"] = "from root\n",
	sub = { ["deep.txt"] = "deeper\n" },
})), "mount / succeeds")

tap.ok(N:mount("/mnt/other", dev.mem({
	["hello.txt"] = "from the other mount\n",
})), "mount /mnt/other succeeds")

-- longest prefix wins: the same filename resolves differently
tap.is(N:readfile("/hello.txt"), "from root\n", "/hello.txt hits the root mount")
tap.is(N:readfile("/mnt/other/hello.txt"), "from the other mount\n",
    "/mnt/other/hello.txt hits the longer prefix")
tap.is(N:readfile("/sub/deep.txt"), "deeper\n", "nested path in the root mount")

-- ".." is lexical, so it crosses back out of a mount rather than asking
-- the mounted backend about its parent
tap.is(N:readfile("/mnt/other/../../hello.txt"), "from root\n",
    ".. climbs out of a mount into the mounting namespace")

-- ---- errors come back as values at this layer ----
local miss, merr = N:open("/nope.txt")

tap.ok(miss == nil and type(merr) == "string",
    "open of a missing file returns nil + reason")
tap.ok(tostring(merr):find(dev.Enonexist, 1, true) ~= nil,
    "and the reason is the backend's own Enonexist: " .. tostring(merr))
tap.ok(tostring(merr):find("%.lua:%d") == nil,
    "with no lua position prefix")

local nomount = ns.new():stat("/anything")

tap.ok(nomount == nil, "an empty namespace resolves nothing")

-- ---- the File object: position, seek, <close> ----
local f = N:open("/hello.txt")

tap.ok(f ~= nil, "open returns a file")
tap.is(f:read(4), "from", "read advances from position 0")
tap.is(f:read(5), " root", "the position carried over")
tap.is(f:seek("set", 0), 0, "seek set returns the new position")
tap.is(f:read(4), "from", "and reading starts over")
f:close()
tap.ok(select(1, f:read(1)) == nil, "reading a closed file fails cleanly")

-- ---- write, create, readdir ----
tap.ok(N:writefile("/made.txt", "written by ns") == 13,
    "writefile creates and writes")
tap.is(N:readfile("/made.txt"), "written by ns", "and it reads back")

local ents = N:readdir("/")
local names = {}

for _, e in ipairs(ents or {}) do
	names[#names + 1] = e.name
end
table.sort(names)
tap.is(table.concat(names, ","), "hello.txt,made.txt,sub",
    "readdir lists the root mount's entries")

-- ---- a namespace is inherited as a capability ----
-- describe() produces plain data, so it crosses a port; the child
-- rebuilds it from its own registry. a proc never told how to build a
-- kind cannot be handed one.
local parent = ns.new()

parent:mount("/", espfs.new("/"), "espfs", { root = "/" })
parent:mount("/tmp", dev.mem({ note = "in memory" }), "mem",
    { tree = { note = "in memory" } })

local desc = parent:describe()

tap.is(#desc, 2, "describe covers both mounts")

local pid, h = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local ns = require("ns")
	local m = thread.recv(sys.SELF)
	local N = ns.restore(m.nsdesc)
	local reply = m.reply.__right

	if not N then
		sys.send(reply, { err = "restore failed" })
		return
	end
	-- prove both mounts work in the child: one real file off the esp,
	-- one from the in-memory tree that travelled as data
	local init = N:readfile("/init.lua")
	local note = N:readfile("/tmp/note")

	sys.send(reply, {
		initlen = init and #init or 0,
		note = note,
	})
]], { name = "nschild" })

local rp = sys.newport()

sys.send(h, { nsdesc = desc, reply = { __right = rp } })

local got = thread.recv(rp)

tap.ok(got.err == nil, "child rebuilt the namespace (" ..
    tostring(got.err) .. ")")
tap.ok((got.initlen or 0) > 0,
    "child read a real ESP file through its inherited espfs mount")
tap.is(got.note, "in memory",
    "child read the mem mount, whose tree travelled as plain data")

-- a kind the child does not know about cannot be restored
local bad, berr = ns.restore({ { prefix = "/x", kind = "nosuchkind" } })

tap.ok(bad == nil and tostring(berr):find("unknown backend kind") ~= nil,
    "restoring an unregistered kind fails: " .. tostring(berr))

tap.done()
