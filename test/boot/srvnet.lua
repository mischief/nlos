-- net test payload: listens on a TCP port, echoes one line back
-- uppercased, so a host client can prove the whole stack end to end.

local sys = require("los.sys")
local thread = require("los.thread")

if not sys.TCP then
	print("NO TCP")
	return
end

local replyport = sys.newport()

local function req(op, extra)
	extra = extra or {}
	extra.op = op
	extra.reply = { __right = replyport }
	sys.send(sys.TCP, extra)
	return thread.recv(replyport)
end

-- Configure() can fail transiently if DHCP hasn't completed yet this
-- soon after boot; retry for a few real seconds before giving up.
-- (no sleep(ms) primitive yet -- NOTES.md future work -- so this is
-- a crude rdtsc busy-wait, fine for a one-off diagnostic, not
-- something to leave lying around as a real primitive.)
local function spin(cycles)
	local t0 = sys.ticks()
	while sys.ticks() - t0 < cycles do
		sys.yield()
	end
end

local listener
for attempt = 1, 60 do
	listener = req("listen", { port = 7777 })
	if listener then
		break
	end
	spin(1000000000)
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
sys.send(sys.TCP, { op = "close", connid = conn })
print("DONE")
