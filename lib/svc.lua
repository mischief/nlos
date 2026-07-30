-- svc: start the services this machine is configured to run.
--
-- ---- why this exists ----
--
-- a fw_cfg payload REPLACES init.lua. that is right for a test, which
-- wants a bare kernel and no init opinions, and must stay testable even
-- when init itself is broken. it is wrong for anything that wants a
-- working machine and then its own program on top -- and using it that
-- way is what left four separate payloads each re-implementing DHCP,
-- three of them silently doing without it.
--
-- so: a test still replaces init. everything else is a SERVICE, started
-- by init once the machine is up. test/boot/srvweb.lua was ~130 lines of
-- which about 100 were init's job done worse; svc/webterm.lua is what is
-- left after deleting them.
--
-- ---- the config is a capability grant table ----
--
-- an entry declares what it needs by name:
--
--	{ path = "/svc/webterm.lua", caps = { "tcp" },
--	  args = { port = 7777 } }
--
-- and `caps` is not documentation. those names are looked up in
-- sys.granted() and the resulting rights are ALL the authority the
-- service gets -- it has no path to anything it did not name, because
-- rights only arrive in a message or a spawn arg and nothing else was
-- put in either. one file therefore says what every service on the
-- machine may touch, which is the thing unix would want users and mode
-- bits for.
--
-- a service that names a capability this machine does not have (tcp on a
-- box with no NIC) is SKIPPED rather than started to fail. that is the
-- same "an absent key means the machine does not have it" test
-- sys.granted() is built around.
--
-- ---- how a service receives it ----
--
-- through the spawn ARG, not a first message, so it is there before the
-- service's first line -- which matters because that line is usually a
-- require. see api_spawn's comment on opts.arg, and lib/dhcpd.lua for
-- the other reason to prefer it.
--
--	local a = ...
--	local tcp = caps.tcp(a.tcp.__right)
--	local port = a.args.port

local proc = require("proc")

local M = {}

-- load a config: a lua chunk returning a list of entries. it is CODE
-- rather than data on purpose -- the same reason meson.build is code --
-- so a machine can decide what to run from what it can see, without this
-- module growing a conditional syntax.
--
-- returns the list, or nil plus a reason. a missing config is not an
-- error: a machine with no services is a perfectly good machine.
function M.parse(src, name)
	local chunk, err = load(src, "=" .. name, "t")

	if not chunk then
		return nil, err
	end
	local ok, list = pcall(chunk)

	if not ok then
		return nil, list
	end
	if type(list) ~= "table" then
		return nil, name .. " did not return a list"
	end
	return list
end

function M.load(ns, path)
	local src = ns:readfile(path)

	if not src then
		return nil, "no " .. path
	end
	return M.parse(src, path)
end

-- start(list, opts) -> started, skipped
--
-- opts.ns        namespace to hand each service (a description)
-- opts.granted   sys.granted(), where declared caps are looked up
-- opts.readfile  function(path) -> source
-- opts.log       function(msg), optional
function M.start(list, opts)
	local started, skipped = {}, {}
	local log = opts.log or function() end

	for _, e in ipairs(list or {}) do
		local name = e.name or
		    tostring(e.path):match("([^/]+)%.lua$") or "svc"
		local src = e.path and opts.readfile(e.path)
		local arg = { args = e.args or {} }
		local missing = nil

		for _, cap in ipairs(e.caps or {}) do
			local h = opts.granted[cap]

			if h then
				arg[cap] = { __right = h }
			else
				missing = cap
				break
			end
		end

		if not src then
			log("svc: " .. name .. ": cannot read " ..
			    tostring(e.path))
			skipped[#skipped + 1] = name
		elseif missing then
			-- not a failure. the machine simply does not have it.
			log("svc: " .. name .. ": no " .. missing ..
			    " capability, skipping")
			skipped[#skipped + 1] = name
		else
			local pid, h = proc.spawn(src,
			    { name = name, ns = opts.ns, arg = arg })

			if pid then
				started[#started + 1] =
				    { name = name, pid = pid, handle = h }
				log("svc: " .. name .. " started as pid " ..
				    pid)
			else
				log("svc: " .. name .. ": spawn failed")
				skipped[#skipped + 1] = name
			end
		end
	end
	return started, skipped
end

return M
