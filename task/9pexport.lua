-- 9pexport: serve a subtree of this proc's namespace over 9P -- plan 9's
-- exportfs, `exportfs -r root` and all.
--
-- It exports a namespace, not a filesystem: what is in the namespace is
-- the spawner's to build (mount gefs alone, or gefs beside everything
-- else, or a hand-assembled tree), and root chooses which subtree to
-- serve. So "just gefs" is this proc's namespace rooted at /n/gefs, and
-- "everything" is the same proc rooted at /, with no code here caring
-- which -- exactly plan 9's split between constructing a namespace and
-- exporting it.
--
-- protocol on the self port: { net = {__right=}, root = "/n/gefs",
-- port = 564 }. root defaults to "/". The proc is spawned with the
-- namespace to export (ns = <a description>), so its /lib is there to
-- load this code from while a rooted export hands out none of it.
--
-- One connection at a time, served to completion before the next accept,
-- the same shape init's 9p-over-tcp server has and for the same reason:
-- gefs is a single writer, so there is nothing to gain from overlapping
-- clients and a real hazard in it. A second client waits.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local nsfs = require("nsfs")
local p9serve = require("p9serve")

local m0 = thread.recv(sys.SELF)
local net = m0.net.__right
local port = m0.port or 564
local backend = nsfs.new(ns.current(), m0.root or "/")

-- the tcp task's request/reply protocol, as init's tcp9srv uses it
local replyport = sys.newport()
-- send only; {__right=} copies the recv flag, and the tcp task has no
-- business receiving on our reply port
local replyright = sys.sendright(replyport)

local function req(op, extra)
	extra = extra or {}
	extra.op = op
	extra.reply = { __right = replyright }
	sys.send(net, extra)
	return thread.recv(replyport)
end

local function make_io(connid)
	local rx = function()
		return req("recv", { connid = connid, maxlen = 8192 })
	end
	local tx = function(bytes)
		req("send", { connid = connid, data = bytes })
	end
	return rx, tx
end

-- a listen before an address exists fails; retry while dhcp settles
local listener
for _ = 1, 40 do
	listener = req("listen", { port = port })
	if listener then
		break
	end
	thread.sleep(50)
end
if not listener then
	return
end

while true do
	local conn = req("accept", { connid = listener })
	if conn then
		local rx, tx = make_io(conn)
		-- a client dropping the connection mid-request makes rx()
		-- return nil; pcall keeps one bad connection off the listener
		pcall(p9serve.serve, backend, rx, tx)
		-- fire-and-forget: tcp's close never replies (see init)
		sys.send(net, { op = "close", connid = conn })
	end
end
