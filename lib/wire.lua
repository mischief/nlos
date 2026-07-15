-- wire: the sole task anywhere with los.platform.wire (raw com2/9p
-- wire write). also holds the raw serial recv right directly (handle
-- 1 in this proc's own table, granted by the kernel at spawn -- not a
-- los.sys-wide constant). every other proc holds, at most, a
-- send-right to this task's mailbox and talks by message:
-- {op="write", data=s} or {op="read", reply={__right=rp}}.
--
-- unlike write, "read" needs a small bridge: raw bytes arrive
-- independently of when someone asks for them, so a pending request
-- is remembered until data shows up, and data that arrives with no
-- pending request is buffered until someone asks.

local sys = require("los.sys")
local thread = require("los.thread")
local platform = require("los.platform.wire")

local RAWSERIAL = 1

local pending = nil	-- a reply right waiting for the next chunk
local buffered = {}	-- chunks that arrived before anyone asked

while true do
	local which, msg = thread.alt({
		{ port = sys.SELF },
		{ port = RAWSERIAL },
	})

	if which == 1 then
		if msg.op == "write" then
			platform.write(msg.data)
		elseif msg.op == "read" then
			if #buffered > 0 then
				sys.send(msg.reply.__right,
				    table.remove(buffered, 1))
			else
				pending = msg.reply.__right
			end
		end
	else
		if pending then
			sys.send(pending, msg)
			pending = nil
		else
			buffered[#buffered + 1] = msg
		end
	end
end
