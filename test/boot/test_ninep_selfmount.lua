-- self-mount: lib/p9fs.lua's own client talking to lib/ninep.lua's own
-- server, in one process, with no virtio-9p device (or any device at
-- all) involved -- ninep.responder(root) is the server with the byte
-- stream framing stripped off, which is exactly the shape p9fs.lua's
-- transport parameter wants (one request in, one reply out).
--
-- this is what actually exercises the base-9P2000 code path: qemu's
-- virtio-9p only ever negotiates .u, so the mount tests that go
-- through real hardware can't prove p9fs.lua works against a server
-- that doesn't speak .u at all. M.serve is exactly such a server (no
-- n_uname handling, no Tcreate even) -- if version negotiation or the
-- dotu-conditional Tattach/Tcreate shape were wrong, everything below
-- would fail outright rather than degrade.

local tap = require("tap")
local ninep = require("ninep")
local p9fs = require("p9fs")

tap.plan(10)

local root = ninep.synth({
	["hello.txt"] = "hi from self-mount\n",
	["scratch.txt"] = {
		data = "",
		write = function(off, data) return #data end,
	},
	["sub"] = { children = { ["nested.txt"] = "deep\n" } },
})

local respond = ninep.responder(root)
local loopback = { rpc = function(req) return respond(req) end }

local backend = p9fs.new(loopback)

local h = backend.attach()

tap.ok(h.isdir, "attach: root is a directory")

local hf = backend.walk(h, "hello.txt")

tap.ok(not hf.isdir, "walk: hello.txt is a file")

local of = backend.open(hf, "r")
local data = backend.read(of, 0, 4096)

tap.is(data, "hi from self-mount\n", "read hello.txt through the loopback")
backend.clunk(of)

-- a second, independent open must see the same content -- proving
-- open() cloned a fresh fid rather than reusing/mutating hf.
local of2 = backend.open(hf, "r")
local data2 = backend.read(of2, 0, 4096)

tap.is(data2, data, "a second independent open reads the same content")
backend.clunk(of2)

local st = backend.stat(hf)

tap.is(st.size, #"hi from self-mount\n", "stat size matches the content")

local ents = backend.readdir(h)
local names = {}

for _, e in ipairs(ents) do
	names[#names + 1] = e.name
end
table.sort(names)
tap.is(table.concat(names, ","), "hello.txt,scratch.txt,sub",
    "root readdir lists the synthetic tree, no . or ..")

local hsub = backend.walk(h, "sub")

tap.ok(hsub.isdir, "walk: sub is a directory")

local subents = backend.readdir(hsub)

tap.is(#subents == 1 and subents[1].name, "nested.txt",
    "nested directory readdir")

local hscratch = backend.walk(h, "scratch.txt")
local owf = backend.open(hscratch, "w")
local n = backend.write(owf, 0, "written\n")

tap.is(n, #"written\n", "write accepted by a writable synthetic node")
backend.clunk(owf)

backend.clunk(h)
backend.clunk(hf)
backend.clunk(hsub)
backend.clunk(hscratch)
tap.ok(true, "clunk on every outstanding handle didn't error")

tap.done()
