#!/usr/bin/env lua5.4
-- lib/dhcp.lua's codec on the host, with nothing booted. decode() and
-- lease() are transport-free, so an option a real server sends only
-- when configured to can be built by hand here.
-- TAP direct: lib/tap.lua needs los.sys.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

-- the client half of lib/dhcp.lua requires these at load. Nothing
-- below calls it -- the codec is what is under test -- so an empty
-- table is enough to get the module loaded.
package.preload["los.sys"] = function() return {} end
package.preload["los.thread"] = function() return {} end

local dhcp = require("dhcp")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
end

local function eq(got, want, name)
	ok(got == want, name .. " (got " .. tostring(got) .. ")")
end

-- ---- a reply, built option by option ----

local function ip(a, b, c, d)
	return string.char(a, b, c, d)
end

local function opt(code, data)
	return string.char(code, #data) .. data
end

-- BOOTREPLY, xid, yiaddr at 17, the cookie at 237, options from 241
local function reply(opts)
	local pkt = string.char(2, 1, 6, 0) .. string.pack(">I4", 0x1234)

	pkt = pkt .. string.rep("\0", 8)		-- secs, flags, ciaddr
	pkt = pkt .. ip(192, 168, 0, 172)		-- yiaddr at 17
	pkt = pkt .. ip(192, 168, 0, 1)			-- siaddr at 21
	pkt = pkt .. string.rep("\0", 236 - #pkt)
	pkt = pkt .. "\99\130\83\99"			-- the magic cookie
	return pkt .. opts .. string.char(255)
end

local ACK = 5

local full = dhcp.decode(reply(
    opt(53, string.char(ACK)) ..
    opt(1, ip(255, 255, 252, 0)) ..
    opt(3, ip(192, 168, 0, 1)) ..
    opt(6, ip(192, 168, 0, 1) .. ip(1, 1, 1, 1)) ..
    opt(15, "home.arpa") ..
    opt(42, ip(192, 168, 0, 1) .. ip(10, 0, 0, 5)) ..
    opt(51, string.pack(">I4", 43200)) ..
    opt(54, ip(192, 168, 0, 1))))

ok(full ~= nil, "an ack with every option decodes")
eq(full.msg_type, ACK, "message type")
eq(full.yiaddr, "192.168.0.172", "offered address")
eq(full.subnet_mask, "255.255.252.0", "subnet mask")
eq(full.router, "192.168.0.1", "router")
eq(full.domain, "home.arpa", "domain")
eq(full.lease_time, 43200, "lease time")

-- both are lists: a server may name several of each, and option 42 is
-- the one that was being thrown away
eq(#full.dns, 2, "two dns servers")
eq(full.dns[1], "192.168.0.1", "first dns server")
eq(full.dns[2], "1.1.1.1", "second dns server")
eq(#full.ntp, 2, "two ntp servers")
eq(full.ntp[1], "192.168.0.1", "first ntp server")
eq(full.ntp[2], "10.0.0.5", "second ntp server")

-- ---- absent is empty, not nil ----

local bare = dhcp.decode(reply(opt(53, string.char(ACK)) ..
    opt(1, ip(255, 255, 255, 0))))

ok(bare ~= nil, "an ack carrying almost nothing decodes")
eq(#bare.dns, 0, "no dns servers offered")
eq(#bare.ntp, 0, "no ntp servers offered")

-- ---- the lease the client keeps ----
--
-- what a caller reads. The ack is authoritative and the previous lease
-- fills what this one omits, so a renewal that repeats nothing does not
-- lose the resolver or the time source.

local l = dhcp.lease(full)

eq(l.ip, "192.168.0.172", "lease address")
eq(l.mask, "255.255.252.0", "lease mask")
eq(l.router, "192.168.0.1", "lease router")
eq(l.domain, "home.arpa", "lease domain")
-- indexed through `and`: a constructor that drops the field entirely
-- is the failure being guarded against, and it must read as one
-- rather than as an error indexing nil
eq(l.dns and l.dns[1], "192.168.0.1", "lease keeps dns")
eq(l.ntp and l.ntp[1], "192.168.0.1", "lease keeps ntp")
eq(l.ntp and #l.ntp, 2, "lease keeps every ntp server")

local renewed = dhcp.lease(bare, l)

eq(renewed.dns and renewed.dns[1], "192.168.0.1",
    "a renewal that repeats no dns keeps it")
eq(renewed.ntp and renewed.ntp[1], "192.168.0.1",
    "a renewal that repeats no ntp keeps it")
eq(renewed.domain, "home.arpa", "and keeps the domain")
eq(renewed.mask, "255.255.255.0", "but takes the mask the ack does carry")

-- ---- the request has to ask for it ----
--
-- a server sends option 42 only when it is in the parameter request
-- list, so the codec asking is half of this working.

local disc = dhcp.encode({ msg_type = 1, xid = 1, mac = "\1\2\3\4\5\6" })
local prl = disc:find(string.char(55), 240, true)

ok(prl ~= nil, "the request carries a parameter request list")
if prl then
	local n = string.byte(disc, prl + 1)
	local want = disc:sub(prl + 2, prl + 1 + n)

	ok(want:find(string.char(42), 1, true) ~= nil,
	    "and asks for the ntp servers option")
	ok(want:find(string.char(6), 1, true) ~= nil,
	    "and for the dns servers option")
end

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
