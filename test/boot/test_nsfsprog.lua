-- A program's module chain, loaded through nsfs -- the stack fatsrv
-- serves once a machine has more than one volume. Other program tests
-- mount the esp straight through mnt, so only this one loads a
-- program's requires across nsfs. The leaf is the esp on purpose.

local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")
local proc = require("proc")
local tap = require("tap")

local caps = sys.granted()

tap.plan(6)
tap.ok(caps.esp ~= nil, "the boot payload holds the esp filesystem")

-- the server: the esp at /, something else at /n, both behind one nsfs
local server = select(2, sys.spawn([[
	local a = ...
	local ns = require("ns")
	local srv = require("srv")
	local mnt = require("mnt")
	local dev = require("dev")

	srv.main(function()
		local N = ns.new()
		local esp = a.esp.__right

		assert(N:mount("/", mnt.new(esp), "mnt",
		    { port = { __right = esp } }))
		-- a second mount, so a walk crosses a boundary the way one
		-- into /config does on the board
		assert(N:mount("/n", dev.mem({ two = "second\n" }), "mem"))
		return require("nsfs").new(N)
	end)
]], { name = "nsfssrv", arg = { esp = { __right = caps.esp } } }))

tap.ok(server ~= nil, "a server exporting a namespace through nsfs")

-- a client namespace over that server, which is what a program gets
local C = ns.new()

assert(C:mount("/", mnt.new(server), "mnt",
    { port = { __right = sys.sendright(server) } }))

tap.ok((C:readfile("/lib/ns.lua") or ""):find("NS:walk", 1, true) ~= nil,
    "a lib file reads through nsfs")
tap.ok(C:readfile("/n/two") == "second\n",
    "and so does one on the far side of the inner mount")

-- the part no other test does: a program whose requires all resolve
-- through nsfs. lib/tls pulls the deepest chain in the tree, which is
-- what made the failure show up on the board and not before.
local port = sys.newport("nsfsprog")
local said

local pid = proc.spawn([[
	local a = ...
	local sys = require("los.sys")
	local out = a.say.__right
	local names = { "ns", "dev", "chan", "mnt", "srv", "prog",
	    "resolv", "dns", "http", "json", "crypto.sha256",
	    "crypto.hmac", "crypto.hkdf", "crypto.drbg", "tls.wire",
	    "tls.record", "tls.keys", "tls.hello", "tls.conn", "x509.der",
	    "x509.cert", "ps" }
	local n = 0

	for _, m in ipairs(names) do
		local ok, why = pcall(require, m)

		if not ok then
			sys.send(out, { bad = m, why = tostring(why) })
			return
		end
		n = n + 1
	end
	sys.send(out, { loaded = n })
]], { name = "chain", ns = C:describe(),
    arg = { say = { __right = sys.sendright(port) } } })

tap.ok(pid ~= nil, "a program spawned on that namespace")

for _ = 1, 400 do
	local ok, m = sys.tryrecv(port)

	if ok then
		said = m
		break
	end
	require("los.thread").sleep(25)
end

if said and said.loaded then
	tap.is(said.loaded, 22, "every module in the chain loaded")
elseif said then
	tap.ok(false, "the chain stopped at " .. tostring(said.bad) ..
	    ": " .. tostring(said.why))
else
	-- the failure this exists for: on the board it said nothing at all
	tap.ok(false, "the program said nothing -- it died loading")
end

tap.done()
