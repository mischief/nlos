-- 9pexport: serve a dev backend over 9P on TCP -- plan 9's exportfs.
--
-- What it exports is whatever dev server it is handed a right to: gefssrv
-- for the gefs volume, or (once lib/nsfs exists) a whole namespace. The
-- choice is the spawner's, not this file's -- exportfs exports a
-- namespace and does not care what is in it.
--
-- protocol: { net = {__right=}, mount = {__right=<a dev server>},
-- port = 564 } on the self port. It mounts the given server as a backend
-- and speaks 9P for it to every TCP client.
--
-- One connection at a time, served to completion before the next accept,
-- the same shape init's 9p-over-tcp server has and for the same reason:
-- gefs is a single writer, so there is nothing to gain from overlapping
-- clients and a real hazard in it. A second client waits.

local sys = require("los.sys")
local thread = require("los.thread")
local mnt = require("mnt")
local p9serve = require("p9serve")

local m0 = thread.recv(sys.SELF)
local net = m0.net.__right
local backend = mnt.new(m0.mount.__right)
local port = m0.port or 564

-- the tcp task's request/reply protocol, as init's tcp9srv uses it
local replyport = sys.newport()

local function req(op, extra)
	extra = extra or {}
	extra.op = op
	extra.reply = { __right = replyport }
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
