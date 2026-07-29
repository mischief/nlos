-- dns: resolves hostnames to IPv4 addresses via a plain-lua dns codec
-- (query building + response parsing, same string.pack/unpack style
-- ninep.lua uses) riding on top of the udp task's capability. NOT a
-- kernel-level exclusive task -- it has no raw efi access of its own,
-- just an ordinary spawned proc holding a udp right, same shape as
-- the 9p-over-tcp/wire servers in init.lua. protocol:
--   {op="resolve", name=, reply={__right=}} -> "a.b.c.d" string or nil
--
-- udp is inherently lossy: a query or its reply can just vanish, so
-- this can't use caps.lua's blocking udp.recv() (thread.recv() with no
-- timeout -- a lost reply would hang this task forever). instead it
-- sends the request and waits on its own reply port with a real
-- deadline (thread.recvtimeout), then explicitly cancels the
-- outstanding recv if that deadline passes -- see lib/udp.lua's
-- "cancel" op -- so a lost reply doesn't leak a pending entry in
-- udp.lua's own table forever either.

local sys = require("los.sys")
local thread = require("los.thread")
local caps = require("caps")
local ns = require("ns")

local spack, sunpack = string.pack, string.unpack

-- the resolver comes from the LEASE, by reading a file: lib/dhcpd.lua
-- serves /net/dns, one address per line, and this proc has /net in the
-- namespace it was spawned with. so option 6 arrives with no right to
-- dhcpd, no message protocol and nothing told to us at spawn time --
-- which is the whole argument for the lease being a filesystem.
--
-- the fallback is qemu slirp's fixed .3 (a slirp convention), for the
-- case where there is no /net at all: no NIC, or dhcpd never started.
-- it is a fallback rather than the default, which is the difference from
-- how this used to work.
local FALLBACK = { 10, 0, 2, 3 }
local RESOLVER_PORT = 53

-- re-read rather than cached, because a renewal can change it and
-- because /net may not have a lease yet when the first query arrives.
-- one namespace read per resolve is nothing next to a udp round trip.
local function resolver()
	local N = ns.current()
	local txt = N and N:readfile("/net/dns")
	local first = txt and txt:match("^%s*([%d%.]+)")

	if first then
		local a, b, c, d =
		    first:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

		if a then
			return { tonumber(a), tonumber(b), tonumber(c),
			    tonumber(d) }
		end
	end
	return FALLBACK
end

-- real milliseconds, via thread.sleep/recvtimeout. these used to be raw
-- tsc cycle counts, which meant the same constant was a different
-- duration on every machine -- and on the machine they were written on
-- the "fifth of a second" attempt window was actually 111ms, so a
-- resolve gave up after 444ms total. that is far too tight for a real
-- upstream. udp is lossy by nature and a lost query or reply is normal,
-- not exceptional, so retry generously.
local ATTEMPTS = 4
local ATTEMPT_MS = 1000
local OPEN_RETRY_MS = 250

-- ---- codec ----

