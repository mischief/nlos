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

-- A number has to outlive a reboot. Their firmware takes one from the
-- hardware address; the radio has no claim on ours, so it is drawn once
-- and kept. Without this every boot is a new stranger in everyone
-- else's node list, and theirs are not swept quickly.
local CONFDIR = "/config/meshtastic"
local IDFILE = CONFDIR .. "/id"

local function keptid()
	local N = require("ns").current()
	local raw = N and N:readfile(IDFILE)
	local kept = raw and tonumber(raw:match("%x+") or "", 16)

	if kept then
		return kept & 0xffffffff
	end

	-- the top bit set, which is what their firmware does for a number
	-- it made up rather than one from a hardware address
	local n = rand() | 0x80000000

	-- /config is empty on a freshly reamed partition
	if N and not N:stat(CONFDIR) then
		local d = N:create(CONFDIR, "rw", true)

		if d then
			d:close()
		end
	end

	if not (N and N:writefile(IDFILE, ("%08x\n"):format(n))) then
		sys.log("meshsrv: cannot keep a node number; this boot is new")
	end
	return n
end

local me = keptid()
local name = cfg.name or "lua-os"

-- a key given as hex, so two machines can be told to share one without
-- either of them holding the public network's
local function hexkey(s)
	if type(s) ~= "string" or #s ~= 32 then
		return nil
	end
	return (s:gsub("%x%x", function(b)
		return string.char(tonumber(b, 16))
	end))
end

local chan = mt.channel({
	preset = mt.PRESETS[cfg.preset or "LONG_FAST"],
	region = mt.REGIONS[cfg.region or "US"],
	name = cfg.channel,
	key = hexkey(cfg.key) or (cfg.psk and mt.psk(tonumber(cfg.psk))),
	slot = tonumber(cfg.slot),
	offset = tonumber(cfg.offset),
})

if not chan then
	sys.log("meshsrv: no such preset or region")
	return
end

local key = chan.key
local channel = chan.hash
local hoplimit = tonumber(cfg.hop) or 3
local interval = math.max(tonumber(cfg.announce) or 10800, 3600)

-- Whether a gateway may put what we send on a public broker, where it
-- is archived and searchable. Off is their firmware's default; on is
-- what makes a message reach the map sites everyone reads.
local okmqtt = cfg.mqtt ~= false

-- Tuning to somebody else's channel is for listening. Nothing goes out
-- while this is set, so visiting a network cannot beacon into it an
-- hour later when the timer comes round and nobody is watching.
local quiet = false

local inbox = {}	-- decoded, waiting for a client that polls
local subs = {}		-- rights to push arrivals to, for those that do not
-- Bounded, because a public mesh is bigger than this machine: about
-- 350 bytes an entry here, and the local network has a thousand of
-- them. The one heard longest ago goes.
local nodes = require("nodedb").new(cfg.nodes or 200)
local seen = {}		-- (from,id) -> when, so a flood is heard once
local nseen = 0
local SEENMAX = 256
local counters = { rx = 0, tx = 0, dup = 0, undecoded = 0 }

-- One reply port per thread, not one for the task. Three threads talk
-- to the radio, and a shared port lets one of them take another's
-- answer: what comes back from a send is not a frame, and the reader
-- that treats it as one dies quietly with the radio still listening.
local function asker(name)
	local port = sys.newport(name)
	local right = sys.sendright(port)

	return function(m, secs)
		m.reply = { __right = right }

		if not sys.send(lora, m) then
			return nil
		end
		return thread.recvtimeout(port, (secs or 5) * 1000)
	end
end

-- ---- what the radio has to be told ----

