-- attenuation: the same filesystem served at two authority levels.
--
-- the claim: whether a client may write is decided by WHICH RIGHT IT
-- HOLDS, with no permission bit anywhere and no per-call check. asking a
-- server for a read-only right cannot escalate, so it needs no capability
-- of its own -- what comes back is strictly weaker than what asked.
--
-- this is what lets a public session be given the ESP without being
-- given the ability to write it.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local ns = require("ns")
local mnt = require("mnt")
local tap = require("tap")

tap.plan(22)

-- a writable server over a mem tree
local SERVER = [[
local dev = require("dev")
require("srv").main(function()
	return dev.mem({ ["hello.txt"] = "readable\n", sub = { deep = "d\n" } })
end)
]]

local _, rw = require("proc").spawn(SERVER, { name = "rwsrv" })

-- ---- the read-write right behaves as before ----

local W = ns.new()

W:mount("/", mnt.new(rw), "mnt", { port = { __right = rw } })

tap.is(W:readfile("/hello.txt"), "readable\n", "rw: reads")
tap.is(W:writefile("/made.txt", "written\n"), 8, "rw: creates and writes")
tap.is(W:readfile("/made.txt"), "written\n", "rw: reads back what it wrote")

-- ---- attenuate ----

local ro = mnt.readonly(rw)

tap.ok(ro ~= nil and ro ~= rw,
    "readonly() returned a different right: " .. tostring(ro))

local R = ns.new()

R:mount("/", mnt.new(ro), "mnt", { port = { __right = ro } })

-- ---- the read side is the SAME tree, not a copy ----

tap.is(R:readfile("/hello.txt"), "readable\n", "ro: reads")
tap.is(R:readfile("/sub/deep"), "d\n", "ro: walks and reads a deep path")
tap.is(R:readfile("/made.txt"), "written\n",
    "ro: sees a file the rw side created, so it is one backend")

local ents = R:readdir("/")
local names = {}

for _, e in ipairs(ents or {}) do
	names[#names + 1] = e.name
end
table.sort(names)
tap.is(table.concat(names, ","), "hello.txt,made.txt,sub", "ro: readdir works")

local st = R:stat("/hello.txt")

tap.ok(st and st.size == 9, "ro: stat works: " .. tostring(st and st.size))

-- ---- and every way of changing it is refused ----

local c, cerr = R:create("/new.txt", "rw")

tap.ok(c == nil, "ro: create is refused")
tap.ok(tostring(cerr):find(dev.Eperm, 1, true) ~= nil,
    "with Eperm: " .. tostring(cerr))

local w, werr = R:open("/hello.txt", "w")

tap.ok(w == nil, "ro: open for writing is refused")
tap.ok(tostring(werr):find(dev.Eperm, 1, true) ~= nil,
    "with Eperm: " .. tostring(werr))

tap.ok(R:writefile("/nope.txt", "x") == nil, "ro: writefile fails")
tap.ok(W:readfile("/nope.txt") == nil,
    "and nothing appeared on the rw side either")

-- a handle opened for reading cannot be written through
local f = assert(R:open("/hello.txt", "r"))
local wn, wferr = f:write("clobber")

tap.ok(wn == nil and tostring(wferr):find(dev.Eperm, 1, true) ~= nil,
    "ro: write through a read handle is refused: " .. tostring(wferr))
f:close()
tap.is(W:readfile("/hello.txt"), "readable\n", "and the file is untouched")

-- ---- the right handed out is SEND ONLY ----
--
-- {__right=} copies the recv flag, so a port the server created would
-- otherwise let a holder receive on it -- and every read-only client
-- shares this one port, so one could take another's requests.

tap.ok(not pcall(sys.tryrecv, ro),
    "the read-only right cannot receive, only send")

-- ---- and now the one that matters: the REAL esp ----
--
-- this is what a public session gets. it must be able to read /lib so it
-- can adopt a namespace and require modules, and it must not be able to
-- touch the boot volume.

local caps = sys.granted()

if caps.esp then
	local espro = mnt.readonly(caps.esp)
	local E = ns.new()

	E:mount("/", mnt.new(espro), "mnt", { port = { __right = espro } })

	local init = E:readfile("/init.lua")

	tap.ok(init and #init > 0,
	    "esp read-only: reads a real file (" .. tostring(init and #init) ..
	    " bytes)")
	tap.ok(E:readfile("/lib/dev.lua") ~= nil,
	    "esp read-only: can read /lib, so a namespace over it is adoptable")

	local ec, eerr = E:create("/pwned.txt", "rw")

	tap.ok(ec == nil and tostring(eerr):find(dev.Eperm, 1, true) ~= nil,
	    "esp read-only: cannot create on the boot volume: " ..
	    tostring(eerr))

	local eo, eoerr = E:open("/init.lua", "w")

	tap.ok(eo == nil and tostring(eoerr):find(dev.Eperm, 1, true) ~= nil,
	    "esp read-only: cannot open init.lua for writing: " ..
	    tostring(eoerr))
else
	tap.ok(false, "no esp capability; cannot test the real thing")
	tap.ok(false, "")
	tap.ok(false, "")
	tap.ok(false, "")
end

tap.done()
