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

-- Each machine names its own config: what a board runs and what a
-- machine with a disk runs are different lists, and one file that
-- branched on the difference would describe neither plainly.
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
-- opts.seed      function(n) -> n bytes of entropy, optional
--
-- opts.seed exists because entropy is DATA, not authority. There is
-- nothing to attenuate about a random number and nothing a service could
-- escalate with one, so it does not want a right and a right is not what
-- it gets: every service is handed its own independent 32-byte seed in
-- its spawn arg, and expands it itself (lib/crypto/drbg.lua). The raw
-- draw stays where it has to be -- los.platform.rng exists in the boot
-- proc alone, because there the C function IS the capability.
--
-- Each service gets a DIFFERENT seed, which is why this is a function
-- rather than a string: one compromised service must not be able to
-- predict another's keys.
-- what a `caps` or `optcaps` list means, one (argname, capname) at a
-- time. `"tcp"` names the capability and calls it that in the arg;
-- `net = "tcp"` names the same capability and calls it `net`, which is
-- how a task written against one name takes a machine's other name for
-- the same thing. Array entries come first and in order, so the
-- capability a machine is missing is reported the same way every boot.
local function caps(t)
	local i, seen, out = 0, {}, {}

	for n, cap in ipairs(t or {}) do
		out[n], seen[n] = { cap, cap }, true
	end
	for k, v in pairs(t or {}) do
		if not seen[k] then
			out[#out + 1] = { k, v }
		end
	end
	return function()
		i = i + 1
		if out[i] then
			return out[i][1], out[i][2]
		end
	end
end

function M.start(list, opts)
	local started, skipped = {}, {}
	local log = opts.log or function() end

	for _, e in ipairs(list or {}) do
		local name = e.name or
		    tostring(e.path):match("([^/]+)%.lua$") or "svc"
		local src = e.path and opts.readfile(e.path)
		local arg = { args = e.args or {} }

		if opts.seed then
			arg.seed = opts.seed(32)
		end
		local missing = nil

		-- what has to exist without being handed over. An export of
		-- /n/gefs is pointless on a machine with no disk and holds no
		-- right to gefssrv either: it reaches the volume through the
		-- namespace, as any other reader does.
		for _, cap in ipairs(e.needs or {}) do
			if not opts.granted[cap] then
				missing = cap
				break
			end
		end

		for as, cap in caps(e.caps) do
			if missing then
				break
			end
			local h = opts.granted[cap]

			if h then
				arg[as] = { __right = h }
			else
				missing = cap
				break
			end
		end

		-- optcaps: handed over where the machine has them, absent
		-- where it does not, and never a reason to skip. A panel
		-- terminal wants the network so its programs can reach it
		-- and is still a terminal without one -- where naming tcp
		-- in caps would stop the panel on a board with no stack.
		for as, cap in caps(e.optcaps) do
			local h = opts.granted[cap]

			if h then
				arg[as] = { __right = h }
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
			-- ns = false in the entry: a service that
			-- opens no file needs no namespace, and the mount
			-- stack costs more than most of them.
			local pid, h = proc.spawn(src,
			    { name = name, arg = arg,
			      ns = e.ns ~= false and opts.ns or nil })

			if pid then
				started[#started + 1] =
				    { name = name, pid = pid, handle = h }
				-- a service is a capability to whatever
				-- comes after it, since the granted table
				-- holds only what the kernel spawned. Order
				-- in the file is the dependency.
				opts.granted[e.capname or name] = h
				log("svc: " .. name .. " started as pid " ..
				    pid)

				-- a service that serves a filesystem says
				-- where it belongs, and everything started
				-- after it inherits the mount. Same rule as
				-- the capability above: order in the file
				-- is the dependency.
				-- names for rights, published into a service
				-- that keeps them. `net = "dhcpd"` offers the
				-- dhcpd capability under the name "net", which
				-- is what a shell asking to mount it says.
				for as, cap in caps(e.post) do
					local ph = opts.granted[cap]

					if ph and opts.post then
						opts.post(h, as, ph)
					end
				end

				if e.mount and opts.mount then
					local nsd, merr =
					    opts.mount(e.mount, h,
					        e.mountfs or "mnt")

					if nsd then
						opts.ns = nsd
					else
						log("svc: " .. name .. ": " ..
						    e.mount .. ": " ..
						    tostring(merr))
					end
				end
			else
				log("svc: " .. name .. ": spawn failed")
				skipped[#skipped + 1] = name
			end
		end
	end
	return started, skipped
end

return M
