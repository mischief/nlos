-- nostrrelay: NIP-01 over a websocket.
--
--	local relay = require("nostrrelay")
--	local r = relay.connect(net, dns, "wss://relay.example", rand)
--	r:req("sub", { kinds = { 1 }, limit = 20 })
--	local what, sub, ev = r:next()

-- The events themselves are lib/nostr.lua, which comes from the ssh
-- tree and knows nothing of sockets. This half stays here: it needs
-- json and a machine to talk to, and that tree has neither.

local json = require("json")

local M = {}

local Relay = {}

Relay.__index = Relay

function M.connect(net, dns, url, rand)
	local websocket = require("websocket")
	local ws, err = websocket.connect(net, dns, url, { rand = rand })

	if not ws then
		return nil, err
	end
	return setmetatable({ ws = ws, url = url }, Relay)
end

-- a relay over a websocket somebody else opened, for a machine whose
-- network is websockets and has no socket to build one on. Everything
-- below this line cannot tell the two apart: send a string, get a
-- string.
function M.attach(ws, url)
	if not ws then
		return nil, "no websocket"
	end
	return setmetatable({ ws = ws, url = url }, Relay)
end

function Relay:send(msg)
	return self.ws:send(json.encode(msg))
end

-- ask for what a relay holds. Filters are NIP-01's: kinds, authors,
-- limit, since, until.
function Relay:req(sub, ...)
	local msg = { "REQ", sub }

	for _, f in ipairs({ ... }) do
		msg[#msg + 1] = f
	end
	return self:send(msg)
end

function Relay:close_sub(sub)
	return self:send({ "CLOSE", sub })
end

function Relay:publish(ev)
	return self:send({ "EVENT", ev })
end

-- next() -> what, a, b, c
--	"event" sub, event   "eose" sub   "notice" text
--	"ok" id, accepted, and the relay's reason when it is not
--	"closed" sub, why    nil, why when the connection is gone
function Relay:next()
	while true do
		local raw, why = self.ws:recv()

		if not raw then
			return nil, why
		end

		local ok, msg = pcall(json.decode, raw)

		if ok and type(msg) == "table" and type(msg[1]) == "string" then
			local kind = msg[1]

			if kind == "EVENT" and type(msg[3]) == "table" then
				return "event", msg[2], msg[3]
			elseif kind == "EOSE" then
				return "eose", msg[2]
			elseif kind == "OK" then
				return "ok", msg[2], msg[3] == true, msg[4]
			elseif kind == "NOTICE" then
				return "notice", msg[2]
			elseif kind == "CLOSED" then
				return "closed", msg[2], msg[3]
			end
		end
		-- anything else is a message this does not speak, and
		-- skipping it is what NIP-01 asks of a client
	end
end

function Relay:alive()
	return self.ws:alive()
end

function Relay:close()
	self.ws:close()
end

return M
