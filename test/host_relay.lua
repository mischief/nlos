#!/usr/bin/env lua5.4
-- lib/bitchat/relay.lua: what is passed on, and what stops here.
--
-- A mesh needs three radios to watch properly and there are two here,
-- so what is checked is the decision rather than the delivery.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" ..
    scriptdir .. "/../lib/?/init.lua;" .. package.path

local relay = require("bitchat.relay")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
	io.flush()
end

local ME = "MEMEMEME"
local THEM = "THEMTHEM"
local clock = 0

local function newrelay()
	clock = 0
	return relay.new({ me = ME, now = function() return clock end,
	    -- the midpoint, so a delay is a number a test can name
	    random = function(a, b) return (a + b) // 2 end })
end

local function packet(o)
	return {
		type = o.type or 0x02, ttl = o.ttl or 7,
		timestamp = o.timestamp or 1000, sender = o.sender or THEM,
		recipient = o.recipient, payload = o.payload or "hello",
	}
end

-- ---- what stops here ----

local R = newrelay()

ok(R:decide(packet({ sender = ME }), 1) == nil, "our own packet is not relayed")
ok(R:decide(packet({ recipient = ME }), 1) == nil, "nor one addressed to us")
ok(R:decide(packet({ ttl = 1 }), 1) == nil, "nor one with one hop left")
ok(R:decide(packet({ ttl = 0 }), 1) == nil, "nor one with none")

-- ---- the ttl ----

local ttl = R:decide(packet({ ttl = 7 }), 1)

ok(ttl == 6, "a hop is taken off")

-- a peer claiming more hops than the protocol allows gets the cap, so
-- one packet cannot be made to circulate.
ok(R:decide(packet({ ttl = 255 }), 1) == 6, "an absurd ttl is capped first")
ok(R:decide(packet({ ttl = 200 }), 1) == 6, "however absurd")

-- density shortens a broadcast: in a crowd our copy is the redundant one.
ok(R:decide(packet({ ttl = 7 }), 2) == 6, "at the edge the ttl is untouched")
ok(R:decide(packet({ ttl = 7 }), 4) == 5, "in company it is cut to six")
ok(R:decide(packet({ ttl = 7 }), 8) == 4, "in a crowd to five")

-- a directed packet keeps its hops whatever the density: it is going
-- somewhere rather than everywhere.
ok(R:decide(packet({ ttl = 7, recipient = "SOMEBODY" }), 8) == 6,
    "a directed packet is not shortened")

-- ---- the delay ----

local _, ms = R:decide(packet({}), 1)

ok(ms == 25, "a quiet node relays soon")
_, ms = R:decide(packet({}), 4)
ok(ms == 105, "a busier one waits")
_, ms = R:decide(packet({}), 8)
ok(ms == 130, "and a crowded one longer")
_, ms = R:decide(packet({}), 20)
ok(ms == 160, "past what the radio will hold")
_, ms = R:decide(packet({ recipient = "SOMEBODY" }), 1)
ok(ms == 40, "a directed packet has its own wait")

-- ---- what has been through here before ----

R = newrelay()

local p = packet({})

ok(R:seen(p) == false, "a packet is new once")
ok(R:seen(p) == true, "and known after that")

-- the same bytes at a different hop count is the same packet: that is
-- what dedup is for, so the ttl must not be in the key.
ok(R:seen(packet({ ttl = 3 })) == true, "a relayed copy is the same packet")

-- and these are all different packets.
ok(R:seen(packet({ timestamp = 1001 })) == false, "another time is another")
ok(R:seen(packet({ payload = "other" })) == false, "so is other content")
ok(R:seen(packet({ sender = "SOMEBODY" })) == false, "and another sender")
ok(R:seen(packet({ type = 0x01 })) == false, "and another type")

-- two messages in the same millisecond from one sender are two
-- messages: sender and time alone would call the second a duplicate.
R = newrelay()
ok(R:seen(packet({ payload = "a" })) == false, "one packet")
ok(R:seen(packet({ payload = "b" })) == false,
    "and another in the same millisecond")

-- ---- the seen set does not grow forever ----

R = newrelay()
R:seen(packet({ timestamp = 1 }))
clock = relay.MAXAGE + 1
R:seen(packet({ timestamp = 2 }))
ok(R.keys[relay.key(packet({ timestamp = 1 }))] == nil,
    "a key older than the window is dropped")

R = newrelay()
for i = 1, relay.MAXSEEN + 50 do
	R:seen(packet({ timestamp = i }))
end
ok(#R.order <= relay.MAXSEEN, "and the set is bounded by count too")
ok(R:seen(packet({ timestamp = relay.MAXSEEN + 50 })) == true,
    "with the newest still known")

io.write("1.." .. count .. "\n")
os.exit(failed == 0 and 0 or 1)
