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

tap.plan(19)

local SERVER = [[
local dev = require("dev")
require("srv").main(function()
	return dev.mem({ a = "alpha\n", b = "bravo\n" })
end)
]]

local _, sh = require("proc").spawn(SERVER, { name = "fidsrv" })

-- ---- the establishment port refuses fid work ----

local rp = sys.newport("test_session.rp")

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
		local rp2 = sys.newport("test_session.rp")

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

local crp = sys.newport("test_session.cr")
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

-- ---- a client that dies still gives its fids back ----
--
-- The ordinary way a client leaves: killed, or dead, holding an open
-- file. 9P clunks a connection's fids when the connection ends, and a
-- backend that keeps anything per handle needs that -- an exclusive
-- device is where it shows, since one interrupted reader would lock
-- everyone else out for as long as the server lives.

local EXCL = [[
local dev = require("dev")

require("srv").main(function()
	local B = {}
	local owner = nil

	function B.attach()
		return { path = "/" }
	end
	function B.walk(h, name)
		if name == "." or name == ".." then
			return { path = h.path }
		end
		if h.path ~= "/" or name ~= "one" then
			dev.error(dev.Enonexist)
		end
		return { path = "/one" }
	end
	function B.stat(h)
		return { name = h.path, size = 0, dir = h.path == "/" }
	end
	function B.open(h)
		if h.path == "/" then
			return { path = h.path }
		end
		if owner then
			dev.error("in use")
		end
		local fh = { path = h.path, holder = true }

		owner = fh
		return fh
	end
	function B.read(h, off, n)
		return off == 0 and "held\n" or ""
	end
	function B.readdir()
		return { { name = "one", size = 0, dir = false } }
	end
	function B.create()
		dev.error(dev.Eperm)
	end
	function B.write()
		dev.error(dev.Eperm)
	end
	function B.clunk(h)
		if h and h.holder and owner == h then
			owner = nil
		end
	end
	return B
end)
]]

local _, xh = require("proc").spawn(EXCL, { name = "exclsrv" })

-- a proc that opens the file and then never gets to close it
local HOLDER = [[
local a = ...
local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")
local N = ns.new()

N:mount("/x", mnt.new(a.srv.__right), "mnt",
    { port = { __right = a.srv.__right } })

local f = N:open("/x/one", "r")

sys.send(a.done.__right, f ~= nil)
-- parked on its own mailbox, holding the file open, until it is killed
require("los.thread").recv(sys.SELF)
]]

local rport = sys.newport("test_session.rp")
local hpid, hh = require("proc").spawn(HOLDER, { name = "holder",
    arg = { srv = { __right = xh }, done = { __right = rport } } })

tap.ok(thread.recvtimeout(rport, 5000) == true, "a holder opened the file")

-- while it holds it, nobody else may
local X = ns.new()

X:mount("/x", mnt.new(xh), "mnt", { port = { __right = xh } })
tap.ok(X:open("/x/one", "r") == nil,
    "a second open is refused while the holder lives")

sys.kill(hpid)
sys.close(hh)
for _ = 1, 8 do
	sys.yield()
end

local f2, ferr = X:open("/x/one", "r")

tap.ok(f2 ~= nil,
    "and it opens once the holder is gone: " .. tostring(ferr))
if f2 then
	f2:close()
end

tap.done()
