-- nsfs: an arbitrarily constructed namespace, exported and read back.
--
-- This is plan 9's split made concrete: build a namespace by mounting
-- whatever you like into it, wrap it as one backend with nsfs, serve it
-- with p9serve, and mount it back with p9fs -- all in this one proc, no
-- wire. The point being proven is that the export is of a NAMESPACE, not
-- a filesystem: two unrelated trees mounted at two points come out as one
-- tree, and a rooted export hands out only a subtree (exportfs -r).

local ns = require("ns")
local dev = require("dev")
local devtree = require("devtree")
local nsfs = require("nsfs")
local p9serve = require("p9serve")
local p9fs = require("p9fs")
local tap = require("tap")

tap.plan(7)

-- construct a namespace: two in-memory trees, mounted at two points
local N = ns.new()
N:mount("/a", devtree.mem({ hello = "from a\n",
    sub = { deep = "nested\n" } }), "mem")
N:mount("/b", devtree.mem({ world = "from b\n" }), "mem")

-- export a subtree of N over 9P, mount it back with p9fs (loopback), and
-- hand the client namespace back for readfile/readdir
local function mounted(root)
	local respond = p9serve.responder(nsfs.new(N, root))
	local cn = ns.new()
	cn:mount("/", p9fs.new({ rpc = function(r) return respond(r) end }),
	    "mnt")
	return cn
end

-- the whole namespace: both trees are one tree over the export
local whole = mounted("/")
tap.ok(whole:readfile("/a/hello") == "from a\n",
    "whole export: /a/hello reads through")
tap.ok(whole:readfile("/b/world") == "from b\n",
    "whole export: /b/world, a different mount, reads through")
tap.ok(whole:readfile("/a/sub/deep") == "nested\n",
    "whole export: a nested file reads through")

local names = {}
for _, e in ipairs(whole:readdir("/") or {}) do names[e.name] = true end
tap.ok(names.a and names.b, "whole export: / lists both mounts")

-- rooted at /a: only that subtree, a's hello is now the root's hello
local rooted = mounted("/a")
tap.ok(rooted:readfile("/hello") == "from a\n",
    "rooted at /a: /hello is a's hello")
tap.ok(rooted:readfile("/sub/deep") == "nested\n",
    "rooted at /a: the nested file is still reachable")

local rnames = {}
for _, e in ipairs(rooted:readdir("/") or {}) do rnames[e.name] = true end
tap.ok(rnames.hello and rnames.sub and not rnames.b and not rnames.world,
    "rooted at /a: only a's children are in the export, not b")

tap.done()
