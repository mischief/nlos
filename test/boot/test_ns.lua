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
local chan = require("chan")
local ns = require("ns")
local espfs = require("espfs")
local tap = require("tap")

tap.plan(58)

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
-- "mnt" is here because /mnt/other is mounted below it, not because the
-- backend serving / has any such directory -- see NS:mountpoints
tap.is(table.concat(names, ","), "hello.txt,made.txt,mnt,sub",
    "readdir lists the root mount's entries plus visible mount points")

-- ---- mount points are visible in their parent ----
--
-- mounting at /mnt/other creates nothing on the backend serving /, so
-- without the namespace contributing the name, `ls /` would not show mnt
-- even though `cd /mnt/other` worked. plan 9 sidesteps this by only
-- letting you mount onto an existing directory -- its root is devroot,
-- a real device with a built-in Dirtab. ours is derived from the mount
-- table, so dynamic mounts appear on their own.
local mntents = {}

for _, e in ipairs(N:readdir("/mnt") or {}) do
	mntents[e.name] = e
end
tap.ok(mntents["other"] ~= nil, "/mnt lists the mount below it")

local mst = N:stat("/mnt")

tap.ok(mst ~= nil and mst.dir,
    "an intermediate path with mounts below it stats as a directory")

-- ---- unions: several backends at one prefix ----
local U = ns.new()

U:mount("/", dev.mem({ a = "from first\n", shared = "first wins\n" }))
U:mount("/", dev.mem({ b = "from second\n", shared = "second loses\n" }),
    nil, nil, "after")

local unames = {}

