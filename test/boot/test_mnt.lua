-- srv.lua + mnt.lua: the dev interface crossing a port.
--
-- the claims under test, in order of how much they matter:
--
--   1. a file server is an ordinary proc, and the send right sys.spawn
--      returns IS the mount. no registry, no wire format.
--   2. a namespace containing such a mount survives describe()/restore()
--      into a child, because what travels is the right. this is the one
--      that was impossible before: every other backend kind is rebuilt
--      from a recipe, and a proc's state has no recipe.
--   3. errors raised inside the server arrive at ns.lua's pcall
--      indistinguishable from local ones -- bare 9front strings.
--   4. fids are finalized, so ns:walk's unclunked intermediates do not
--      leak in the server forever.
--   5. threads sharing a mount pipeline instead of serialising, and
--      their replies cannot cross -- the reply port belongs to the
--      caller, which is why there are no tags.
--   6. the server exits when its last client goes away.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local ns = require("ns")
local mnt = require("mnt")
local tap = require("tap")

tap.plan(21)

-- ---- the server proc ----
--
-- it counts clunks and publishes the count as a file in its own tree,
-- which is how claim 4 becomes observable from outside: the only thing
-- that knows a fid was released is the server.

local SERVER = [[
local dev = require("dev")
local srv = require("srv")

srv.main(function()
	local base = dev.mem({
		hello = "hello from another proc\n",
		clunks = "0",
		sub = { deep = "deep file\n" },
	})
	local nclunk = 0
	local B = {}

	for k, v in pairs(base) do
		B[k] = v
	end
	B.clunk = function(h)
		nclunk = nclunk + 1
		return base.clunk(h)
	end
	B.read = function(h, off, n)
		if h.name == "clunks" then
			-- FIXED WIDTH on purpose. the count changes between
			-- the two reads of a single readfile, and a count
			-- crossing a digit boundary would make the second
			-- read return the tail of a longer string.
			local s = string.format("%08d\n", nclunk)

			return s:sub(off + 1, off + n)
		end
		return base.read(h, off, n)
	end
	return B
end)
]]

local pid, h = sys.spawn(SERVER, { name = "fileserver" })

tap.ok(pid and h, "spawned a file server proc; its right is the mount")

-- ---- claim 1: mount it ----

local N = ns.new()

N:mount("/", dev.mem({ ["init.lua"] = "-- local\n" }), "mem",
    { tree = { ["init.lua"] = "-- local\n" } })

local ok, err = N:mount("/host", mnt.new(h), "mnt", { port = { __right = h } })

tap.ok(ok, "mnt backend passes dev.check: " .. tostring(err))

tap.is(N:readfile("/host/hello"), "hello from another proc\n",
    "read a file served by another proc")
tap.is(N:readfile("/host/sub/deep"), "deep file\n",
    "walked two elements into the remote tree")

local st = N:stat("/host/hello")

tap.ok(st and not st.dir and st.size == 24,
    "stat crossed the port: size " .. tostring(st and st.size))

local sd = N:stat("/host/sub")

tap.ok(sd and sd.dir, "a remote directory stats as a directory")

-- readdir of the mount itself
local ents = N:readdir("/host")
local names = {}

