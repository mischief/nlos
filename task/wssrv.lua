-- wssrv: the sole task anywhere with los.platform.ws. Everything else
-- holds a send right to this mailbox and speaks lib/client/ws.lua.
--   {op="session"}, {op="open"|"state"|"send"|"recv"|"close", ...}
-- A socket is polled, not waited on, so one thread here polls for
-- everyone and a slow relay costs the others nothing.

local sys = require("los.sys")
local thread = require("los.thread")
local platform = require("los.platform.ws")

-- how often an outstanding open or recv is retried. A relay's messages
-- arrive when they arrive; this only bounds how late we notice.
local POLL_MS = 20

-- ---- one socket space per client ----
--
-- Ids are per session, as fb's images are and as 9P fids are per
-- connection: a shared table lets a client name another's socket by
-- guessing a small integer, and a port carries no sender identity.
local anon = { socks = {}, nextid = 1 }

-- parallel: ports is the set alt waits on, spaces[i] is whose sockets
-- arrive on ports[i]. [1] is this task's own port, for a client that
-- never asked for a session.
local ports = { sys.SELF }
local spaces = { anon }

local pending = {}	-- {kind=, id=, space=, reply=}

local cases = {}

local function altcases(hs)
	for i = 1, #hs do
		local c = cases[i]

		if not c then
			c = {}
			cases[i] = c
		end
		c.port = hs[i]
	end
	for i = #hs + 1, #cases do
		cases[i] = nil
	end
	return cases
end

-- the platform's socket behind a client's id, or nil where the client
-- named one that is not its own
local function sock(space, id)
	return id and space.socks[id]
end

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
		local h = sock(p.space, p.id)

		if not h then
			done = true
			answer(p, nil, "no such socket")
		elseif p.kind == "open" then
			local st = platform.state(h)

			if st == "open" then
				done = true
				answer(p, p.id)
			elseif st == "closed" then
				done = true
				platform.close(h)
				p.space.socks[p.id] = nil
				answer(p, nil, "connect failed")
			end
		elseif p.kind == "recv" then
			local m, why = platform.recv(h)

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

-- a session whose client has gone: sys.hungup is sole_holder, so it is
-- true once we are the only holder left. Its sockets go with it, which
-- is the whole reason ids are per client.
local function reap()
	for i = #ports, 2, -1 do
		if sys.hungup(ports[i]) then
			for id, h in pairs(spaces[i].socks) do
				platform.close(h)
				spaces[i].socks[id] = nil
			end

			local j = 1

			while j <= #pending do
				if pending[j].space == spaces[i] then
					sys.close(pending[j].reply)
					table.remove(pending, j)
				else
					j = j + 1
				end
			end
			sys.close(ports[i])
			table.remove(ports, i)
			table.remove(spaces, i)
		end
	end
end

thread.spawn(function()
	while true do
		thread.sleep(POLL_MS)
		service()
		reap()
	end
end)

local ops = {}

-- a client's own socket space, and a right to talk on it. Ours is
-- closed once the reply has gone, so the client holds the only send
-- right and sys.hungup tells us when it has gone.
function ops.session(space, m, reply)
	local recv = sys.newport("ws.session")
	local send = sys.sendright(recv)

	ports[#ports + 1] = recv
	spaces[#spaces + 1] = { socks = {}, nextid = 1 }
	sys.send(reply, { port = { __right = send } })
	sys.close(reply)
	sys.close(send)
end

function ops.open(space, m, reply)
	local h, why = platform.open(tostring(m.url or ""))

	if not h then
		sys.send(reply, nil, why)
		sys.close(reply)
		return
	end

	local id = space.nextid

	space.nextid = id + 1
	space.socks[id] = h
	pending[#pending + 1] = { kind = "open", id = id, space = space,
	    reply = reply }
end

-- an id nobody was given is the one error these answer. Not `h and nil
-- or "no such socket"`: nil is false, so that names the error on every
-- successful call as well.
local function answer(reply, h, ok)
	if h then
		sys.send(reply, ok)
	else
		sys.send(reply, nil, "no such socket")
	end
	sys.close(reply)
end

function ops.state(space, m, reply)
	local h = sock(space, m.id)

	answer(reply, h, h and platform.state(h))
end

function ops.send(space, m, reply)
	local h = sock(space, m.id)

	answer(reply, h, h and platform.send(h, m.data or ""))
end

function ops.recv(space, m, reply)
	local h = sock(space, m.id)

	if not h then
		sys.send(reply, nil, "no such socket")
		sys.close(reply)
		return
	end

	-- tried once before parking: a message already waiting should not
	-- cost a poll interval.
	local got, why = platform.recv(h)

	if got then
		sys.send(reply, got)
		sys.close(reply)
	elseif why ~= "again" then
		sys.send(reply, nil, why)
		sys.close(reply)
	else
		pending[#pending + 1] = { kind = "recv", id = m.id,
		    space = space, reply = reply }
	end
end

function ops.close(space, m, reply)
	local h = sock(space, m.id)

	if h then
		platform.close(h)
		space.socks[m.id] = nil
	end
	if reply then
		answer(reply, h, true)
	end
end

-- both loops are threads, and thread.run is what drives them: a bare
-- receive loop in the main chunk would be the only one that ever ran,
-- and the poller above would never wake.
thread.spawn(function()
	while true do
		local i, m = sys.alt(altcases(ports))

		if i and type(m) == "table" then
			local space = spaces[i]
			local fn = ops[m.op]
			local reply = m.reply and m.reply.__right

			if fn and space then
				fn(space, m, reply)
			elseif reply then
				sys.send(reply, nil, "no such op")
				sys.close(reply)
			end
		end
	end
end)

thread.run()
