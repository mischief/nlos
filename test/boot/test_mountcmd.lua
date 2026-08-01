-- the mount builtin: a name typed at a prompt becomes a mounted tree.
--
-- This is the end of the road /srv exists for. test_srv.lua proves a
-- right survives being named; this proves a user can spend that without
-- holding any right themselves -- they type a string, and the shell
-- turns it into authority it was granted.

local sys = require("los.sys")
local tap = require("tap")
local ns = require("ns")
local dev = require("dev")
local dos = require("dos")
local srvc = require("srvc")
local srvfs = require("srvfs")

tap.plan(15)

local srvd = select(2, sys.spawn(
    string.dump(assert(loadfile("/lib/srvd.lua"))), { name = "srvtest" }))
local server = select(2, sys.spawn([[
	local dev = require("dev")
	local srv = require("srv")

	srv.main(function()
		return dev.mem({ ["hello"] = "mounted by name\n" })
	end)
]], { name = "memsrv" }))

tap.ok(srvd and server, "a registry and a server")
tap.ok(srvc.post(srvd, "mem", sys.sendright(server)), "server posted as 'mem'")

-- ---- a shell with a namespace and the registry ----
local N = ns.new()

N:mount("/", dev.mem({ ["motd"] = "local root\n" }), "mem",
    { tree = { ["motd"] = "local root\n" } })
N:mount("/srv", srvfs.new(srvd), "srvfs")

-- the console is a port we read back, so what the shell prints can be
-- asserted on rather than just not crashing.
-- NOTE the shell is given no registry capability. Everything mount
-- needs it finds in the namespace.
local consport = sys.newport()
local sh = dos.new({ ns = N, cons = sys.sendright(consport) })

local function said()
	local out = {}

	while true do
		local ok, m = sys.tryrecv(consport)

		if not ok then
			break
		end
		out[#out + 1] = (type(m) == "table" and m.data) or ""
	end
	return table.concat(out)
end

local function run(line)
	local words = {}

	for w in line:gmatch("%S+") do
		words[#words + 1] = w
	end
	return dos.builtins[words[1]](sh, words), said()
end

-- ---- mount ----
tap.ok(dos.builtins["mount"] ~= nil, "mount is a builtin")
tap.ok(dos.builtins["unmount"] ~= nil, "unmount is a builtin")

local rc = run("mount mem /n")

tap.is(rc, 0, "mount mem /n succeeds")
tap.is(N:readfile("/n/hello"), "mounted by name\n",
    "and the tree is really there")

-- the /srv path spelling, since that is how you find the name
local rc2 = run("mount /srv/mem /n2")

tap.is(rc2, 0, "mount /srv/mem /n2 -- the path spelling works too")
tap.is(N:readfile("/n2/hello"), "mounted by name\n", "and it mounted")

-- ---- what a user gets wrong ----
local rc3, out3 = run("mount nosuch /n3")

tap.is(rc3, 1, "mounting an unposted name fails")
tap.ok(out3:find("nosuch") ~= nil, "and says which name: " .. out3:gsub("\n", ""))

local rc4, out4 = run("mount")

tap.is(rc4, 1, "mount with no arguments fails")
tap.ok(out4:find("usage") ~= nil, "and prints usage")

-- ---- unmount ----
local rc5 = run("unmount /n")

tap.is(rc5, 0, "unmount /n succeeds")
tap.ok(N:readfile("/n/hello") == nil, "and the tree is gone")

-- ---- a shell whose namespace has no /srv ----
-- authority to mount IS having /srv in the namespace, so removing it
-- takes the ability away with nothing else changed.
local bare = dos.new({ ns = ns.new(), cons = sys.sendright(consport) })

dos.builtins["mount"](bare, { "mount", "mem", "/x" })
tap.ok(said():find("/srv/mem") ~= nil,
    "a shell whose namespace lacks /srv cannot mount")

tap.done()
