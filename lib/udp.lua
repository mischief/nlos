-- udp: the sole task anywhere with los.platform.udp (raw udp4). also
-- holds the raw udpport recv right directly (handle 1 in this proc's
-- own table, granted by the kernel at spawn -- not a los.sys-wide
-- constant). every other proc holds, at most, a send-right to this
-- task's mailbox and talks by message:
--   {op="open", port=, reply={__right=}} -> connid or nil
--   {op="send", connid=, a=,b=,c=,d=, port=, data=, reply={__right=}}
--       -> true or false
--   {op="recv", connid=, maxlen=, reply={__right=}}
--       -> {data=, a=,b=,c=,d=, port=} (sender's address) or nil
--   {op="close", connid=}
--   {op="cancel", connid=}
--
-- separate task from tcp (lib/tcp.lua), separate port (los.sys.UDP,
-- not TCP), soft-fails independently at boot -- a firmware/NIC combo
-- missing the udp4 driver doesn't take tcp down with it, and vice
-- versa. connectionless: no listen/accept/dial, every send names its
-- destination, every recv reports the sender's.

local sys = require("los.sys")
local thread = require("los.thread")
local platform = require("los.platform.udp")

local RAWUDP = 1

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

		if p.kind == "send" then
			local ok = platform.send_poll(p.token)
			if ok then
				done = true
				result = true
			end
		elseif p.kind == "recv" then
			local ok, data, a, b, c, d, port =
			    platform.recv_poll(p.token)
			if ok then
				done = true
				result = data and
				    { data = data, a = a, b = b, c = c,
				      d = d, port = port } or nil
			end
		end

		if done then
			sys.send(p.reply, result)
			-- see lib/tcp.lua's checkpending for why this close
			-- is required, not optional.
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
		{ port = RAWUDP },
	})

	if which == 1 then
		local reply = m.reply and m.reply.__right

		if m.op == "open" then
			local raw = platform.open(m.port)
			sys.send(reply, raw and newconn(raw) or nil)
			sys.close(reply)
		elseif m.op == "send" then
			local token = conns[m.connid] and
			    platform.send_start(conns[m.connid],
			    m.a, m.b, m.c, m.d, m.port, m.data)
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
		elseif m.op == "cancel" then
			-- aborts any outstanding token on this connid WITHOUT
			-- closing it -- for a caller doing its own wall-clock
			-- retry/timeout (dns, say): the aborted token still
			-- completes normally (as an error) on the next
			-- checkpending() pass below, so whoever was waiting
			-- on it unblocks instead of hanging forever.
			if conns[m.connid] then
				platform.cancel(conns[m.connid])
			end
		end
	end

	-- a udpport wakeup (which==2) or a just-issued op might already
	-- be resolvable; always recheck.
	checkpending()
end
