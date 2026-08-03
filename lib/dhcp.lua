-- SPDX-License-Identifier: ISC
-- net/dhcp.lua - DHCP packet encode/decode (RFC 2131)

local M = {}

-- DHCP message types
M.DISCOVER = 1
M.OFFER    = 2
M.REQUEST  = 3
M.DECLINE  = 4
M.ACK      = 5
M.NAK      = 6
M.RELEASE  = 7
M.INFORM   = 8

-- DHCP option codes
M.OPT_SUBNET_MASK     = 1
M.OPT_ROUTER          = 3
M.OPT_DNS             = 6
M.OPT_HOSTNAME        = 12
M.OPT_DOMAIN          = 15
M.OPT_NTP             = 42
M.OPT_BROADCAST       = 28
M.OPT_REQUESTED_IP    = 50
M.OPT_LEASE_TIME      = 51
M.OPT_MSG_TYPE        = 53
M.OPT_SERVER_ID       = 54
M.OPT_PARAM_LIST      = 55
M.OPT_RENEWAL_TIME    = 58
M.OPT_REBINDING_TIME  = 59
M.OPT_END             = 255

local COOKIE = "\x63\x82\x53\x63"
local BOOTREQUEST = 1
local BOOTREPLY = 2
local HTYPE_ETHER = 1

-- Format an IPv4 address from 4 bytes
local function bytes_to_ip(s, offset)
	return string.format("%d.%d.%d.%d",
		string.byte(s, offset),
		string.byte(s, offset + 1),
		string.byte(s, offset + 2),
		string.byte(s, offset + 3))
end

-- Convert dotted-quad to 4 bytes
local function ip_to_bytes(ip)
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	return string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
end

