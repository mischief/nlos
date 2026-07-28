-- tcp: the sole task anywhere with los.platform.tcp (raw tcp4). also
-- holds the raw netport recv right directly (handle 1 in this proc's
-- own table, granted by the kernel at spawn -- not a los.sys-wide
-- constant). every other proc holds, at most, a send-right to this
-- task's mailbox and talks by message:
--   {op="listen", port=, reply={__right=}} -> connid or nil
--   {op="dial", a=,b=,c=,d=, port=, reply={__right=}} -> connid or nil
--   {op="accept", connid=, reply={__right=}} -> connid or nil
--   {op="send", connid=, data=, reply={__right=}} -> true or false
--   {op="recv", connid=, maxlen=, reply={__right=}} -> data or nil
--   {op="close", connid=}
--
-- unlike cons/wire's ops, accept/send/recv are genuinely async under
-- the hood (tcp4 tokens, not synchronous EFI calls) -- each mints a
-- token and remembers who to reply to; every netport wakeup ping
-- (raw bytes arrived, a send finished, whatever) rechecks every
-- outstanding token, replying to whichever actually completed.
--
-- udp lives in lib/udp.lua now, its own exclusive task -- los.sys.UDP,
-- not this one. see DESIGN.md for why they're split.

local sys = require("los.sys")
local thread = require("los.thread")
local platform = require("los.platform.tcp")

local RAWNET = 1

local conns = {}	-- connid -> connection userdata (see net.c's connbox)
local nextconnid = 1
local pending = {}	-- {kind=, token=, reply=}, checked on every wakeup

local function newconn(raw)
	local id = nextconnid
	nextconnid = nextconnid + 1
	conns[id] = raw
	return id
end

local function checkpending()
	local i = 1
	while i <= #pending do
		local p = pending[i]
		local done, result = false, nil

		if p.kind == "accept" then
			local ok, raw = platform.accept_poll(p.token)
			if ok then
				done = true
				result = raw and newconn(raw) or nil
			end
		elseif p.kind == "dial" then
			local ok, raw = platform.dial_poll(p.token)
			if ok then
				done = true
				result = raw and newconn(raw) or nil
			end
		elseif p.kind == "send" then
			local ok = platform.send_poll(p.token)
			if ok then
				done = true
				result = true
			end
		elseif p.kind == "recv" then
			local ok, data = platform.recv_poll(p.token)
			if ok then
				done = true
				result = data
			end
		end

		if done then
			sys.send(p.reply, result)
			-- each client req() transfers a fresh right in with
			-- its reply port; it must be closed once used or this
			-- exclusive task's own (finite, MAXRIGHTS-sized)
			-- rights table fills up permanently after enough
			-- requests, and the NEXT incoming right transfer
			-- fails deserialization ("corrupt message") since
			-- there's no free slot left to land it in.
			sys.close(p.reply)
			table.remove(pending, i)
		else
			i = i + 1
		end
	end
end

while true do
	local which, m = thread.alt({
		{ port = sys.SELF },
		{ port = RAWNET },
	})

	if which == 1 then
		local reply = m.reply and m.reply.__right

		if m.op == "listen" then
			local raw = platform.listen(m.port)
			sys.send(reply, raw and newconn(raw) or nil)
			sys.close(reply)
		elseif m.op == "dial" then
			local token = platform.dial_start(m.a, m.b, m.c, m.d, m.port)
			if token then
				pending[#pending + 1] =
				    { kind = "dial", token = token,
				      reply = reply }
			else
				sys.send(reply, nil)
				sys.close(reply)
			end
		elseif m.op == "accept" then
			local token = conns[m.connid] and
			    platform.accept_start(conns[m.connid])
			if token then
				pending[#pending + 1] =
				    { kind = "accept", token = token,
				      reply = reply }
			else
				sys.send(reply, nil)
				sys.close(reply)
			end
		elseif m.op == "send" then
			local token = conns[m.connid] and
			    platform.send_start(conns[m.connid], m.data)
			if token then
				pending[#pending + 1] =
				    { kind = "send", token = token,
				      reply = reply }
			else
				sys.send(reply, false)
				sys.close(reply)
			end
		elseif m.op == "recv" then
			local token = conns[m.connid] and
			    platform.recv_start(conns[m.connid], m.maxlen)
			if token then
				pending[#pending + 1] =
				    { kind = "recv", token = token,
				      reply = reply }
			else
				sys.send(reply, nil)
				sys.close(reply)
			end
		elseif m.op == "close" then
			if conns[m.connid] then
				platform.close(conns[m.connid])
				conns[m.connid] = nil
			end
		end
	end

	-- a netport wakeup (which==2) or a just-issued op might already
	-- be resolvable; always recheck.
	checkpending()
end
