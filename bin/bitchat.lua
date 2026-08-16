-- bitchat: the public mesh, over BLE.
--
--	bitchat [NICKNAME]
--
-- Public messages only, which are unencrypted: a peer is readable
-- before any handshake exists. Private traffic rides Noise, not here.

local unistd = require("posix.unistd")
local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local uuid = require("ble.uuid")
local att = require("ble.att")
local gattc = require("ble.gattc")
local packet = require("bitchat.packet")
local ed25519 = require("crypto.ed25519")

local function out(s)
	unistd.write(1, s)
end

local function die(s)
	unistd.write(2, "bitchat: " .. s .. "\n")
	os.exit(1)
end

local srv = prog.ble() or die("no bluetooth service here")
local N = prog.ns() or die("no namespace")
local nick = arg[1] or "luaos"

-- BitChat's own service, from BLEService.swift. One characteristic
-- carries both directions: peers write to it and subscribe to it.
local SERVICE = uuid.parse("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
local CHAR = uuid.parse("A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")

-- ---- identity ----
--
-- /config survives a reflash, so a peer keeps its name across one.
local KEYFILE = "/config/bitchat_id"

local function identity()
	local raw = N:readfile(KEYFILE)

	if raw and #raw == 32 then
		return raw
	end

	-- prog.rand is the draw itself, not a generator to ask.
	local randbytes = prog.rand() or die("no entropy to make a key with")
	local seed = randbytes(32)
	local okw, werr = N:writefile(KEYFILE, seed)

	if not okw then
		out("bitchat: could not save the key: " .. tostring(werr) ..
		    "\n")
	end
	return seed
end

local seed = identity()
local pub = ed25519.publickey(seed)

-- the peer id is the first eight bytes of the public key, which is
-- what a sender field holds and what other peers know us by.
local myid = pub:sub(1, 8)

local function hex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

out(string.format("bitchat: %s, peer %s\n", nick, hex(myid)))

-- ---- the radio ----

local function ask(msg, ms)
	local reply = sys.newport("bitchat.reply")
	local guard <close> = sys.owned(reply)

	msg.reply = { __right = reply }
	sys.send(srv, msg)

	local m = thread.recvtimeout(reply, ms or 5000)

	if not m then
		die("blesrv did not answer " .. tostring(msg.op))
	end
	return m
end

local port = sys.newport("bitchat.events")
local guard <close> = sys.owned(port)

ask({ op = "watch", port = { __right = port }, want = "all" })

-- serve the same service we look for, because every node is both: a
-- mesh has no clients and no servers, only peers.
-- the port owns the service: when this program exits, blesrv sees the
-- right hang up and takes the handles back, so the next run gets the
-- same ones rather than a second copy further along.
local mine = ask({ op = "serve", service = SERVICE,
    port = { __right = port },
    chars = { { uuid = CHAR, props = 0x04 | 0x08 | 0x10 } } })

if mine.err then
    die(mine.err)
end

local mychar = mine.handles.chars[1].value
-- the descriptor a peer writes to subscribe, which is where an announce
-- becomes possible rather than at the link.
local mycccd = mine.handles.chars[1].cccd

ask({ op = "advertise", on = true, name = nick, service = SERVICE })
out("advertising, and listening\n")

ask({ op = "scan", on = true })

-- ---- what arrives ----

local peers = {}		-- handle -> {addr, char, nick}
local names = {}		-- peer id -> nickname, so an announce is said once
local seen = {}			-- packet ids already relayed

local function show(p)
	if p.type == packet.ANNOUNCE then
		local a = packet.decodeannounce(p.payload)
		local id = hex(p.sender)

		if not names[id] then
			names[id] = a.nickname or "?"
			out(string.format("* %s is here (%s%s)\n",
			    a.nickname or "?", id,
			    a.noisekey and ", has a noise key" or ""))
		end
	elseif p.type == packet.MESSAGE then
		local m = packet.decodemessage(p.payload)

		if m then
			out(string.format("<%s> %s\n", m.sender, m.content))
		end
	elseif p.type == packet.LEAVE then
		out(string.format("* %s left\n", hex(p.sender)))
	elseif p.type == packet.NOISE_HANDSHAKE or
	    p.type == packet.NOISE_ENCRYPTED then
		-- private traffic, which needs a handshake this does not
		-- have. Counted rather than shown, so the mesh looks busy
		-- rather than broken.
		return "private"
	end
	return nil
end

local nprivate = 0

local function onpacket(b)
	local p, why = packet.decode(b)

	if not p then
		out("bitchat: " .. tostring(why) .. "\n")
		return
	end
	if p.sender == myid then
		return		-- our own, come back around the mesh
	end

	local key = hex(p.sender) .. tostring(p.timestamp)

	if seen[key] then
		return
	end
	seen[key] = true

	if show(p) == "private" then
		nprivate = nprivate + 1
	end
end

-- an announce of our own, so peers know a name for us.
local function announce()
	-- an announce is TLV, not a bare name: a nickname beside the keys
	-- a peer would need to speak privately later.
	return packet.encode({ type = packet.ANNOUNCE, ttl = 3,
	    timestamp = math.floor(sys.uptime_ms()), sender = myid,
	    payload = packet.encodeannounce({ nickname = nick,
		signkey = pub }) })
end

local function say(text)
	return packet.encode({ type = packet.MESSAGE, ttl = 7,
	    timestamp = math.floor(sys.uptime_ms()), sender = myid,
	    payload = packet.encodemessage({
		id = hex(myid) .. tostring(sys.uptime_ms()),
		sender = nick, content = text,
		timestamp = math.floor(sys.uptime_ms()),
	    }) })
end

-- write a packet to every peer we hold a link to.
local function broadcast(b)
	for h, p in pairs(peers) do
		if p.char then
			ask({ op = "att", handle = h,
			    pdu = gattc.writecmd(p.char, b) })
		end
	end
end

local deadline = sys.uptime_ms() + 60000

while sys.uptime_ms() < deadline do
	local m = thread.recvtimeout(port, 1000)

	if m and m.kind == "adv" then
		-- a peer offering the same service is one of us.
		for _, u in ipairs(m.uuids or {}) do
			if uuid.eq(u, SERVICE) and not peers[m.addr] then
				out("peer " .. m.addr .. "\n")
				peers[m.addr] = { addr = m.addr }
			end
		end
	elseif m and m.kind == "link" and m.up then
		peers[m.handle] = { addr = m.addr, role = m.role }
		out(string.format("linked %s (we are %s)\n", m.addr or "?",
		    m.role == 1 and "peripheral" or "central"))
		-- A peer that connected to us reads our characteristic by
		-- subscribing, so what reaches it is a notification. Writing
		-- would need its handle for its own database, which is a
		-- different number we have not discovered.
		local n = ask({ op = "notify", attr = mychar,
		    value = announce() })

		if n.err or n.ok == false then
			out("announce not sent: " ..
			    tostring(n.err or "nobody subscribed") .. "\n")
		end
	elseif m and m.kind == "link" and not m.up then
		peers[m.handle] = nil
	elseif m and m.kind == "write" and m.attr == mycccd then
		-- a write to the descriptor is the peer subscribing, not a
		-- packet. It is also the first moment a notification can
		-- reach them, so the announce goes now rather than at link.
		out("peer subscribed; announcing\n")
		ask({ op = "notify", attr = mychar, value = announce() })
	elseif m and m.kind == "write" then
		if m.attr ~= mychar then
			out(string.format("write to handle %d (ours is %d)\n",
			    m.attr or 0, mychar))
		end
		onpacket(m.value or "")
	elseif m and m.kind == "notify" then
		onpacket(m.value or "")
	end
end

ask({ op = "scan", on = false })
ask({ op = "advertise", on = false })
out(string.format("done; %d private packets not read\n", nprivate))