for _, e in ipairs(U:readdir("/") or {}) do
	unames[#unames + 1] = e.name
end
table.sort(unames)
tap.is(table.concat(unames, ","), "a,b,shared",
    "readdir unions both backends at the prefix")

tap.is(U:readfile("/a"), "from first\n", "a file from the first member")
tap.is(U:readfile("/b"), "from second\n",
    "walk falls through to the second when the first lacks it")
tap.is(U:readfile("/shared"), "first wins\n",
    "on a duplicate name the earlier member wins")

-- "before" puts a backend ahead of what is already there
U:mount("/", dev.mem({ shared = "jumped the queue\n" }), nil, nil, "before")
tap.is(U:readfile("/shared"), "jumped the queue\n",
    "mounting before takes precedence")

-- "replace" evicts the whole union at that prefix
U:mount("/", dev.mem({ only = "alone\n" }))
local ronly = {}

for _, e in ipairs(U:readdir("/") or {}) do
	ronly[#ronly + 1] = e.name
end
tap.is(table.concat(ronly, ","), "only",
    "replace evicts every member at the prefix")
tap.ok(U:readfile("/a") == nil, "and the evicted members are gone")

-- ---- a namespace is inherited as a capability ----
-- describe() produces plain data, so it crosses a port; the child
-- rebuilds it from its own registry. a proc never told how to build a
-- kind cannot be handed one.
local espcaps = sys.granted()

-- the ESP as a MOUNT, not a local espfs. a child cannot rebuild espfs
-- any more -- los.fs belongs to the esp server task alone -- so what
-- describe() must hand it is a right to that server. see lib/espsrv.lua.
local parent = ns.new()

parent:mount("/", require("mnt").new(espcaps.esp), "mnt",
    { port = { __right = espcaps.esp } })
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
    "child read a real ESP file through its inherited esp mount")
tap.is(got.note, "in memory",
    "child read the mem mount, whose tree travelled as plain data")

-- a kind the child does not know about cannot be restored
local bad, berr = ns.restore({ { prefix = "/x", kind = "nosuchkind" } })

tap.ok(bad == nil and tostring(berr):find("unknown backend kind") ~= nil,
    "restoring an unregistered kind fails: " .. tostring(berr))

-- ---- Chans carry the name they were reached by ----
--
-- lib/chan.lua's whole argument. the name is the CALLER's cleaned path,
-- never anything the backend reports: a backend has no idea what prefix
-- it was mounted at, and /mnt/other/hello.txt is "hello.txt" to the
-- dev.mem serving it.

do
	local c <close> = assert(N:open("/mnt/other/hello.txt"))

	tap.is(c.path, "/mnt/other/hello.txt",
	    "a Chan carries the name it was opened by, mount prefix and all")
	tap.ok(chan.is(c), "and it really is a Chan")
end

do
	local c <close> = assert(N:open("/sub/.././sub//deep.txt"))

	tap.is(c.path, "/sub/deep.txt",
	    "the Cname is the CLEANED name, folded lexically: " .. c.path)
end

-- a Chan from walk() has it too, not just an opened one
tap.is(N:walk("/mnt/other").path, "/mnt/other",
    "walk() returns a named Chan")

-- ---- the namespace's cached mount root is not the caller's to close ----
--
-- ns caches one Chan per mount to walk from. dev.mem and espfs both
-- return the SAME handle table from open() on a directory, so if a
-- lookup of the mount point itself handed back that cached root, this
-- close would clunk it and every later lookup through the mount would
-- be using a released handle.

do
	local d <close> = assert(N:open("/mnt/other", "r"))

	tap.ok(d ~= nil, "the mount point itself opens")
end

tap.is(N:readfile("/mnt/other/hello.txt"), "from the other mount\n",
    "the mount still works after its own root was opened and closed")

-- unmounting releases the cached root, and remounting builds a new one
tap.ok(N:unmount("/mnt/other"), "unmount drops the mount and its root")
tap.ok(N:readfile("/mnt/other/hello.txt") == nil,
    "the path is gone once unmounted")
tap.ok(N:mount("/mnt/other", dev.mem({ ["hello.txt"] = "second time\n" })),
    "remounting at the same prefix succeeds")
tap.is(N:readfile("/mnt/other/hello.txt"), "second time\n",
    "and resolves through a freshly attached root")

-- ---- require() resolves through the namespace ----
--
-- the point of ns.adopt: a program's CODE comes from its own namespace.
-- proved by unioning a synthetic /lib in FRONT of the real one and
-- requiring a module that exists nowhere on the ESP, then requiring a
-- real one to show the union falls through.
--
-- note what this does NOT prove: that a module absent from the
-- namespace is unreachable. the stock LUA_PATH searcher is still behind
-- ours as the bootstrap fallback, so ambient /lib is still findable.
-- closing that is a separate change -- it means removing raw ESP access
-- from ordinary procs, which cannot happen until require no longer
-- needs it.

local R = ns.new()

R:mount("/", require("mnt").new(espcaps.esp), "mnt",
    { port = { __right = espcaps.esp } })
R:mount("/", dev.mem({
	lib = {
		["synthetic.lua"] =
		    "return { origin = 'from the namespace' }\n",
	},
}), "mem", {
	tree = {
		lib = {
			["synthetic.lua"] =
			    "return { origin = 'from the namespace' }\n",
		},
	},
}, "before")

local reqport = sys.newport()

local desc = R:describe()

-- proc.spawn adopts for us: the chunk below never mentions the
-- namespace and still resolves every require through it. that is the
-- point -- adopting by hand was optional boilerplate, and a chunk that
-- forgot it silently fell back to the ambient searcher.
require("proc").spawn([[
	local sys = require("los.sys")
	local oks, syn = pcall(require, "synthetic")
	local okt, tapmod = pcall(require, "tap")

	sys.send((...).__right, {
		syn = oks and syn.origin or ("ERR " .. tostring(syn)),
		realmod = okt and type(tapmod) or ("ERR " .. tostring(tapmod)),
		iscurrent = (require("ns").current() ~= nil),
	})
]], { name = "reqchild2", ns = desc, arg = { __right = reqport } })

local rm = thread.recvtimeout(reqport, 5000)

tap.ok(rm ~= nil, "the child answered")
tap.is(rm and rm.syn, "from the namespace",
    "require found a module that exists ONLY in the namespace")
tap.is(rm and rm.realmod, "table",
    "and fell through the union to a real module on the esp")
tap.ok(rm and rm.iscurrent,
    "proc.spawn adopted the namespace without the chunk asking")

-- ---- readfile does not ask in thimblefuls ----
--
-- The chunk readfile asks for used to be sized to a port message, which
-- was never its business: the mount drivers chunk to their own iounit
-- (see dev.readloop), so the only thing this number controls is how
-- much of a file is held at once. It was 4096, which meant a megabyte
-- cost 256 round trips through a mount for no reason.
--
-- Counted rather than timed, so this measures the thing it claims to
-- and does not depend on how fast the machine is.
local function counting(inner)
	local B, n = {}, 0

	for k, v in pairs(inner) do
		B[k] = v
	end
	B.read = function(h, off, want)
		n = n + 1
		return inner.read(h, off, want)
	end
	return B, function() return n end
end

do
	local BIG = 512 * 1024
	local body = string.rep("0123456789abcdef", BIG // 16)
	local base = dev.mem({ ["big.bin"] = body })
	local B, reads = counting(base)
	local CN = ns.new()

	tap.ok(CN:mount("/", B, "mem"), "mounted a counting backend")

	local got = CN:readfile("/big.bin")

	tap.is(got and #got, #body, "readfile returned the whole file")
	tap.ok(got == body, "and every byte of it is right")

	-- ceil(size / chunk) reads, plus the one that returns "" at eof.
	-- Derived from dev.IOUNIT, which is where readfile's chunk comes
	-- from -- asking ns for the number it used would only prove it
	-- agrees with itself.
	local want = math.ceil(#body / dev.IOUNIT) + 1

	tap.is(reads(), want,
	    "readfile issued " .. reads() .. " reads, not " ..
	    (math.ceil(#body / 4096) + 1))

	-- the old number, stated so a regression to it is unmistakable
	tap.ok(reads() < math.ceil(#body / 4096) + 1,
	    "which is fewer than a 4096-byte chunk would have taken")
end

tap.done()
