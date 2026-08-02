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
			-- every request arrives with a FRESH right to the
			-- caller's reply port, even when the port is one it
			-- has used a hundred times before, so the right has
			-- to be closed once the reply is queued or this task
			-- runs out of the 64 it may hold. lib/tcp.lua has
			-- always done this; here it was missed, and stayed
			-- invisible for as long as the wire happened to
			-- deliver in few enough chunks to stay under the
			-- ceiling. that is a property of the uart, not of
			-- anything this task can see.
			if #buffered > 0 then
				sys.send(msg.reply.__right,
				    table.remove(buffered, 1))
				sys.close(msg.reply.__right)
			else
				if pending then
					sys.close(pending)
				end
				pending = msg.reply.__right
			end
		end
	else
		if pending then
			sys.send(pending, msg)
			sys.close(pending)
			pending = nil
		else
			buffered[#buffered + 1] = msg
		end
	end
end
