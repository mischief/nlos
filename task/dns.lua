-- dns: resolves hostnames to IPv4 addresses, riding the udp task's
-- capability. The wire format is lib/dns.lua, which this requires --
-- the same codec lib/dnsc.lua drives over the Lua stack, so a fix to
-- either transport cannot quietly disagree with the other about the
-- protocol. NOT a
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
local udpc = require("client.udp")
local dnsmsg = require("dns")

-- the resolver comes from the lease, asked for rather than mounted:
-- task/dhcpd.lua answers {op="get", name="dns"} with what /net/dns
-- holds. Reading the file instead meant adopting a namespace, and the
-- mount stack cost more than this whole proc.
--
-- the fallback is qemu slirp's fixed .3 (a slirp convention), for the
-- case where there is no lease at all: no NIC, or dhcpd never started.
local FALLBACK = { 10, 0, 2, 3 }
local RESOLVER_PORT = dnsmsg.PORT

local dhcpd = nil		-- a right, where this machine has one

-- re-asked rather than cached, because a renewal can change it and
-- because there may be no lease yet when the first query arrives. One
-- round trip is nothing next to the udp one it precedes.
local function resolver()
	local txt = dhcpd and thread.rpc(dhcpd, { op = "get", name = "dns" })
	local first = type(txt) == "table" and txt.data and
	    txt.data:match("^%s*([%d%.]+)")

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

-- ---- transport: manual send + poll-with-deadline (see header) ----

-- the udp right comes in the spawn arg when lib/svc.lua starts this,
-- and in a first message when a payload spawns it by hand. Named `ip`
-- by a machine whose udp is task/ip.lua, and `udp` by one whose udp is
-- the firmware's.
local a = ...
local udph = type(a) == "table" and
    ((a.ip and a.ip.__right) or (a.udp and a.udp.__right)) or nil

if not udph then
	udph = thread.recv(sys.SELF).udp.__right
end
dhcpd = type(a) == "table" and a.dhcpd and a.dhcpd.__right or nil

local udp = udpc.new(udph)

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
	local replyport = sys.newport("dns.replyport")
	-- send only; {__right=} copies the recv flag, and udp has no
	-- business receiving on our reply port
	local replyright = sys.sendright(replyport)

	local function done()
		sys.close(replyright)
		sys.close(replyport)
	end

	sys.send(udph, { op = "recv", connid = conn, maxlen = 512,
	    reply = { __right = replyright } })
	local r = resolver()

	if not udp.send(conn, r[1], r[2], r[3], r[4], RESOLVER_PORT, query) then
		sys.send(udph, { op = "cancel", connid = conn })
		thread.recv(replyport)	-- drain the now-aborted recv's reply
		done()
		return nil
	end

	local r, why = thread.recvtimeout(replyport, ms)

	if why == nil then
		done()
		if r then
			return dnsmsg.parse(r.data, id)
		end
		return nil
	end
	-- timed out: cancel so the eventually-late (or never) reply
	-- doesn't sit as an orphaned pending entry in udp.lua forever,
	-- then drain the abort-completion reply it triggers.
	sys.send(udph, { op = "cancel", connid = conn })
	thread.recv(replyport)
	done()
	return nil
end

local function resolve(name)
	if not conn then
		return nil
	end
	for _ = 1, ATTEMPTS do
		local id = nextid
		nextid = (nextid % 0xFFFF) + 1
		local ip = try_once(dnsmsg.build_query(name, id), id, ATTEMPT_MS)
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