-- Convert MAC string "aa:bb:cc:dd:ee:ff" to 6 bytes
function M.mac_to_bytes(mac)
	local bytes = {}
	for hex in mac:gmatch("%x%x") do
		bytes[#bytes + 1] = string.char(tonumber(hex, 16))
	end
	return table.concat(bytes)
end

-- Build a DHCP packet
-- opts: {xid, mac, ciaddr, msg_type, requested_ip, server_id, hostname}
function M.encode(opts)
	local mac_bytes = M.mac_to_bytes(opts.mac)
	local chaddr = mac_bytes .. string.rep("\0", 16 - #mac_bytes)
	local ciaddr = ip_to_bytes(opts.ciaddr or "0.0.0.0")

	-- Fixed header (236 bytes)
	local pkt = string.pack(">BBBB I4 I2 I2",
		BOOTREQUEST,  -- op
		HTYPE_ETHER,  -- htype
		6,            -- hlen
		0,            -- hops
		opts.xid,     -- xid
		0,            -- secs
		0x8000        -- flags (broadcast)
	)
	.. ciaddr                    -- ciaddr (4)
	.. "\0\0\0\0"               -- yiaddr (4)
	.. "\0\0\0\0"               -- siaddr (4)
	.. "\0\0\0\0"               -- giaddr (4)
	.. chaddr                    -- chaddr (16)
	.. string.rep("\0", 64)     -- sname (64)
	.. string.rep("\0", 128)    -- file (128)
	.. COOKIE                    -- magic cookie

	-- Options
	-- Message type (required)
	pkt = pkt .. string.char(M.OPT_MSG_TYPE, 1, opts.msg_type)

	-- Requested IP
	if opts.requested_ip then
		pkt = pkt .. string.char(M.OPT_REQUESTED_IP, 4) .. ip_to_bytes(opts.requested_ip)
	end

	-- Server identifier
	if opts.server_id then
		pkt = pkt .. string.char(M.OPT_SERVER_ID, 4) .. ip_to_bytes(opts.server_id)
	end

	-- Hostname
	if opts.hostname then
		pkt = pkt .. string.char(M.OPT_HOSTNAME, #opts.hostname) .. opts.hostname
	end

	-- Parameter request list
	pkt = pkt .. string.char(M.OPT_PARAM_LIST, 5,
		M.OPT_SUBNET_MASK, M.OPT_ROUTER, M.OPT_DNS, M.OPT_DOMAIN, M.OPT_NTP)

	-- End
	pkt = pkt .. string.char(M.OPT_END)

	-- Pad to minimum BOOTP size (300 bytes)
	if #pkt < 300 then
		pkt = pkt .. string.rep("\0", 300 - #pkt)
	end

	return pkt
end

-- Parse a DHCP reply packet
-- Returns table with: msg_type, yiaddr, siaddr, options (subnet, router, dns, domain, lease_time, server_id, etc.)
function M.decode(pkt)
	if #pkt < 240 then return nil, "packet too short" end

	local op = string.byte(pkt, 1)
	if op ~= BOOTREPLY then return nil, "not a BOOTREPLY" end

	local xid = string.unpack(">I4", pkt, 5)
	local yiaddr = bytes_to_ip(pkt, 17)
	local siaddr = bytes_to_ip(pkt, 21)

	-- Verify magic cookie at offset 237
	if pkt:sub(237, 240) ~= COOKIE then
		return nil, "bad magic cookie"
	end

	local result = {
		xid = xid,
		yiaddr = yiaddr,
		siaddr = siaddr,
		dns = {},
	}

	-- Parse options starting at byte 241
	local pos = 241
	while pos <= #pkt do
		local code = string.byte(pkt, pos)
		if code == M.OPT_END then break end
		if code == 0 then -- pad
			pos = pos + 1
		else
			if pos + 1 > #pkt then break end
			local len = string.byte(pkt, pos + 1)
			local data = pkt:sub(pos + 2, pos + 1 + len)
			pos = pos + 2 + len

			if code == M.OPT_MSG_TYPE and len == 1 then
				result.msg_type = string.byte(data, 1)
			elseif code == M.OPT_SUBNET_MASK and len == 4 then
				result.subnet_mask = bytes_to_ip(data, 1)
			elseif code == M.OPT_ROUTER and len >= 4 then
				result.router = bytes_to_ip(data, 1)
			elseif code == M.OPT_DNS then
				for i = 1, len, 4 do
					if i + 3 <= len then
						result.dns[#result.dns + 1] = bytes_to_ip(data, i)
					end
				end
			elseif code == M.OPT_NTP then
				result.ntp = result.ntp or {}
				for i = 1, len, 4 do
					if i + 3 <= len then
						result.ntp[#result.ntp + 1] = bytes_to_ip(data, i)
					end
				end
			elseif code == M.OPT_DOMAIN then
				result.domain = data
			elseif code == M.OPT_LEASE_TIME and len == 4 then
				result.lease_time = string.unpack(">I4", data)
			elseif code == M.OPT_SERVER_ID and len == 4 then
				result.server_id = bytes_to_ip(data, 1)
			elseif code == M.OPT_RENEWAL_TIME and len == 4 then
				result.renewal_time = string.unpack(">I4", data)
			elseif code == M.OPT_REBINDING_TIME and len == 4 then
				result.rebinding_time = string.unpack(">I4", data)
			end
		end
	end

	return result
end

-- ---- the client ----
--
-- everything above is a transport-free codec, ported unchanged from
-- ~/code/lua/init/net/dhcp.lua. this is the RFC 2131 four-way over a
-- udp socket that has NO address yet -- udp.open(port, true), whose
-- raw flag is what tells task/ip.lua to accept a datagram addressed to
-- a machine that does not have an address to be addressed at.
--
-- why do it ourselves at all: the firmware takes four seconds to accept
-- an offer it already has. Ip4Config2 passes Dhcp4 no callback, so
-- DhcpCallUser returns EFI_NOT_READY for Dhcp4RcvdOffer ("collect more
-- offers"), and the offer is not chosen until the first entry of
-- mDhcp4DefaultTimeout = { 4, 8, 16, 32 } expires. measured on the
-- wire: DISCOVER and OFFER 0ms apart, REQUEST 3.55s later.
--
-- that timeout is not reachable from outside. one Dhcp4 child may be
-- active at a time (Dhcp4Impl.c:678) and Ip4Config2 owns it. so the only
-- way to choose the timing is to run the protocol ourselves -- which is
-- where a policy decision belonged anyway.

local sys = require("los.sys")
local thread = require("los.thread")

M.CLIENT_PORT = 68
M.SERVER_PORT = 67

-- OUR timing, which is the entire point of the exercise. a server that
-- answers in 0ms does not want a four second collection window; it wants
-- a short deadline and a couple of retries in case a packet is lost.
M.TIMEOUT_MS = 500
M.TRIES = 4

-- "10.0.2.15" -> 10, 0, 2, 15. the codec speaks dotted quads and
-- caps.tcp's setaddr wants octets.
function M.quad(s)
	local a, b, c, d = tostring(s):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

	if not a then
		return nil
	end
	return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

-- send, then wait up to ms for a reply we recognise.
--
-- the RECEIVE IS POSTED FIRST, before the send. the server answers in
-- about no time at all, and a datagram arriving with no token waiting is
-- simply dropped -- which cost two runs to work out during the spike.
--
-- the deadline is thread.recvtimeout against our own reply port, then an
-- explicit cancel, because caps' blocking recv has no deadline of its
-- own. same shape as lib/dns.lua's try_once and for the same reason.
local function exchange(udp, udph, conn, pkt, xid, want, ms, dest)
	local replyport = sys.newport()
	local a, b, c, d = 255, 255, 255, 255

	if dest then
		a, b, c, d = dest[1], dest[2], dest[3], dest[4]
	end

	sys.send(udph, { op = "recv", connid = conn, maxlen = 1024,
	    reply = { __right = replyport } })

	if not udp.send(conn, a, b, c, d, M.SERVER_PORT, pkt) then
		sys.send(udph, { op = "cancel", connid = conn })
		thread.recv(replyport)
		sys.close(replyport)
		return nil, "send failed"
	end

	local r, why = thread.recvtimeout(replyport, ms)

	if why then
		-- cancel so the never-arriving reply does not sit as an
		-- orphaned pending entry in udp.lua forever, then drain the
		-- abort completion it triggers.
		sys.send(udph, { op = "cancel", connid = conn })
		thread.recv(replyport)
		sys.close(replyport)
		return nil, "timeout"
	end
	sys.close(replyport)
	if not (r and r.data) then
		return nil, "no data"
	end
	local reply = M.decode(r.data)

	if not reply then
		return nil, "undecodable"
	end
	-- the xid check is what makes a retry safe: a late answer to a
	-- DISCOVER we gave up on must not be read as an answer to this one.
	if reply.xid ~= xid or reply.msg_type ~= want then
		return nil, "not ours"
	end
	return reply
end

-- acquire(udp, udph, opts) -> lease, err
--
-- opts.mac is required -- the real NIC address, from caps.tcp's
-- hwaddr(). a made up one gets a lease the server associates with
-- hardware that does not exist, so nothing can then use it.
function M.acquire(udp, udph, opts)
	opts = opts or {}
	if not opts.mac then
		return nil, "no mac address"
	end

	local conn = udp.open(M.CLIENT_PORT, true)

	if not conn then
		return nil, "cannot open port " .. M.CLIENT_PORT
	end

	local err

	for try = 1, M.TRIES do
		-- a fresh xid per attempt, for the reason exchange() gives
		local xid = (sys.ticks() + try * 7919) % 0xffffffff
		local offer

		offer, err = exchange(udp, udph, conn,
		    M.encode({ xid = xid, mac = opts.mac,
		      msg_type = M.DISCOVER, hostname = opts.hostname }),
		    xid, M.OFFER, M.TIMEOUT_MS)

		if offer then
			local ack

			ack, err = exchange(udp, udph, conn,
			    M.encode({ xid = xid, mac = opts.mac,
			      msg_type = M.REQUEST,
			      requested_ip = offer.yiaddr,
			      server_id = offer.server_id,
			      hostname = opts.hostname }),
			    xid, M.ACK, M.TIMEOUT_MS)

			if ack then
				udp.close(conn)
				-- the ACK is authoritative, but a server may
				-- omit what it already said in the OFFER
				return {
					ip = ack.yiaddr,
					mask = ack.subnet_mask or
					    offer.subnet_mask,
					router = ack.router or offer.router,
					dns = (#ack.dns > 0) and ack.dns or
					    offer.dns,
					domain = ack.domain or offer.domain,
					lease_time = ack.lease_time,
					server_id = ack.server_id or
					    offer.server_id,
				}
			end
		end
	end
	udp.close(conn)
	return nil, err or "no reply"
end

-- renew(udp, udph, lease, mac) -> lease, err
--
-- RFC 2131's RENEWING: a REQUEST with ciaddr set to the address we
-- already hold and NO requested-ip or server-id option, unicast to the
-- server that granted it. a proc has to do this periodically or the
-- lease simply expires -- which is the whole reason lib/dhcpd.lua is a
-- proc and not a line in init.lua.
--
-- broadcast is the fallback when the lease carries no server id: not
-- strictly RENEWING, but every server answers it and the alternative is
-- not renewing at all.
function M.renew(udp, udph, lease, mac)
	local conn = udp.open(M.CLIENT_PORT, true)

	if not conn then
		return nil, "cannot open port " .. M.CLIENT_PORT
	end
	local dest = nil
	local sa, sb, sc, sd = M.quad(lease.server_id or "")

	if sa then
		dest = { sa, sb, sc, sd }
	end

	local err

	for try = 1, M.TRIES do
		local xid = (sys.ticks() + try * 104729) % 0xffffffff
		local ack

		ack, err = exchange(udp, udph, conn,
		    M.encode({ xid = xid, mac = mac, msg_type = M.REQUEST,
		      ciaddr = lease.ip }),
		    xid, M.ACK, M.TIMEOUT_MS, dest)

		if ack then
			udp.close(conn)
			return {
				ip = ack.yiaddr,
				mask = ack.subnet_mask or lease.mask,
				router = ack.router or lease.router,
				dns = (#ack.dns > 0) and ack.dns or lease.dns,
				domain = ack.domain or lease.domain,
				lease_time = ack.lease_time or lease.lease_time,
				server_id = ack.server_id or lease.server_id,
			}
		end
	end
	udp.close(conn)
	return nil, err or "no reply"
end

-- install a lease: hand the address to the stack, which is the only
-- thing that decides what this machine answers to.
function M.install(tcp, lease)
	local a, b, c, d = M.quad(lease.ip)
	local ma, mb, mc, md = M.quad(lease.mask or "255.255.255.0")

	if not a or not ma then
		return nil, "lease has no usable address"
	end
	local ga, gb, gc, gd = M.quad(lease.router or "")

	return tcp.setaddr(a, b, c, d, ma, mb, mc, md, ga, gb, gc, gd)
end

return M
