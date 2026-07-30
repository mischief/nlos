-- per-client fid spaces.
--
-- a server's fids are private to the client that opened them. 9P gets
-- this from one fid space per connection; we get it from one port per
-- client, because a port carries no sender identity and so a shared fid
-- table cannot tell whose fid it is being handed.
--
-- the establishment port answers session and readonly only. fid
-- operations there are not implemented, so a client cannot keep using a
-- shared space by accident.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local ns = require("ns")
local mnt = require("mnt")
local tap = require("tap")

tap.plan(16)

local SERVER = [[
local dev = require("dev")
require("srv").main(function()
	return dev.mem({ a = "alpha\n", b = "bravo\n" })
end)
]]

local _, sh = require("proc").spawn(SERVER, { name = "fidsrv" })

-- ---- the establishment port refuses fid work ----

local rp = sys.newport()

sys.send(sh, { op = "attach", seq = 1, reply = { __right = rp } })

local m = thread.recvtimeout(rp, 5000)

tap.ok(m ~= nil, "the establishment port answered")
tap.is(m and m.err, dev.Enotimpl,
    "attach on the establishment port is not implemented: " ..
    tostring(m and m.err))

sys.send(sh, { op = "session", seq = 2, reply = { __right = rp } })

local sm = thread.recvtimeout(rp, 5000)

tap.ok(sm and sm.port and sm.port.__right,
    "session returns a right: " .. tostring(sm and sm.port and
    sm.port.__right))

local sess = sm.port.__right

tap.ok(not pcall(sys.tryrecv, sess),
    "and it is send only, so a client cannot take another's requests")

-- ---- two mounts of one server do not share fids ----

local A = ns.new()
local B = ns.new()

A:mount("/", mnt.new(sh), "mnt", { port = { __right = sh } })
B:mount("/", mnt.new(sh), "mnt", { port = { __right = sh } })

tap.is(A:readfile("/a"), "alpha\n", "mount A reads")
tap.is(B:readfile("/b"), "bravo\n", "mount B reads")

-- open a file through A and keep the handle, then try to reach it from B
-- by naming every small fid. A's fid is in there somewhere.
local held = assert(A:open("/a", "r"))

tap.is(held:read(5), "alpha", "A holds an open handle and can read it")

local reached = 0

for fid = 1, 40 do
	local ok, res = pcall(function()
		local rp2 = sys.newport()

		sys.send(sess, { op = "read", fid = fid, off = 0, n = 8,
		    seq = 1000 + fid, reply = { __right = rp2 } })

		local r = thread.recvtimeout(rp2, 2000)

		sys.close(rp2)
		if r and r.data then
			return r.data
		end
		return nil, r and r.err
	end)

	if ok and res then
		reached = reached + 1
	end
end

tap.is(reached, 0,
    "B's session cannot read any of A's fids by guessing (" .. reached ..
    " reached)")

-- and clunking a guessed fid does not disturb A
for fid = 1, 40 do
	pcall(sys.send, sess, { op = "clunk", fid = fid })
end
for _ = 1, 4 do
	sys.yield()
end

tap.is(held:read(2), "\n", "A's handle survives another session clunking fids")
held:close()

tap.is(A:readfile("/a"), "alpha\n", "and A still works afterwards")
tap.is(B:readfile("/a"), "alpha\n", "as does B")

-- ---- a session ends with its client ----

local CHILD = [[
local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local a = thread.recv(sys.SELF)
local N = ns.restore(a.nsdesc)

sys.send(a.reply.__right, { got = N and N:readfile("/a") })
]]

local crp = sys.newport()
local cpid, ch = sys.spawn(CHILD, { name = "sessionchild" })

sys.monitor(cpid)
sys.send(ch, { nsdesc = A:describe(), reply = { __right = crp } })
sys.close(ch)

local cm = thread.recvtimeout(crp, 5000)

tap.is(cm and cm.got, "alpha\n", "a child opened its own session and read")

local deadline = sys.uptime_ms() + 4000
local gone = false

while sys.uptime_ms() < deadline do
	local ok, em = sys.tryrecv(sys.SELF)

	if ok and em and em.exit == cpid then
		gone = true
		break
	end
	sys.yield()
end
tap.ok(gone, "and the child exited, releasing its session")

-- ---- readonly composes: attenuate, then get a private session ----

local ro = mnt.readonly(sh)
local R = ns.new()

R:mount("/", mnt.new(ro), "mnt", { port = { __right = ro } })

tap.is(R:readfile("/a"), "alpha\n", "a read-only session reads")
tap.ok(select(1, R:create("/new", "rw")) == nil,
    "and still refuses to create")

-- ---- unmounting releases the session ----

local before = sys.stats().ports

A:unmount("/")
for _ = 1, 4 do
	sys.yield()
end
tap.ok(sys.stats().ports <= before,
    "unmount released the session rather than leaking the port (" ..
    before .. " -> " .. sys.stats().ports .. ")")

tap.done()
