-- dhcpd: the DHCP client as a proc, and the lease as a filesystem.
--
-- lib/dhcp.lua is the protocol -- codec plus acquire/renew. this is the
-- part that has to outlive the call. two reasons it is a proc:
--
--   a lease has a lifetime (SLIRP hands out 24 hours, a real network
--   often an hour), and an address nobody renews stops working. so
--   acquiring one in init.lua and moving on would have been a boot-time
--   trick rather than networking.
--
--   and the answers have to be reachable. what the lease said about DNS,
--   the gateway, NTP -- something has to be able to ask, or every
--   consumer gets told once at spawn time and goes stale.
--
-- ---- the lease is a filesystem ----
--
-- which is procfs's move, for procfs's reason: "a debugger stops being a
-- program and becomes cat /proc/4/stack". network status stops being a
-- command and becomes `cat /net/lease`. mounted at /net by init.lua,
-- inherited by every child, so lib/dns.lua learns its resolver by
-- READING A FILE rather than by holding a right to this task or being
-- handed an address at spawn.
--
--	/net/lease   everything, human readable
--	/net/addr    10.0.2.15
--	/net/mask    255.255.255.0
--	/net/gw      10.0.2.2
--	/net/dns     one per line, which is what a resolver wants
--	/net/ntp     likewise, empty when the lease carried none
--	/net/domain
--	/net/ctl     write "renew" to force one now
--
-- procfs is read-only on the grounds that everything it reports is
-- structure rather than authority, and that a /proc/n/ctl able to kill a
-- proc would be authority wanting a capability. /net/ctl IS authority --
-- so note where its capability lives: this tree is served over this
-- proc's own port, so only something holding a right to this task can
-- mount it at all. the check is the mount, not a permission bit.
--
-- an ordinary spawned proc, not a kernel-level exclusive task, holding
-- rights that arrived in its spawn ARG rather than in a first message.
-- that matters here specifically: this proc's port belongs to srv.serve,
-- and a first message landing in the same queue would have to be
-- consumed before serving starts and never after -- a sequencing rule
-- with nothing enforcing it. rights travel through arg exactly as they
-- do through a message (see api_spawn's comment, and
-- test_spawnarg.lua), so the coupling simply does not exist.
--
-- it needs TWO rights, which is unusual here:
--
--	udp   to speak the protocol, on a socket with no address
--	      (udp.open(port, true) -- see udp_open's raw case in net.c)
--	tcp   for hwaddr() and setaddr(), which is where the privileged
--	      Ip4Config2 access lives. the authority to ask is holding a
--	      right to that task, exactly as it is for listen and dial.

local sys = require("los.sys")
local thread = require("los.thread")
local caps = require("caps")
local dev = require("dev")
local srv = require("srv")
local dhcp = require("dhcp")

local a = ...

if not (type(a) == "table" and a.udp and a.tcp) then
	return
end

local tcp = caps.tcp(a.tcp.__right)
local udp = caps.udp(a.udp.__right)
local udph = a.udp.__right
local mac = tcp.hwaddr()

-- ---- state ----

local lease = nil		-- the current lease, or nil while unbound
local got_at = nil		-- uptime_ms when it was installed
local kick = thread.chancreate(1)	-- /net/ctl asking for a renewal now

local function joinlines(t)
	if not t or #t == 0 then
		return ""
	end
	return table.concat(t, "\n") .. "\n"
end

local function remaining()
	if not (lease and got_at and lease.lease_time) then
		return nil
	end
	local left = lease.lease_time - (sys.uptime_ms() - got_at) // 1000

	return left > 0 and left or 0
end

-- one line per field, which is both readable and greppable. a proc that
-- wants one value reads that value's own file instead.
local function leasetext()
	if not lease then
		return "state unbound\n"
	end
	local left = remaining()

	return table.concat({
		"state bound",
		"addr " .. tostring(lease.ip),
		"mask " .. tostring(lease.mask),
		"gw " .. tostring(lease.router or ""),
		"dns " .. table.concat(lease.dns or {}, " "),
		"ntp " .. table.concat(lease.ntp or {}, " "),
		"domain " .. tostring(lease.domain or ""),
		"server " .. tostring(lease.server_id or ""),
		"lease " .. tostring(lease.lease_time or ""),
		"remaining " .. tostring(left or ""),
		"mac " .. tostring(mac or ""),
	}, "\n") .. "\n"
end

-- name -> generator. content is produced at OPEN and cached in the
-- handle, same as procfs, so a partial read cannot see half of one
-- snapshot and half of the next.
local files = {
	lease = leasetext,
	addr = function() return lease and (lease.ip .. "\n") or "" end,
	mask = function() return lease and (tostring(lease.mask) .. "\n") or "" end,
	gw = function()
		return (lease and lease.router) and (lease.router .. "\n") or ""
	end,
	dns = function() return lease and joinlines(lease.dns) or "" end,
	ntp = function() return lease and joinlines(lease.ntp) or "" end,
	domain = function()
		return (lease and lease.domain) and (lease.domain .. "\n") or ""
	end,
	ctl = function() return "" end,
}

-- ---- the backend ----

local function backend()
	local B = {}

	local function h_of(name, data)
		return { name = name, data = data }
	end

	function B.attach()
		return h_of(nil)
	end

	function B.walk(h, name)
		if h.name then
			dev.error(dev.Enotdir)
		end
		if name == ".." or name == "." then
			return h_of(nil)
		end
		if not files[name] then
			dev.error(dev.Enonexist)
		end
		return h_of(name)
	end

	function B.stat(h)
		if not h.name then
			return { name = "/", dir = true, size = 0 }
		end
		-- size is the CURRENT length, which for a synthetic file is a
		-- hint rather than a promise; readers here loop until "".
		return { name = h.name, dir = false, size = #files[h.name]() }
	end

	function B.open(h, mode)
		if not h.name then
			if mode ~= "r" then
				dev.error(dev.Eisdir)
			end
			return dev.closable(B, h_of(nil))
		end
		if mode ~= "r" and h.name ~= "ctl" then
			dev.error(dev.Eperm)
		end
		return dev.closable(B, h_of(h.name, files[h.name]()))
	end

	-- nothing here can be brought into existence, but `>` goes through
	-- create rather than open (see dos.lua's redirection, and
	-- ns:writefile), so `echo renew > /net/ctl` lands here. an existing
	-- name is therefore opened rather than refused -- which is also what
	-- a synthetic tree means: the file was always there.
	function B.create(h, name, mode)
		if h.name or not files[name] then
			dev.error(dev.Eperm)
		end
		return B.open(h_of(name), mode or "w")
	end

	function B.read(h, off, n)
		if not h.name then
			dev.error(dev.Eisdir)
		end
		local data = h.data or files[h.name]()

		return data:sub(off + 1, off + n)
	end

	-- the only writable file, and the only authority in the tree
	function B.write(h, off, data)
		if h.name ~= "ctl" then
			dev.error(dev.Eperm)
		end
		local cmd = tostring(data):gsub("%s+$", "")

		if cmd == "renew" then
			-- nbsend so a second renew while one is queued is
			-- dropped rather than blocking the writer
			kick:nbsend(true)
			return #data
		end
		dev.error(dev.Ebadarg)
	end

	function B.readdir(h)
		if h.name then
			dev.error(dev.Enotdir)
		end
		local names = {}

		for name in pairs(files) do
			names[#names + 1] = name
		end
		table.sort(names)

		local out = {}

		for _, name in ipairs(names) do
			out[#out + 1] = { name = name, dir = false,
			    size = #files[name]() }
		end
		return out
	end

	function B.clunk(_)
	end

	return B
end

-- ---- maintenance ----

-- a lease is hours and sys.timer takes milliseconds, so wait in chunks
-- rather than trusting one enormous timer. alt rather than sleep so
-- `echo renew > /net/ctl` takes effect now instead of at the next tick.
local CHUNK_S = 15

local function wait(secs)
	local left = secs

	while left > 0 do
		local chunk = left > CHUNK_S and CHUNK_S or left
		local t = sys.timer(chunk * 1000)

		if not t then
			return false
		end
		local which = thread.alt({ { c = kick, op = "recv" },
		    { port = t } })

		sys.close(t)
		if which == 1 then
			return true	-- asked for early
		end
		left = left - chunk
	end
	return false
end

local function install(l, how)
	if not dhcp.install(tcp, l) then
		print("dhcp: could not install " .. tostring(l.ip))
		return false
	end
	lease = l
	got_at = sys.uptime_ms()
	print("dhcp: " .. how .. " " .. l.ip .. "/" .. tostring(l.mask) ..
	    " gw " .. tostring(l.router) ..
	    (l.dns and l.dns[1] and (" dns " .. l.dns[1]) or "") ..
	    " for " .. tostring(l.lease_time) .. "s")
	return true
end

-- RFC 2131's T1: renew at half the lease. earlier than strictly needed,
-- which is the point -- it leaves the whole second half to keep trying
-- before the address actually goes away.
local function maintain()
	while true do
		if not lease then
			local l, err = dhcp.acquire(udp, udph, { mac = mac })

			if not (l and install(l, "got")) then
				print("dhcp: " ..
				    tostring(err or "install failed") ..
				    " -- retrying")
				wait(CHUNK_S)
			end
		end

		if lease then
			wait((lease.lease_time or 3600) // 2)

			local l, err = dhcp.renew(udp, udph, lease, mac)

			if l then
				install(l, "renewed")
			else
				-- half the lease is still left to get a new
				-- one from scratch
				print("dhcp: renew failed (" ..
				    tostring(err) .. "), reacquiring")
				lease = nil
			end
		end
	end
end

if not mac then
	print("dhcp: no hardware address, serving an unbound /net")
else
	thread.spawn(maintain)
end

-- serving and maintaining are both coroutines under one thread.run: the
-- tree has to answer while a renewal is parked on its timer, and a
-- renewal has to proceed while nobody is reading.
thread.spawn(function()
	srv.serve(backend(), sys.SELF)
end)
thread.run()
