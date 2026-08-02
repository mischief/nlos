-- srvc: the client side of lib/srvd.lua.
--
-- Separate from srvfs.lua because these are different things: this
-- moves rights, that shows names. See srvd.lua on why a capability
-- cannot come out of a read().

local sys = require("los.sys")
local thread = require("los.thread")

local M = {}

-- thread.rpc owns minting and closing the reply right. Hand-rolling it
-- here spent one of MAXRIGHTS per call and got away with it only
-- because a srv conversation is short -- lib/ethwire.lua wrote the same
-- four lines and ran out mid-DHCP.
local function rpc(srv, msg)
	local r = thread.rpc(srv, msg)

	if not r then
		return nil, "srv: no reply"
	end
	if not r.ok then
		return nil, r.err or "srv: failed"
	end
	return r
end

-- publish `right` under `name`, and take ownership of it: srvd gets its
-- own copy, which is what lets a service outlive the proc that posted
-- it, and the caller's is closed here.
--
-- "given away" is what this comment used to say, and it was the same
-- misreading that has cost this tree five leaks: sending COPIES, so a
-- caller that mints a right to post and then treats it as gone keeps
-- spending one of MAXRIGHTS per post. Closing it here rather than
-- asking every caller to is what makes the sentence above true.
function M.post(srv, name, right)
	local r, err = rpc(srv, { op = "post", name = name,
	    port = { __right = right } })

	pcall(sys.close, right)

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
