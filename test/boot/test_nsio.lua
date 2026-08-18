-- io.open over the namespace (lib/nsio.lua).
--
-- the claim: io is no longer a second, parallel filesystem that reaches
-- the ESP and only the ESP. it reaches whatever the proc's namespace
-- says, which means a synthetic tree and a file server in ANOTHER PROC
-- are both openable with plain io.open -- neither of which the C io
-- could do at all.
--
-- what stays put, deliberately: io.write/print are a device, not files.
-- see lib/nsio.lua.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local devtree = require("devtree")
local ns = require("ns")
local espfs = require("espfs")
local tap = require("tap")

tap.plan(18)

local N = ns.new()

N:mount("/", espfs.new("/"), "espfs", { root = "/" })
N:mount("/synth", devtree.mem({
	["hello.txt"] = "line one\nline two\nline three\n",
	["empty.txt"] = "",
}), "mem", { tree = {} })

ns.setcurrent(N)

tap.ok(io.__nsio, "io.open was replaced in this proc")

-- ---- a synthetic tree, through plain io.open ----

do
	local f <close> = assert(io.open("/synth/hello.txt"))

	tap.is(f:read(8), "line one", "read(n) returns exactly n bytes")
	tap.is(f:read("l"), "", "read('l') finishes the current line")
	tap.is(f:read("l"), "line two", "and the next line")
	tap.is(f:read("a"), "line three\n", "read('a') takes the rest")
	tap.is(f:read("a"), "", "read('a') at eof is the empty string")
	tap.is(f:read(4), nil, "read(n) at eof is nil, as lua does")
end

do
	local f <close> = assert(io.open("/synth/hello.txt"))
	local n = 0

	for line in f:lines() do
		n = n + 1
	end
	tap.is(n, 3, "lines() iterates the file")
end

tap.is(select(1, io.open("/synth/nope.txt")), nil,
    "a missing file returns nil, not an error")

-- ---- the ESP, through the same call ----

do
	local f <close> = assert(io.open("/init.lua"))
	local src = f:read("a")

	tap.ok(#src > 0 and src:find("lua%-os init"),
	    "the same io.open reaches a real ESP file (" .. #src .. " bytes)")
end

-- ---- a file server in another proc: what the old io could not do ----

local SERVER = [[
local dev = require("dev")
local devtree = require("devtree")
require("srv").main(function()
	return devtree.mem({ ["served.txt"] = "this came from another proc\n" })
end)
]]

local _, sh = require("proc").spawn(SERVER, { name = "ioserver" })

N:mount("/remote", require("mnt").new(sh), "mnt", { port = { __right = sh } })

do
	local f <close> = assert(io.open("/remote/served.txt"))

	tap.is(f:read("a"), "this came from another proc\n",
	    "io.open reached a file server over a port")
end

-- ---- writing ----

do
	local f = assert(io.open("/synth/made.txt", "w"))

	f:write("written ", "through ", "io\n")
	f:close()
end
tap.is(N:readfile("/synth/made.txt"), "written through io\n",
    "io.open('w') creates and writes through the namespace")

-- ---- the namespace is now the boundary, not advisory ----
--
-- a child with a namespace that has nothing mounted at / cannot open a
-- file that plainly exists on the ESP. that was impossible before: io
-- went to the ESP whatever the namespace said.

local rp = sys.newport("test_nsio.rp")
local Empty = ns.new()

Empty:mount("/tmp", devtree.mem({ only = "in the mount\n" }), "mem",
    { tree = { only = "in the mount\n" } })

require("proc").spawn([[
	local sys = require("los.sys")
	local a = ...
	local esp = io.open("/init.lua")
	local mounted = io.open("/tmp/only")

	sys.send(a.__right, {
		esp = esp ~= nil,
		mounted = mounted and mounted:read("a") or nil,
	})
]], { name = "confined", ns = Empty:describe(), arg = { __right = rp } })

local m = thread.recvtimeout(rp, 5000)

tap.ok(m ~= nil, "the confined child answered")
tap.ok(m and m.esp == false,
    "a file outside its namespace is not openable, though it exists")
tap.is(m and m.mounted, "in the mount\n",
    "while what IS mounted opens normally")

-- ---- and a proc given NO namespace can open nothing at all ----
--
-- the other half of the boundary. the file entry points are removed in
-- the kernel for every proc but proc 0 (see proc_new), and nsio puts
-- io.open back only for a proc that has a namespace. so this is not a
-- gate that returns nil -- there is nothing to call.

local np = sys.newport("test_nsio.np")

require("proc").spawn([[
	local sys = require("los.sys")

	sys.send((...).__right, {
		open = io.open == nil,
		lines = io.lines == nil,
		-- rawget, because reading an unbound global raises rather
		-- than answering nil (src/linit.c). io.open above is a
		-- field on a table that exists, so it needs no such care;
		-- these two are globals that are genuinely not there,
		-- which is the thing being asserted.
		loadfile = rawget(_G, "loadfile") == nil,
		dofile = rawget(_G, "dofile") == nil,
		write = type(io.write) == "function",
	})
]], { name = "nonamespace", arg = { __right = np } })

local nm = thread.recvtimeout(np, 5000)

tap.ok(nm ~= nil, "the namespace-less child answered")
tap.ok(nm and nm.open and nm.lines and nm.loadfile and nm.dofile,
    "a proc with no namespace has no io.open, io.lines, loadfile or dofile")
tap.ok(nm and nm.write,
    "but keeps io.write: the console is a device, not a file")

tap.done()
