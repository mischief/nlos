-- srvc: the client side of lib/srvd.lua.
--
-- Separate from srvfs.lua because these are different things: this
-- moves rights, that shows names. See srvd.lua on why a capability
-- cannot come out of a read().

local sys = require("los.sys")
local thread = require("los.thread")

local M = {}

local function rpc(srv, msg)
	local reply = thread.replyport()

	msg.reply = { __right = sys.sendright(reply) }

	local ok, sent = pcall(sys.send, srv, msg)

	if not ok or not sent then
		return nil, "srv: not answering"
	end

	local r = thread.recv(reply)

	if not r then
		return nil, "srv: no reply"
	end
	if not r.ok then
		return nil, r.err or "srv: failed"
	end
	return r
end

-- publish `right` under `name`. The right is GIVEN AWAY: srvd holds it
-- from here on, which is what lets a service outlive the proc that
-- posted it.
function M.post(srv, name, right)
	local r, err = rpc(srv, { op = "post", name = name,
	    port = { __right = right } })

	return r and true or nil, err
end

-- pick up a right by name. Each call gets its own send-right, so two
-- callers opening one name do not share a handle.
function M.open(srv, name)
	local r, err = rpc(srv, { op = "open", name = name })

	if not r then
		return nil, err
	end
	if not (r.port and r.port.__right) then
		return nil, "srv: reply carried no right"
	end
	return r.port.__right
end

function M.remove(srv, name)
	local r, err = rpc(srv, { op = "remove", name = name })

	return r and true or nil, err
end

function M.list(srv)
	local r, err = rpc(srv, { op = "list" })

	if not r then
		return nil, err
	end
	return r.names or {}
end

return M