for _, e in ipairs(ents or {}) do
	names[#names + 1] = e.name
end
tap.is(table.concat(names, " "), "clunks hello sub",
    "readdir listed the remote tree: " .. table.concat(names, " "))

-- and the mount point is visible in its parent, as for any other mount
local root = N:readdir("/")
local rootnames = {}

for _, e in ipairs(root or {}) do
	rootnames[#rootnames + 1] = e.name
end
tap.ok(table.concat(rootnames, " "):find("host", 1, true) ~= nil,
    "the mount point shows up in /: " .. table.concat(rootnames, " "))

-- ---- writing, and create ----

local nw, werr = N:writefile("/host/made.txt", "written across a port\n")

tap.is(nw, 22, "create + write through the mount: " .. tostring(werr))
tap.is(N:readfile("/host/made.txt"), "written across a port\n",
    "and it reads back")

-- ---- claim 3: errors keep their 9front spelling ----

local f, ferr = N:open("/host/nosuchfile", "r")

tap.ok(f == nil, "opening a missing remote file fails")
tap.ok(tostring(ferr):find(dev.Enonexist, 1, true) ~= nil,
    "with the server's own error string: " .. tostring(ferr))

local _, derr = N:readfile("/host/sub")

tap.ok(tostring(derr):find(dev.Eisdir, 1, true) ~= nil,
    "reading a remote directory raises Eisdir: " .. tostring(derr))

-- ---- claim 4: dropped fids are clunked by the collector ----

local function clunkcount()
	return tonumber(N:readfile("/host/clunks")) or -1
end

local before = clunkcount()

do
	local B = mnt.new(h)
	local hs = {}

	for i = 1, 30 do
		hs[i] = B.attach()	-- deliberately never clunked
	end
	hs = nil
end
collectgarbage("collect")
collectgarbage("collect")

-- give the finalizers' messages a lap to be served
for _ = 1, 3 do
	sys.yield()
end

local after = clunkcount()

tap.ok(after - before >= 30,
    "30 abandoned fids were clunked by __gc (" .. before .. " -> " ..
    after .. ")")

-- ---- claim 2: the namespace travels, because the right travels ----

local CHILD = [[
local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")

local m = thread.recv(sys.SELF)
local N, err = ns.restore(m.nsdesc)

if not N then
	sys.send(m.reply.__right, { err = tostring(err) })
	return
end
local remote, rerr = N:readfile("/host/sub/deep")
local localf = N:readfile("/init.lua")

sys.send(m.reply.__right, { remote = remote, err = rerr, ["local"] = localf })
]]

local rp = sys.newport()
local cpid, ch = sys.spawn(CHILD, { name = "inheritor" })

sys.send(ch, { nsdesc = N:describe(), reply = { __right = rp } })
sys.close(ch)

local m = thread.recv(rp)

tap.ok(m ~= nil, "the child answered")
tap.is(m.remote, "deep file\n",
    "a CHILD read through the inherited mount: " .. tostring(m.err))
tap.is(m["local"], "-- local\n",
    "and the recipe-built mount still works alongside it")

-- the parent's own mount is unaffected: rights are copied, not moved
tap.is(N:readfile("/host/hello"), "hello from another proc\n",
    "describe() did not consume the parent's right")

-- ---- threads sharing a mount pipeline, and do not read each other's
-- ---- replies ----
--
-- the reply port belongs to the thread rather than the mount, so both
-- of these have a request in flight at once. that is the whole reason
-- there are no tags, and it is only safe if the answers cannot cross.

local crossed, rounds = 0, 60
local done = { 0, 0 }

thread.spawn(function()
	for _ = 1, rounds do
		if N:readfile("/host/hello") ~= "hello from another proc\n" then
			crossed = crossed + 1
		end
		done[1] = done[1] + 1
	end
end)
thread.spawn(function()
	for _ = 1, rounds do
		if N:readfile("/host/sub/deep") ~= "deep file\n" then
			crossed = crossed + 1
		end
		done[2] = done[2] + 1
	end
end)
thread.run()

tap.is(crossed, 0, "two threads shared one mount for " .. (rounds * 2) ..
    " reads with no crossed replies")
tap.ok(done[1] == rounds and done[2] == rounds,
    "and both finished: " .. done[1] .. "/" .. done[2])

-- ---- claim 5: the server exits when its last client goes ----

local dead = false

sys.monitor(pid)
N:unmount("/host")
sys.close(h)
-- the child's right went away when it exited; ours just did. nobody can
-- send again, so serve() returns and the proc ends.
local deadline = sys.uptime_ms() + 4000

while sys.uptime_ms() < deadline do
	local got, msg = sys.tryrecv(sys.SELF)

	if got and msg and msg.exit == pid then
		dead = true
		break
	end
	sys.yield()
end
tap.ok(dead, "the file server (pid " .. tostring(cpid and pid) ..
    ") exited once its last client dropped the right")

tap.done()
