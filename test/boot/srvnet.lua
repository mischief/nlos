-- net test payload: listens on a TCP port, echoes one line back
-- uppercased, so a host client can prove the whole stack end to end.

local sys = require("los.sys")
local thread = require("los.thread")
local caps_of = sys.granted()

if not caps_of.tcp then
	print("NO TCP")
	return
end

local replyport = sys.newport("srvnet.replypor")

local function req(op, extra)
	extra = extra or {}
	extra.op = op
	extra.reply = { __right = replyport }
	sys.send(caps_of.tcp, extra)
	return thread.recv(replyport)
end

-- Configure() can fail transiently if DHCP hasn't completed yet this
-- soon after boot; retry for a few real seconds before giving up.
local listener
for _ = 1, 60 do
	listener = req("listen", { port = 7777 })
	if listener then
		break
	end
	thread.sleep(250)
end
if not listener then
	print("LISTEN FAILED")
	return
end
print("LISTENING")

local conn = req("accept", { connid = listener })
if not conn then
	print("ACCEPT FAILED")
	return
end
print("ACCEPTED")

local data = req("recv", { connid = conn, maxlen = 256 })
print("GOT: " .. tostring(data))

if data then
	req("send", { connid = conn, data = data:upper() })
	print("SENT")
end

-- fire-and-forget: tcp.lua's "close" op never replies (see
-- lib/tcp.lua's op table comment), so this must not go through
-- req()/thread.recv or it blocks forever.
sys.send(caps_of.tcp, { op = "close", connid = conn })
print("DONE")
