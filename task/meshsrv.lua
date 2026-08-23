-- meshsrv: a mesh over the radio, for whoever asks.
--
--	{op="recv"}  {op="send", text=, to=}  {op="nodes"}  {op="status"}
--
-- What this adds over the lora task is the protocol: keys, dedup, and
-- who is out there.

local sys = require("los.sys")
local thread = require("los.thread")
local mt = require("meshtastic")
local svcarg = require("svcarg")

local init, cfg = svcarg(...)
local lora = init and init.lora and init.lora.__right

if not lora then
	sys.log("meshsrv: no radio")
	return
end

-- ids and this node's number come from here. A node number is not
-- authority and nothing is encrypted with it, so what matters is that
-- two machines rarely pick the same one -- the seed a service is
-- handed, or the clock where it was handed none.
local seed = cfg.seed and string.unpack("<I4", cfg.seed) or
    (sys.uptime_ms() * 2654435761) & 0xffffffff

local function rand()
	seed = (seed * 1103515245 + 12345) & 0xffffffff
	return seed
end

-- the top bit set, which is what their firmware does for a number it
-- made up rather than one from a hardware address
local me = rand() | 0x80000000
local name = cfg.name or "lua-os"
local key = mt.DEFAULTKEY
local channel = mt.channelhash("", key)

local inbox = {}	-- decoded, waiting for a client
local nodes = {}	-- number -> what it has told us
local seen = {}		-- (from,id) -> when, so a flood is heard once
local nseen = 0
local counters = { rx = 0, tx = 0, dup = 0, undecoded = 0 }

local reply = sys.newport("meshsrv.reply")
local right = sys.sendright(reply)

local function ask(m, secs)
	m.reply = { __right = right }

	local ok = sys.send(lora, m)

	if not ok then
		return nil
	end
	return thread.recvtimeout(reply, (secs or 5) * 1000)
end

-- ---- what the radio has to be told ----

local function configure()
	local p = mt.PRESETS.LONG_FAST
	local freq = mt.slot("LongFast", mt.REGIONS.US, p.bw)

	return ask({ op = "config", freq = math.floor(freq * 1e6),
	    sf = p.sf, bw = p.bw, cr = p.cr, sync = mt.SYNCWORD,
	    preamble = 16 }, 15)
end

-- ---- what arrives ----

-- a flood repeats: the same packet reaches us from every neighbour that
-- rebroadcast it, so it is remembered by sender and id rather than
-- shown twice.
local function duplicate(h)
	local k = ("%08x:%08x"):format(h.from, h.id)

	if seen[k] then
		return true
	end
	seen[k] = sys.uptime_ms()
	nseen = nseen + 1

	-- bounded rather than swept: an id is a random word, so what is
	-- worth remembering is the recent past and not all of it
	if nseen > 256 then
		local old = sys.uptime_ms() - 600000

		for kk, when in pairs(seen) do
			if when < old then
				seen[kk] = nil
				nseen = nseen - 1
			end
		end
	end
	return false
end

local function note(num, fields)
	local n = nodes[num] or { num = num, id = mt.nodeid(num) }

	for k, v in pairs(fields) do
		n[k] = v
	end
	n.heard = sys.uptime_ms()
	nodes[num] = n
	return n
end