local function encode_qname(name)
	local parts = {}
	for label in name:gmatch("[^.]+") do
		parts[#parts + 1] = spack("s1", label)
	end
	parts[#parts + 1] = "\0"
	return table.concat(parts)
end

local function build_query(name, id)
	-- header: ID, flags (0x0100 = standard query, recursion desired),
	-- QDCOUNT=1, ANCOUNT/NSCOUNT/ARCOUNT=0
	local header = spack(">I2I2I2I2I2I2", id, 0x0100, 1, 0, 0, 0)
	-- question: QNAME, QTYPE=1 (A), QCLASS=1 (IN)
	local question = encode_qname(name) .. spack(">I2I2", 1, 1)
	return header .. question
end

-- a NAME field in the question section is always literal labels (we
-- wrote it ourselves); in the answer section it may instead be a
-- compression pointer (top two bits of the length byte set) pointing
-- back at the question -- we only need to skip past it, never
-- resolve what it points to.
local function skip_qname(buf, off)
	while true do
		local len = buf:byte(off)
		if not len or len == 0 then
			return off + 1
		end
		off = off + 1 + len
	end
end

local function skip_name(buf, off)
	local len = buf:byte(off)
	if len and (len & 0xC0) == 0xC0 then
		return off + 2
	end
	return skip_qname(buf, off)
end

-- returns "a.b.c.d" on success, or nil + a reason on failure.
--
-- called only through safe_parse below: every sunpack here can throw
-- on a truncated buffer, and the source of these bytes is a udp
-- datagram from the network, which anything on the wire can forge and
-- truncate. an uncaught throw would take the whole dns task down --
-- permanently, for every client -- on one malformed packet.
local function parse_response(buf, expect_id)
	if #buf < 12 then
		return nil, "short reply"
	end
	local id, flags, qdcount, ancount = sunpack(">I2I2I2I2", buf)
	if id ~= expect_id then
		return nil, "id mismatch"
	end
	if (flags & 0xF) ~= 0 then
		return nil, "rcode " .. (flags & 0xF)
	end
	local off = 13	-- 1-based, right after the 12-byte header
	for _ = 1, qdcount do
		off = skip_qname(buf, off) + 4	-- +2 QTYPE, +2 QCLASS
	end
	for _ = 1, ancount do
		off = skip_name(buf, off)
		local rtype, rclass, ttl, rdlen
		rtype, rclass, ttl, rdlen, off = sunpack(">I2I2I4I2", buf, off)
		if rtype == 1 and rclass == 1 and rdlen == 4 then
			local a, b, c, d = buf:byte(off, off + 3)
			return string.format("%d.%d.%d.%d", a, b, c, d)
		end
		off = off + rdlen
	end
	return nil, "no A record"
end

local function safe_parse(buf, expect_id)
	local ok, ip, why = pcall(parse_response, buf, expect_id)

	if not ok then
		return nil, "malformed reply"
	end
	return ip, why
end

-- ---- transport: manual send + poll-with-deadline (see header) ----

local m0 = thread.recv(sys.SELF)
local udph = m0.udp.__right
local udp = caps.udp(udph)

local conn
for _ = 1, 60 do
	conn = udp.open(0)	-- 0: firmware picks an ephemeral port
	if conn then
		break
	end
	thread.sleep(OPEN_RETRY_MS)	-- waiting for dhcp; park, don't spin
end

local nextid = 1

-- one query attempt: send, wait up to `ms` for our own reply port,
-- cancel-and-give-up if nothing arrived.
local function try_once(query, id, ms)
	local replyport = sys.newport()

	sys.send(udph, { op = "recv", connid = conn, maxlen = 512,
	    reply = { __right = replyport } })
	local r = resolver()

	if not udp.send(conn, r[1], r[2], r[3], r[4], RESOLVER_PORT, query) then
		sys.send(udph, { op = "cancel", connid = conn })
		thread.recv(replyport)	-- drain the now-aborted recv's reply
		sys.close(replyport)
		return nil
	end

	local r, why = thread.recvtimeout(replyport, ms)

	if why == nil then
		sys.close(replyport)
		if r then
			return safe_parse(r.data, id)
		end
		return nil
	end
	-- timed out: cancel so the eventually-late (or never) reply
	-- doesn't sit as an orphaned pending entry in udp.lua forever,
	-- then drain the abort-completion reply it triggers.
	sys.send(udph, { op = "cancel", connid = conn })
	thread.recv(replyport)
	sys.close(replyport)
	return nil
end

local function resolve(name)
	if not conn then
		return nil
	end
	for _ = 1, ATTEMPTS do
		local id = nextid
		nextid = (nextid % 0xFFFF) + 1
		local ip = try_once(build_query(name, id), id, ATTEMPT_MS)
		if ip then
			return ip
		end
	end
	return nil
end

while true do
	local m = thread.recv(sys.SELF)
	if m.op == "resolve" then
		local reply = m.reply and m.reply.__right
		sys.send(reply, resolve(m.name))
		sys.close(reply)
	end
end