local function configure(ask)
	return ask({ op = "config", freq = math.floor(chan.freq * 1e6),
	    sf = chan.sf, bw = chan.bw, cr = chan.cr, sync = mt.SYNCWORD,
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

	-- an id is a random word, so what is worth remembering is the
	-- recent past and not all of it
	if nseen > SEENMAX then
		local old = sys.uptime_ms() - 600000

		for kk, when in pairs(seen) do
			if when < old then
				seen[kk] = nil
				nseen = nseen - 1
			end
		end

		-- A mesh busy enough that nothing is ten minutes old must
		-- still fit, or the sweep frees nothing and runs again on
		-- every packet. Half at a time, so this is one sort per
		-- few hundred rather than a scan per arrival.
		if nseen > SEENMAX then
			local all = {}

			for kk, when in pairs(seen) do
				all[#all + 1] = { kk, when }
			end
			table.sort(all, function(a, b)
				return a[2] < b[2]
			end)
			for i = 1, #all // 2 do
				seen[all[i][1]] = nil
				nseen = nseen - 1
			end
		end
	end
	return false
end

local function note(num, fields)
	local n = nodes:note(num, fields, sys.uptime_ms())

	n.id = n.id or mt.nodeid(num)
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

	-- Pushed to whoever asked to be told, and queued for whoever
	-- polls: a subscriber and a poller are different clients and each
	-- gets the whole stream. Two pollers still share one inbox, which
	-- is what the push is here to avoid.
	for i = #subs, 1, -1 do
		if not sys.send(subs[i], m) then
			sys.close(subs[i])
			table.remove(subs, i)
		end
	end

	inbox[#inbox + 1] = m
	if #inbox > 64 then
		table.remove(inbox, 1)
	end
end

local function pump()
	local ask = asker("meshsrv.pump")

	while true do
		local r = ask({ op = "recv" })
		local got = r and r.ok

		-- a frame, and not merely something that is not false: a
		-- reader that indexes whatever arrives stops reading the
		-- first time it is handed anything else
		if type(got) == "table" and got.data then
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

local function sendtext(ask, text, to)
	if quiet then
		return nil, "listening to somebody else's channel"
	end

	local h = {
		to = to or mt.BROADCAST,
		from = me,
		id = packetid(),
		hoplimit = hoplimit,
		hopstart = hoplimit,
		channel = channel,
	}
	local frame = mt.seal(h, { portnum = mt.PORT_TEXT, payload = text,
	    ok_to_mqtt = okmqtt }, key)

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
local function announce(ask)
	if quiet then
		return nil, "listening to somebody else's channel"
	end

	local pb = require("protobuf")
	local user = pb.encode({
		{ 1, "bytes", mt.nodeid(me) },
		{ 2, "bytes", name },
		{ 3, "bytes", name:sub(1, 4) },
	})
	local h = {
		to = mt.BROADCAST, from = me, id = packetid(),
		hoplimit = hoplimit, hopstart = hoplimit, channel = channel,
	}
	local frame = mt.seal(h, { portnum = mt.PORT_NODEINFO,
	    payload = user, ok_to_mqtt = okmqtt }, key)

	if frame then
		duplicate(h)
		counters.tx = counters.tx + 1
		return ask({ op = "send", data = frame }, 30)
	end
end

-- a node that never says who it is stays a number in everybody's list,
-- so this goes out once the radio is up and then on a timer. An hour is
-- their floor and it is kept: the air is shared and a nodeinfo is not
-- urgent. `mesh announce` is there for when it is.
local function beacon()
	local ask = asker("meshsrv.beacon")

	thread.sleep(15000)

	while true do
		if not quiet then
			announce(ask)
		end
		thread.sleep(interval * 1000)
	end
end

local function serve()
	local ask = asker("meshsrv.serve")

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
				local sent, why = sendtext(ask, m.text or "",
				    m.to)

				answer({ ok = sent, err = why })
			elseif m.op == "nodes" then
				answer({ ok = nodes:list() })
			elseif m.op == "announce" then
				local said, why = announce(ask)

				answer({ ok = said, err = why })
			elseif m.op == "status" then
				answer({ ok = { me = mt.nodeid(me), name = name,
				    channel = channel, waiting = #inbox,
				    chan = chan, hop = hoplimit,
				    quiet = quiet,
				    known = nodes:count(),
				    nodemax = nodes.max,
				    counters = counters } })
			elseif m.op == "subscribe" then
				-- kept, not closed with the reply: this one
				-- is ours until the client goes away, and a
				-- failed send is how we learn that it has
				local r = m.port and m.port.__right

				if r then
					subs[#subs + 1] = r
					answer({ ok = true })
				else
					answer({ err = "no port to push to" })
				end
			elseif m.op == "tune" then
				local c = mt.channel({
					preset = mt.PRESETS[m.preset or "LONG_FAST"],
					region = mt.REGIONS[m.region or "US"],
					name = m.channel,
					slot = tonumber(m.slot),
					offset = tonumber(m.offset),
				})

				if not c then
					answer({ err = "no such preset or region" })
				else
					chan, key, channel = c, c.key, c.hash
					hoplimit = tonumber(m.hop) or hoplimit
					quiet = m.quiet ~= false
					answer({ ok = configure(ask) and c,
					    quiet = quiet })
				end
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

-- before any thread runs, so this port is nobody else's
if not configure(asker("meshsrv.start")) then
	sys.log("meshsrv: the radio would not take the mesh settings")
end
sys.log(("meshsrv: %s on channel %02x"):format(mt.nodeid(me), channel))

thread.spawn(pump)
thread.spawn(beacon)
thread.spawn(serve)
thread.run()
