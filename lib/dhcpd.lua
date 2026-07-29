-- dhcpd: the DHCP client as a proc, because a lease has to be KEPT.
--
-- lib/dhcp.lua is the protocol -- codec plus acquire/renew. this is the
-- part that has to outlive the call: a lease has a lifetime (SLIRP hands
-- out 24 hours, a real network often an hour), and an address nobody
-- renews stops working when it expires. so acquiring one in init.lua and
-- moving on would have been a boot-time trick rather than networking.
--
-- shape is lib/dns.lua's: an ordinary spawned proc, not a kernel-level
-- exclusive task, holding rights it was handed in its first message. it
-- needs two of them, which is unusual here and worth being explicit
-- about:
--
--   udp   to speak the protocol, on a socket with no address
--         (udp.open(port, true) -- see udp_open's raw case in src/net.c)
--   tcp   for hwaddr() and setaddr(), which is where the privileged
--         Ip4Config2 access lives -- the authority to ask is holding a
--         right to that task, exactly as it is for listen and dial
--
-- it answers {op="lease", reply={__right=}} with the current lease, so
-- anything that wants the DNS servers or the domain can ask rather than
-- being told at spawn time and going stale.

local sys = require("los.sys")
local thread = require("los.thread")
local caps = require("caps")
local dhcp = require("dhcp")

local m = thread.recv(sys.SELF)

if not (m and m.udp and m.tcp) then
	return
end

local tcp = caps.tcp(m.tcp.__right)
local udp = caps.udp(m.udp.__right)
local udph = m.udp.__right
local mac = tcp.hwaddr()

if not mac then
	print("dhcp: no hardware address, giving up")
	return
end

-- a lease is hours and sys.timer takes milliseconds, so wait in chunks
-- rather than trusting one enormous timer. it also means a lease query
-- gets answered within CHUNK_S rather than at the next renewal.
local CHUNK_S = 15

local lease = nil

local function serve_pending()
	while true do
		local ok, q = sys.tryrecv(sys.SELF)

		if not ok then
			return
		end
		if q and q.op == "lease" and q.reply then
			sys.send(q.reply.__right, lease)
			sys.close(q.reply.__right)
		end
	end
end

local function wait(secs)
	while secs > 0 do
		local chunk = secs > CHUNK_S and CHUNK_S or secs

		thread.sleep(chunk * 1000)
		secs = secs - chunk
		serve_pending()
	end
end

local function install(l, how)
	if not dhcp.install(tcp, l) then
		print("dhcp: could not install " .. tostring(l.ip))
		return false
	end
	print("dhcp: " .. how .. " " .. l.ip .. "/" .. tostring(l.mask) ..
	    " gw " .. tostring(l.router) ..
	    (l.dns and l.dns[1] and (" dns " .. l.dns[1]) or "") ..
	    " for " .. tostring(l.lease_time) .. "s")
	return true
end

-- RFC 2131's T1: renew at half the lease. earlier than strictly needed,
-- which is the point -- it leaves the whole second half to keep trying
-- before the address actually goes away.
local function t1(l)
	return ((l.lease_time or 3600) // 2)
end

while true do
	if not lease then
		local l, err = dhcp.acquire(udp, udph, { mac = mac })

		if l and install(l, "got") then
			lease = l
		else
			print("dhcp: " .. tostring(err or "install failed") ..
			    " -- retrying")
			-- the firmware's own DHCP is still running if we never
			-- set a static policy, so a failure here degrades to
			-- the old behaviour rather than to no network.
			wait(CHUNK_S)
		end
	end

	if lease then
		wait(t1(lease))

		local l, err = dhcp.renew(udp, udph, lease, mac)

		if l then
			-- reinstalling an unchanged address is harmless and
			-- covers the case where the server moved us
			install(l, "renewed")
			lease = l
		else
			-- half the lease left to get a new one from scratch
			print("dhcp: renew failed (" .. tostring(err) ..
			    "), reacquiring")
			lease = nil
		end
	end
end
