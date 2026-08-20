-- wssrv: the sole task anywhere with los.platform.ws. Everything else
-- holds a send right to this mailbox and speaks lib/client/ws.lua.
--   {op="open"|"state"|"send"|"recv"|"close", id=, url=, data=, reply=}
-- open and recv answer once there is an answer, so a caller waits on
-- its reply port. The socket can only be polled, so one thread here
-- waits for everyone and a slow relay costs the others nothing.

local sys = require("los.sys")
local thread = require("los.thread")
local platform = require("los.platform.ws")

-- how often an outstanding open or recv is retried. A relay's messages
-- arrive when they arrive; this only bounds how late we notice.
local POLL_MS = 20

local pending = {}	-- {kind=, id=, reply=}

-- reply and let go of the right. Each request transfers a fresh one in;
-- left open, this task's rights table fills and the next transfer fails
-- to land -- see the same note in task/tcp.lua.
local function answer(p, a, b)
	sys.send(p.reply, a, b)
	sys.close(p.reply)
end

local function service()
	local i = 1

	while i <= #pending do
		local p = pending[i]
		local done = false

		if p.kind == "open" then
			local st = platform.state(p.id)

			if st == "open" then
				done = true
				answer(p, p.id)
			elseif st == "closed" then
				done = true
				platform.close(p.id)
				answer(p, nil, "connect failed")
			end
		elseif p.kind == "recv" then
			local m, why = platform.recv(p.id)

			if m then
				done = true
				answer(p, m)
			elseif why ~= "again" then
				done = true
				answer(p, nil, why)
			end
		end

		if done then
			table.remove(pending, i)
		else
			i = i + 1
		end
	end
end

thread.spawn(function()
	while true do
		thread.sleep(POLL_MS)
		service()
	end
end)

-- both loops are threads, and thread.run is what drives them: a bare
-- receive loop in the main chunk would be the only one that ever ran,
-- and the poller above would never wake.
thread.spawn(function()
while true do
	local m = thread.recv(sys.SELF)

	if type(m) == "table" then
		local reply = m.reply and m.reply.__right

		if m.op == "open" then
			local id, why = platform.open(tostring(m.url or ""))

			if id then
				pending[#pending + 1] =
				    { kind = "open", id = id, reply = reply }
			else
				sys.send(reply, nil, why)
				sys.close(reply)
			end
		elseif m.op == "state" then
			sys.send(reply, platform.state(m.id))
			sys.close(reply)
		elseif m.op == "send" then
			sys.send(reply, platform.send(m.id, m.data or ""))
			sys.close(reply)
		elseif m.op == "recv" then
			-- tried once before parking: a message already
			-- waiting should not cost a poll interval.
			local got, why = platform.recv(m.id)

			if got then
				sys.send(reply, got)
				sys.close(reply)
			elseif why ~= "again" then
				sys.send(reply, nil, why)
				sys.close(reply)
			else
				pending[#pending + 1] =
				    { kind = "recv", id = m.id, reply = reply }
			end
		elseif m.op == "close" then
			platform.close(m.id)
			if reply then
				sys.send(reply, true)
				sys.close(reply)
			end
		elseif reply then
			sys.send(reply, nil, "no such op")
			sys.close(reply)
		end
	end
end
end)

thread.run()
