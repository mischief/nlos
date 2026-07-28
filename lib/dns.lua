-- dns: resolves hostnames to IPv4 addresses via a plain-lua dns codec
-- (query building + response parsing, same string.pack/unpack style
-- ninep.lua uses) riding on top of the udp task's capability. NOT a
-- kernel-level exclusive task -- it has no raw efi access of its own,
-- just an ordinary spawned proc holding a udp right, same shape as
-- the 9p-over-tcp/wire servers in init.lua. protocol:
--   {op="resolve", name=, reply={__right=}} -> "a.b.c.d" string or nil
--
-- udp is inherently lossy: a query or its reply can just vanish, so
-- this can't use caps.lua's blocking udp.recv() (thread.recv() with
-- no timeout -- a lost reply would hang this task forever). instead
-- it sends the request and polls its own reply port directly
-- (sys.tryrecv) against a real wall-clock deadline (sys.ticks()),
-- and explicitly cancels the outstanding recv if the deadline passes
-- -- see lib/udp.lua's "cancel" op -- so a lost reply doesn't leak a
-- pending entry in udp.lua's own table forever either.

local sys = require("los.sys")
local thread = require("los.thread")
local caps = require("caps")

local spack, sunpack = string.pack, string.unpack

-- qemu's slirp usermode networking answers dns at this fixed address
-- (the gateway's .3, a slirp convention); a real deployment would
-- learn this from dhcp option 6, which nothing here parses yet.
local RESOLVER = { 10, 0, 2, 3 }
local RESOLVER_PORT = 53

-- sys.ticks() is a raw TSC read, so these are cycle counts, not
-- seconds: roughly a fifth of a second per attempt on a ~2GHz part,
-- four attempts before giving up. udp is lossy by nature and a lost
-- query or reply is normal, not exceptional.
local ATTEMPTS = 4
local ATTEMPT_CYCLES = 500000000
local OPEN_RETRY_CYCLES = 1000000000

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
do
	local function spin(cycles)
		local t0 = sys.ticks()
		while sys.ticks() - t0 < cycles do
			sys.yield()
		end
	end

	for _ = 1, 60 do
		conn = udp.open(0)	-- 0: firmware picks an ephemeral port
		if conn then
			break
		end
		spin(OPEN_RETRY_CYCLES)
	end
end

local nextid = 1

-- one query attempt: send, poll our own reply port up to `cycles`
-- worth of sys.ticks(), cancel-and-give-up if nothing arrived.
local function try_once(query, id, cycles)
	local replyport = sys.newport()

	sys.send(udph, { op = "recv", connid = conn, maxlen = 512,
	    reply = { __right = replyport } })
	if not udp.send(conn, RESOLVER[1], RESOLVER[2], RESOLVER[3],
	    RESOLVER[4], RESOLVER_PORT, query) then
		sys.send(udph, { op = "cancel", connid = conn })
		thread.recv(replyport)	-- drain the now-aborted recv's reply
		sys.close(replyport)
		return nil
	end

	local t0 = sys.ticks()
	while sys.ticks() - t0 < cycles do
		local ok, r = sys.tryrecv(replyport)
		if ok then
			sys.close(replyport)
			if r then
				return safe_parse(r.data, id)
			end
			return nil
		end
		sys.yield()
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
		local ip = try_once(build_query(name, id), id, ATTEMPT_CYCLES)
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
