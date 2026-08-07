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
local caps = require("caps")
local dnsmsg = require("dns")
local ns = require("ns")


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
local RESOLVER_PORT = dnsmsg.PORT

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
