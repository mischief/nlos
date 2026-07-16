-- diagnostic: bypass net.lua's wakeup-ping bridge entirely, talk to
-- los.platform.net directly from a privileged-equivalent probe (spawn
-- ourselves AS the net-flavored task is not possible from lua, so
-- instead: drive net's accept_poll via busy sys.yield(), never
-- touching netport/thread.alt at all, to isolate whether CheckEvent
-- itself ever reports completion independent of the notify bridge.

local sys = require("los.sys")
local thread = require("los.thread")

if not sys.NET then
	print("NO NET")
	return
end

local replyport = sys.newport()
local function req(op, extra)
	extra = extra or {}
	extra.op = op
	extra.reply = { __right = replyport }
	sys.send(sys.NET, extra)
	return thread.recv(replyport)
end

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

-- issue accept via net task as normal (net.lua still owns the raw
-- conn and is the only one that can call accept_start), but instead
-- of waiting for net.lua's reply, busy-poll our own request status
-- by re-sending "accept" repeatedly is wrong (would issue multiple
-- overlapping listen tokens) -- so instead just wait for the normal
-- reply, but print progress periodically so we can see how long it
-- actually takes and whether it EVER arrives given enough patience.
print("waiting for accept (up to ~60s, this call blocks)...")
local conn = req("accept", { connid = listener })
print("ACCEPT RETURNED: " .. tostring(conn))
