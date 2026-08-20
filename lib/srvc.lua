-- srvc: the client side of lib/srvd.lua.
--
-- Separate from srvfs.lua because these are different things: this
-- moves rights, that shows names. See srvd.lua on why a capability
-- cannot come out of a read().

local sys = require("los.sys")

local M = {}

-- thread.rpc parks the calling thread and leaves its siblings running;
-- sys.call parks the whole proc, so it is right only where there are
-- none to stall. The port is per call rather than cached: a thread owns
-- one and gives it up when it ends, a module would hold one for the
-- life of a proc that posted once. Nothing here runs in a loop.
local function ask(srv, msg)
	local thread = package.loaded["los.thread"]

	if thread then
		return thread.rpc(srv, msg)
	end

	local reply = sys.newport("srvc.reply")
	local send = sys.sendright(reply)

	-- Copied into the message rather than moved out of this proc, so
	-- both are still ours to close, and a caller that forgets spends
	-- one of MAXRIGHTS a call.
	msg.reply = { __right = send }

	local ok, r = pcall(sys.call, srv, msg, reply)

	pcall(sys.close, send)
	pcall(sys.close, reply)
	return ok and r or nil
end

local function rpc(srv, msg)
	local r = ask(srv, msg)

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
