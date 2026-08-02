-- DHCP over the Lua stack: DISCOVER, OFFER, REQUEST, ACK (RFC 2131).
--
-- The packet codec is lib/dhcp.lua's, unchanged and unforked. That
-- module was written against lib/udp.lua -- the task that re-serves the
-- UEFI firmware's udp4 -- but only its acquire() and renew() ever touch
-- a capability; encode and decode are pure, and this drives them over
-- lib/inet.lua instead. Two transports, one understanding of the
-- protocol, which is the whole reason to keep a codec free of the thing
-- that carries it.
--
-- What is genuinely different here is that there is no firmware to have
-- configured anything first. This runs with no address: the client
-- broadcasts from 0.0.0.0 to 255.255.255.255, which lib/inet.lua's send
-- handles by not asking ARP anything, since there is nobody to ask and
-- nobody to ask about.
--
-- Replies come back broadcast because lib/dhcp.lua sets the broadcast
-- flag in every request it builds. That is not a detail to lose: a
-- server honouring it sends to 255.255.255.255, which a host with no
-- address can receive, and one ignoring it unicasts to the address it
-- is offering -- which we do not have yet and would drop.
--
-- Addresses cross the seam as dotted quads because that is what
-- lib/dhcp.lua speaks; everything on this side of it is 4-byte strings.
-- The conversions are all in this file, on purpose.

local ip4 = require("ip4")
local udp4 = require("udp4")
local ether = require("ether")
local dhcp = require("dhcp")

local dhcpc = {}

dhcpc.CLIENT_PORT = 68
dhcpc.SERVER_PORT = 67

-- our timing, and the reason lib/dhcp.lua gives for running this
-- ourselves at all: a server that answers immediately wants a short
-- deadline and a retry, not the firmware's four-second collection
-- window.
dhcpc.TIMEOUT_MS = 700
dhcpc.TRIES = 4

-- send one request and wait for the reply of the type we want.
--
-- Other traffic keeps arriving throughout -- this is a broadcast
-- segment and DHCP is the noisiest thing on it -- so everything that is
-- not our transaction is discarded rather than being an error. The xid
-- is what makes a reply ours; without checking it, another host's lease
-- would be taken as our own.
local function exchange(host, pkt, xid, want, timeout_ms)
	local ok, why = host:udp_send(ip4.BROADCAST, dhcpc.CLIENT_PORT,
	    dhcpc.SERVER_PORT, pkt)

	if not ok then
		return nil, why
	end

	local deadline = host.wire.now() + timeout_ms

	while host.wire.now() < deadline do
		local p = host:pump(100)

		if p and p.proto == ip4.PROTO_UDP then
			local d = udp4.decode(p.payload, p.src, p.dst)

			if d and d.dport == dhcpc.CLIENT_PORT then
				local m = dhcp.decode(d.data)

				if m and m.xid == xid and m.msg_type == want then
					return m
				end
			end
		end
	end
	return nil, "no reply"
end

local function try(host, build, xid, want)
	local err

	for _ = 1, dhcpc.TRIES do
		local m

		m, err = exchange(host, build(), xid, want, dhcpc.TIMEOUT_MS)
		if m then
			return m
		end
	end
	return nil, err
end

-- acquire(host, opts) -> lease, err
--
-- lease is the shape lib/dhcp.lua's decode produces, with the addresses
-- converted to this stack's 4-byte strings: {ip=, mask=, gw=, dns=,
-- ntp=, server=, lease_time=}.
--
-- The host's own ip is set on success, since a lease that is not
-- installed is not a lease -- and because everything above this point
-- would otherwise still be sending from 0.0.0.0.
function dhcpc.acquire(host, opts)
	opts = opts or {}

	local mac = ether.mac_str(host.mac)

	-- an xid only has to be unique among transactions in flight on this
	-- segment. The clock is the only thing here that differs between
	-- two boots of the same image, so it is what distinguishes them.
	local xid = (opts.xid or (host.wire.now() * 2654435761)) & 0xffffffff

	if xid == 0 then
		xid = 1
	end

	local offer, err = try(host, function()
		return dhcp.encode({ xid = xid, mac = mac,
		    msg_type = dhcp.DISCOVER, hostname = opts.hostname })
	end, xid, dhcp.OFFER)

	if not offer then
		return nil, "no offer: " .. tostring(err)
	end

	local ack

	ack, err = try(host, function()
		return dhcp.encode({ xid = xid, mac = mac,
		    msg_type = dhcp.REQUEST,
		    requested_ip = offer.yiaddr,
		    server_id = offer.server_id,
		    hostname = opts.hostname })
	end, xid, dhcp.ACK)

	if not ack then
		return nil, "offered " .. tostring(offer.yiaddr) ..
		    " but no ack: " .. tostring(err)
	end

	-- lib/dhcp.lua puts the options at the top level of its result, not
	-- under an `options` table -- its own summary line says otherwise,
	-- and the code is what is true. dns and ntp are lists, since a
	-- server may name several of each.
	local lease = {
		ip = ip4.parse(ack.yiaddr),
		mask = ack.subnet_mask and ip4.parse(ack.subnet_mask) or nil,
		gw = ack.router and ip4.parse(ack.router) or nil,
		dns = ack.dns and ack.dns[1] and ip4.parse(ack.dns[1]) or nil,
		ntp = ack.ntp and ack.ntp[1] and ip4.parse(ack.ntp[1]) or nil,
		server = ack.server_id and ip4.parse(ack.server_id) or nil,
		domain = ack.domain,
		lease_time = ack.lease_time,
		raw = ack,
	}

	if not lease.ip then
		return nil, "ack carried no address"
	end

	host.ip = lease.ip
	host.mask = lease.mask
	host.gw = lease.gw

	return lease
end

return dhcpc
