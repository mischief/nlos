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
local session = require("bitchat.session")
local ed25519 = require("crypto.ed25519")
local x25519 = require("crypto.x25519")
local sha256 = require("crypto.sha256")

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

-- prog.rand is the draw itself, not a generator to ask. An ephemeral
-- key wants it too, so it is held rather than drawn once.
local randbytes = prog.rand() or die("no entropy to make a key with")

local function identity()
	local raw = N:readfile(KEYFILE)

	if raw and #raw == 32 then
		return raw
	end

	local seed = randbytes(32)
	local okw, werr = N:writefile(KEYFILE, seed)

	if not okw then
		out("bitchat: could not save the key: " .. tostring(werr) ..
		    "\n")
	end
	return seed
end

local function derive(seed, label)
	return sha256.new():update(label):update(seed):final()
end

-- two keys from one stored seed, separated by their labels: a
-- Curve25519 key to agree with and an Ed25519 key to sign with. A peer
-- needs both before it will look at us.
local seed = identity()
local noisesec = derive(seed, "bitchat-noise-static")
local noisepub = x25519.scalarmult_base(noisesec)
local signsec = derive(seed, "bitchat-ed25519-signing")
local signpub = ed25519.publickey(signsec)

-- the peer id is the first eight bytes of the hash of the Curve25519
-- key. A peer recomputes it from the announce and drops anything whose
-- sender field disagrees, so this is not ours to choose.
local myid = sha256.new():update(noisepub):final():sub(1, 8)

local function hex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- the whole hash, not the eight bytes of it a peer id is: this is what
-- another client shows for us, and comparing it is how two people check
-- there is nobody in the middle.
local fingerprint = hex(sha256.new():update(noisepub):final())

out(string.format("bitchat: %s, peer %s\n", nick, hex(myid)))
out(string.format("fingerprint %s\n", (fingerprint:upper():gsub(
    "(%x%x%x%x)", "%1 "):gsub(" $", ""))))

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

-- A link that predates this run is useless to us: the peer subscribed
-- to the old service, and registering a new one resets that, so a
-- notification would go nowhere. Dropping the link makes the peer
-- reconnect and subscribe again, which is the path that works.
local st = ask({ op = "status" })

for _, l in ipairs(st.links or {}) do
	out(string.format("dropping stale link %d (%s)\n", l.handle,
	    l.addr or "?"))
	ask({ op = "disconnect", handle = l.handle })
end

ask({ op = "advertise", on = true, name = nick, service = SERVICE })
out("advertising, and listening\n")

ask({ op = "scan", on = true })

-- ---- what arrives ----

local peers = {}		-- handle -> {addr, char, nick}
local names = {}		-- peer id -> nickname, so an announce is said once
local seen = {}			-- packet ids already relayed
local sessions = {}		-- peer id -> a Noise session

-- these answer private traffic and want to send, which needs the
-- signing and the radio below.
local onhandshake, onencrypted

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
	elseif p.type == packet.NOISE_HANDSHAKE then
		onhandshake(p)
		return "private"
	elseif p.type == packet.NOISE_ENCRYPTED then
		onencrypted(p)
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

-- unix milliseconds. A peer drops anything more than 15 minutes old,
-- so uptime will not do: this needs the wall clock timed has set.
local function now()
	local t = os.time()

	if not t then
		die("no wall clock; a peer would call every packet stale")
	end
	return math.floor(t) * 1000
end

-- Sign and serialize; a peer ignores an announce carrying no signature.
-- The signature covers the packet padded and with ttl zeroed, but the
-- packet goes out at its own length: only Noise frames are padded, and
-- a padded announce would not fit the link. A verifier re-encodes what
-- it received, so a payload of 100 bytes or more would be deflated on
-- its side and must be kept under that to agree.
local function signed(p)
	p.signature = ed25519.sign(signsec, packet.signinput(p))
	return packet.encode(p)
end

-- ---- private sessions ----
--
-- A handshake and the messages after it are directed rather than
-- broadcast, so both carry a recipient. Neither is signed: the session
-- is what says who is speaking.
local function directed(kind, to, body)
	return packet.encode({ type = kind, ttl = 7, timestamp = now(),
	    sender = myid, recipient = to, payload = body })
end

local function saypacket(b)
	local n = ask({ op = "notify", attr = mychar, value = b })

	if n.err or n.ok == false then
		out("send failed: " .. tostring(n.err or "nobody listening") ..
		    "\n")
		return false
	end
	return true
end

local function whois(id)
	return names[hex(id)] or hex(id)
end

function onhandshake(p)
	if p.recipient ~= myid then
		return		-- somebody else's, passing through
	end

	local id = hex(p.sender)
	local s = sessions[id]

	-- a bare ephemeral key is a fresh approach, so an earlier
	-- half-built session is abandoned rather than fed a message it
	-- cannot place.
	if #p.payload == session.INIT_SIZE and (not s or not s:established())
	    then
		s = session.new(noisesec, randbytes, false)
		sessions[id] = s
		out(string.format("~ %s is opening a private session\n",
		    whois(p.sender)))
	end

	if not s then
		return
	end

	local reply, err = s:handshake(p.payload)

	if err then
		out("handshake failed: " .. tostring(err) .. "\n")
		sessions[id] = nil
		return
	end
	if reply then
		saypacket(directed(packet.NOISE_HANDSHAKE, p.sender, reply))
	end
	if s:established() then
		out(string.format("~ private session with %s\n",
		    whois(p.sender)))
	end
end

function onencrypted(p)
	if p.recipient ~= myid then
		return
	end

	local s = sessions[hex(p.sender)]

	if not s or not s:established() then
		out("~ encrypted traffic with no session to read it\n")
		return
	end

	local kind, body = s:decrypt(p.payload)

	if not kind then
		out("~ could not read it: " .. tostring(body) .. "\n")
		return
	end

	if kind == session.PRIVATE_MESSAGE then
		local m = session.decodeprivate(body)

		if m then
			out(string.format("[%s] %s\n", whois(p.sender),
			    m.content))
		end
	else
		out(string.format("~ %s sent a 0x%02x, which we do not read\n",
		    whois(p.sender), kind))
	end
end

-- an announce of our own, so peers know a name for us.
local function announce()
	-- all three fields are mandatory: a peer that cannot find the
	-- nickname and both keys stops parsing and never sees us.
	return signed({ type = packet.ANNOUNCE, ttl = 3, timestamp = now(),
	    sender = myid,
	    payload = packet.encodeannounce({ nickname = nick,
		noisekey = noisepub, signkey = signpub }) })
end

local function say(text)
	return signed({ type = packet.MESSAGE, ttl = 7, timestamp = now(),
	    sender = myid,
	    payload = packet.encodemessage({
		id = hex(myid) .. tostring(sys.uptime_ms()),
		sender = nick, content = text, timestamp = now(),
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

local deadline = sys.uptime_ms() + 180000
local nextannounce = 0

while sys.uptime_ms() < deadline do
	-- announce on a timer as well as on subscribe. A peer that
	-- subscribed before we asked would otherwise never hear one.
	if sys.uptime_ms() >= nextannounce then
		nextannounce = sys.uptime_ms() + 10000
		local n = ask({ op = "notify", attr = mychar,
		    value = announce() })

		if not (n.err or n.ok == false) then
			out("announced\n")
		end
	end

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
