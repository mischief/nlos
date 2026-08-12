-- Reading the lease back out of dhcpd, before and after it has one.
--
-- On the T-Deck a service task reading /net/ntp gets "" while the lease
-- is unbound and an i/o error once it exists -- while the same read
-- from a shell works. The file stats fine either way. This asks the
-- same question where a failure costs thirty seconds instead of a
-- flash cycle.
--
-- /net/dns rather than /net/ntp: slirp leases a resolver and offers no
-- ntp server, and the point is a file with bytes in it. Both go through
-- the same joinlines over the same kind of list.
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local mnt = require("mnt")
local nsmod = require("ns")

tap.plan(7)

local caps = sys.granted()

if not tap.ok(caps.dhcpd ~= nil, "a dhcpd capability was granted") then
	tap.diag("no dhcpd; there is no lease to read")
	tap.done()
	return
end

-- the raw port, with no namespace anywhere near it
local B = mnt.new(caps.dhcpd)

local function readraw(name)
	return pcall(function()
		local root = B.attach()
		local h = B.open(B.walk(root, name), "r")
		local s = B.read(h, 0, 256)

		B.clunk(h)
		B.clunk(root)
		return s
	end)
end

-- and through a namespace, the way a task and a shell both reach it
local N = nsmod.new()

tap.ok(N:mount("/net", mnt.new(caps.dhcpd), "mnt",
    { port = { __right = caps.dhcpd } }), "mounted dhcpd at /net")

local ok0, raw0 = readraw("dns")

tap.ok(ok0, "the raw read works before a lease: " .. tostring(raw0))
tap.diag("before: raw=" .. string.format("%q", tostring(raw0)) ..
    " ns=" .. string.format("%q", tostring(N:readfile("/net/dns"))))

-- wait for the lease. slirp answers at once, but the task has to send,
-- receive and install before the files say anything.
local addr

for _ = 1, 100 do
	addr = N:readfile("/net/addr")
	if addr and addr ~= "" then break end
	thread.sleep(100)
end

if not tap.ok(addr and addr ~= "", "a lease arrived: " .. tostring(addr)) then
	tap.done()
	return
end

local ok1, raw1 = readraw("dns")
local nsok, nstxt = pcall(function() return N:readfile("/net/dns") end)

tap.diag("after: raw ok=" .. tostring(ok1) .. " v=" .. tostring(raw1))
tap.diag("after: ns  ok=" .. tostring(nsok) .. " v=" .. tostring(nstxt))

tap.ok(ok1 and raw1 ~= nil and raw1 ~= "",
    "the raw read works once the lease exists")
tap.ok(nsok and nstxt ~= nil and nstxt ~= "",
    "the namespace read works once the lease exists")
-- and the way a service task actually gets it: not by mounting, but by
-- being handed a description of somebody else's namespace to rebuild.
-- That is the one hop between a shell and task/timed.lua, and the hop
-- this test exists to cover.
local child = [[
	local a = ...
	local sys = require("los.sys")
	local nsmod = require("ns")

	-- what lib/proc.lua's bootstrap does before the chunk runs
	local N = a.ns and nsmod.adopt(a.ns) or nsmod.current()
	-- an EMPTY file first, then one with bytes, on the same session.
	-- That is the order timed sees: /net/ntp answers "" while the
	-- lease is unbound, and the read after it is the one that fails.
	local ok0, empty = pcall(function() return N:readfile("/net/ntp") end)
	local ok, txt = pcall(function() return N:readfile("/net/dns") end)

	sys.send(a.reply.__right, { ok = ok, txt = tostring(txt),
	    hasns = N ~= nil, first = tostring(ok0) .. "/" .. tostring(empty),
	    stat = N and N:stat("/net/dns") ~= nil })
]]

local rp = sys.newport("netfiles_rp")
-- the description travels in the arg and the child adopts it, which is
-- what lib/proc.lua's bootstrap does for a service task. Spelt out here
-- because lib/proc.lua is not in microvm's embedded set.
local pid = sys.spawn(child, {
	arg = { reply = { __right = sys.sendright(rp) },
	    ns = N:describe() },
})

local m = thread.recvtimeout(rp, 5000)

if type(m) == "table" then
	tap.diag("child: first=" .. tostring(m.first) .. " ns=" .. tostring(m.hasns) .. " ok=" ..
	    tostring(m.ok) .. " stat=" .. tostring(m.stat) ..
	    " v=" .. tostring(m.txt))
	tap.ok(m.ok and m.txt ~= "nil" and m.txt ~= "",
	    "a described namespace reads /net/dns")
else
	tap.ok(false, "the child said nothing: " .. tostring(m))
end

tap.done()