local function arrived(frame, rssi, snr)
	local h, d, why = mt.open(frame, key)

	counters.rx = counters.rx + 1
	if not h then
		counters.undecoded = counters.undecoded + 1
		return
	end
	if duplicate(h) then
		counters.dup = counters.dup + 1
		return
	end

	note(h.from, { rssi = rssi, snr = snr, hops = (h.hopstart or 0) -
	    (h.hoplimit or 0) })

	if not d then
		-- a packet for a channel whose key we have not got, which
		-- on a public mesh is most of the private ones
		counters.undecoded = counters.undecoded + 1
		sys.log(("meshsrv: %s undecoded (%s)"):format(
		    mt.nodeid(h.from), tostring(why)))
		return
	end

	local m = {
		from = h.from,
		id = mt.nodeid(h.from),
		to = h.to,
		port = d.portnum,
		portname = mt.PORTNAME[d.portnum] or tostring(d.portnum),
		rssi = rssi,
		snr = snr,
		at = sys.uptime_ms(),
	}

	if d.portnum == mt.PORT_TEXT then
		m.text = d.payload
	elseif d.portnum == mt.PORT_NODEINFO then
		local u = mt.user(d.payload)

		if u then
			note(h.from, { long = u.long, short = u.short })
			m.long, m.short = u.long, u.short
		end
	elseif d.portnum == mt.PORT_POSITION then
		local p = mt.position(d.payload)

		note(h.from, { lat = p.lat, lon = p.lon, alt = p.alt })
		m.lat, m.lon = p.lat, p.lon
	end

	inbox[#inbox + 1] = m
	if #inbox > 64 then
		table.remove(inbox, 1)
	end
end

local function pump()
	while true do
		local r = ask({ op = "recv" })
		local got = r and r.ok

		if got then
			arrived(got.data, got.rssi, got.snr)
		else
			thread.sleep(100)
		end
	end
end

-- ---- what goes out ----

local function packetid()
	return rand()
end

local function sendtext(text, to)
	local h = {
		to = to or mt.BROADCAST,
		from = me,
		id = packetid(),
		hoplimit = 3,
		hopstart = 3,
		channel = channel,
	}
	local frame = mt.seal(h, { portnum = mt.PORT_TEXT, payload = text },
	    key)

	if not frame then
		return nil, "cannot seal"
	end

	-- our own id, so the echo off a neighbour's rebroadcast is not
	-- read back as somebody else saying it
	duplicate(h)
	counters.tx = counters.tx + 1

	local r = ask({ op = "send", data = frame }, 30)

	return r and r.ok
end

-- who we are, which is what makes this node a name in other people's
-- lists rather than a number.
local function announce()
	local pb = require("protobuf")
	local user = pb.encode({
		{ 1, "bytes", mt.nodeid(me) },
		{ 2, "bytes", name },
		{ 3, "bytes", name:sub(1, 4) },
	})
	local h = {
		to = mt.BROADCAST, from = me, id = packetid(),
		hoplimit = 3, hopstart = 3, channel = channel,
	}
	local frame = mt.seal(h, { portnum = mt.PORT_NODEINFO,
	    payload = user }, key)

	if frame then
		duplicate(h)
		ask({ op = "send", data = frame }, 30)
	end
end

local function serve()
	while true do
		local m = thread.recv(sys.SELF)

		if type(m) == "table" then
			local rp = m.reply and m.reply.__right
			local function answer(msg)
				if rp then
					sys.send(rp, msg)
				end
			end

			if m.op == "recv" then
				answer({ ok = table.remove(inbox, 1) })
			elseif m.op == "send" then
				answer({ ok = sendtext(m.text or "", m.to) })
			elseif m.op == "nodes" then
				local out = {}

				for _, n in pairs(nodes) do
					out[#out + 1] = n
				end
				answer({ ok = out })
			elseif m.op == "announce" then
				announce()
				answer({ ok = true })
			elseif m.op == "status" then
				answer({ ok = { me = mt.nodeid(me), name = name,
				    channel = channel, waiting = #inbox,
				    counters = counters } })
			elseif m.op == "name" then
				name = tostring(m.name or name):sub(1, 32)
				answer({ ok = name })
			else
				answer({ err = "no such op" })
			end

			-- the right arrived as a copy of the client's
			if rp then
				sys.close(rp)
			end
		end
	end
end

if not configure() then
	sys.log("meshsrv: the radio would not take the mesh settings")
end
sys.log(("meshsrv: %s on channel %02x"):format(mt.nodeid(me), channel))

thread.spawn(pump)
thread.spawn(serve)
thread.run()
