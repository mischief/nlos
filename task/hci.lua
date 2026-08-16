-- hci: the sole task holding los.platform.hci (raw bluetooth packets).
-- Others hold a send right to this mailbox and talk by message:
--
--   {op="send", data=<packet>, reply={__right=}} -> {ok=<bool>}
--   {op="listen", port={__right=}, reply=}       -> {ok=<bool>}
--   {op="stats", reply=}                         -> {packets=,drops=,sram=}

-- Packets carry the H4 type byte a uart transport would deliver: 0x04
-- for an event, 0x02 for ACL data. So lib/ble reads the same bytes here
-- as it does against a socket on the host. This task is the whole of
-- BLE in C; GAP, L2CAP, ATT and GATT are Lua above it, for the reason
-- eth.lua gives about ip -- the controller is a device, protocol is
-- policy.

local sys = require("los.sys")
local thread = require("los.thread")
local hci = require("los.platform.hci")
local buf = require("los.buf")

-- the kernel's wakeup, granted at spawn. Carries no data: it means only
-- "the controller handed something up, ask it again".
local RAWHCI = 1

-- send rights to the ports of everyone who asked to see packets.
local listeners = {}

local function reply(m, msg)
	local h = type(m.reply) == "table" and m.reply.__right or nil

	if h then
		sys.send(h, msg)
		sys.close(h)
	end
end

-- Every packet goes to every listener, as eth.lua does with frames: one
-- HCI stream can interest the host stack and a btsnoop trace at once,
-- and a trace seeing only what the stack ignored would be no use.
local function drain()
	while #listeners > 0 do
		local pkt = hci.recv()

		if not pkt then
			return
		end

		local msg = { data = pkt }
		local live = {}

		for _, h in ipairs(listeners) do
			local ok, why = sys.send(h, msg)

			if ok or why == "full" then
				live[#live + 1] = h
			else
				sys.close(h)	-- hung up; stop copying to it
			end
		end
		listeners = live
	end
end

-- listen pushes rather than answering, which is what makes receiving
-- correct: a controller sends unsolicited events -- a connection
-- completing, an advertising report -- when no client is asking, and a
-- request/reply recv reaches only a caller standing there at that
-- instant. eth.lua makes the same argument at length.
while true do
	local which, m = thread.alt({
		{ port = sys.SELF },
		{ port = RAWHCI },
	})

	if which == 2 then
		drain()
	elseif m.op == "send" then
		reply(m, { ok = (type(m.data) == "string" or
		    buf.is(m.data)) and hci.send(m.data) or false })
	elseif m.op == "listen" then
		local h = type(m.port) == "table" and m.port.__right or nil

		if h then
			listeners[#listeners + 1] = h
			reply(m, { ok = true })
			-- whatever the controller already handed up is this
			-- listener's too, and there may be no further
			-- wakeup to come back on.
			drain()
		else
			reply(m, { ok = false, err = "listen needs a port right" })
		end
	elseif m.op == "stats" then
		reply(m, hci.stats())
	else
		reply(m, { err = "unknown op" })
	end
end
