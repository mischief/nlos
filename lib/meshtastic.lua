-- meshtastic, as bytes: no radio, no ports, no clock.
--
-- Everything here is a pure function of what came off the air, so the
-- whole protocol is testable against captured frames. What drives a
-- radio with it lives above.

local pb = require("protobuf")

local M = {}

-- ---- the frame ----
--
-- 16 bytes, little-endian, then the ciphertext. Flags carry the hop
-- counts; channel is a hash, not an index.
M.HEADER = 16

M.BROADCAST = 0xffffffff

function M.parse(frame)
	if #frame < M.HEADER then
		return nil, "shorter than a header"
	end

	local to, from, id, flags, chan, nexthop, relay =
	    string.unpack("<I4I4I4BBBB", frame)

	return {
		to = to,
		from = from,
		id = id,
		hoplimit = flags & 0x07,
		want_ack = (flags & 0x08) ~= 0,
		via_mqtt = (flags & 0x10) ~= 0,
		hopstart = (flags >> 5) & 0x07,
		channel = chan,
		nexthop = nexthop,
		relay = relay,
	}, frame:sub(M.HEADER + 1)
end

function M.frame(h, payload)
	local flags = (h.hoplimit or 3) & 0x07

	if h.want_ack then
		flags = flags | 0x08
	end
	if h.via_mqtt then
		flags = flags | 0x10
	end
	flags = flags | (((h.hopstart or h.hoplimit or 3) & 0x07) << 5)

	return string.pack("<I4I4I4BBBB", h.to or M.BROADCAST, h.from or 0,
	    h.id or 0, flags, h.channel or 0, h.nexthop or 0,
	    h.relay or 0) .. (payload or "")
end

-- ---- the channel ----

-- the key every device powers up on. Public in the plainest sense: it
-- is in their source, so this encrypts against eavesdroppers with no
-- radio and nobody else.
M.DEFAULTKEY = "\xd4\xf1\xbb\x3a\x20\x29\x07\x59" ..
    "\xf0\xbc\xff\xab\xcf\x4e\x69\x01"

-- a byte, and only a hint: the receiver still has to try the key. Name
-- and key are xored together, so two channels can collide and the
-- decrypt is what settles it.
function M.channelhash(name, key)
	local h = 0

	for i = 1, #name do
		h = h ~ name:byte(i)
	end
	for i = 1, #key do
		h = h ~ key:byte(i)
	end
	return h
end

-- djb2 over the channel name, which is what picks the slot
function M.namehash(name)
	local h = 5381

	for i = 1, #name do
		h = ((h << 5) + h + name:byte(i)) & 0xffffffff
	end
	return h
end

-- where a channel lands in a region's band. The slot is the name's
-- hash over however many channels the bandwidth leaves room for, and
-- the frequency is the middle of that slot.
function M.slot(name, region, bwkhz)
	local span = region.hi - region.lo
	local n = math.floor(span / ((region.spacing or 0) + bwkhz / 1000))

	if n < 1 then
		return nil, "the band is narrower than one channel"
	end

	local ch = M.namehash(name) % n

	return region.lo + (bwkhz / 2000) + ch * (bwkhz / 1000), ch, n
end

M.REGIONS = {
	US = { lo = 902.0, hi = 928.0, spacing = 0 },
	EU_868 = { lo = 869.4, hi = 869.65, spacing = 0 },
	ANZ = { lo = 915.0, hi = 928.0, spacing = 0 },
}

-- the presets, as their firmware defines them: spreading factor,
-- bandwidth in kHz, and the coding rate's denominator.
M.PRESETS = {
	SHORT_TURBO = { sf = 7, bw = 500, cr = 5 },
	SHORT_FAST = { sf = 7, bw = 250, cr = 5 },
	SHORT_SLOW = { sf = 8, bw = 250, cr = 5 },
	MEDIUM_FAST = { sf = 9, bw = 250, cr = 5 },
	MEDIUM_SLOW = { sf = 10, bw = 250, cr = 5 },
	LONG_FAST = { sf = 11, bw = 250, cr = 5 },
	LONG_MODERATE = { sf = 11, bw = 125, cr = 8 },
	LONG_SLOW = { sf = 12, bw = 125, cr = 8 },
	LONG_TURBO = { sf = 11, bw = 500, cr = 8 },
}

-- what every radio on the network uses, and not the sx1262's default
M.SYNCWORD = 0x2b

-- ---- the cipher ----

-- AES-CTR with the counter in the last four bytes: the packet id and
-- the sender, which are both in the header, so a receiver has the
-- nonce before it has the key.
function M.nonce(id, from)
	return string.pack("<I8I4", id, from) .. string.rep("\0", 4)
end

local aes = nil

do
	local ok, native = pcall(require, "crypto.native")

	aes = ok and native.aes_ctr_xor or nil
end

-- the same call both ways, which is what a stream cipher means
function M.decrypt(key, id, from, data)
	if not aes then
		return nil, "no aes here"
	end
	return aes(key, M.nonce(id, from), data)
end

M.encrypt = M.decrypt

-- ---- what is inside ----

M.PORT_TEXT = 1
M.PORT_POSITION = 3
M.PORT_NODEINFO = 4
M.PORT_ROUTING = 5
M.PORT_TELEMETRY = 67

-- the Data message, of which a reader wants two fields. The rest are
-- carried through as they came so nothing is lost by not naming them.
function M.data(plain)
	local f = pb.decode(plain)

	if f[1] == nil and f[2] == nil then
		return nil, "not a Data message"
	end
	return {
		portnum = f[1] or 0,
		payload = f[2] or "",
		want_response = f[3] == 1,
		dest = f[4],
		source = f[5],
		request_id = f[6],
		reply_id = f[7],
	}
end

function M.encodedata(d)
	local fields = {}

	if d.portnum and d.portnum ~= 0 then
		fields[#fields + 1] = { 1, "varint", d.portnum }
	end
	if d.payload and d.payload ~= "" then
		fields[#fields + 1] = { 2, "bytes", d.payload }
	end
	if d.want_response then
		fields[#fields + 1] = { 3, "varint", 1 }
	end
	if d.dest then
		fields[#fields + 1] = { 4, "i32", d.dest }
	end
	if d.source then
		fields[#fields + 1] = { 5, "i32", d.source }
	end
	if d.request_id then
		fields[#fields + 1] = { 6, "i32", d.request_id }
	end
	if d.reply_id then
		fields[#fields + 1] = { 7, "i32", d.reply_id }
	end
	return pb.encode(fields)
end

-- ---- the whole way in ----

-- a frame off the air to what it says, or nil and why. The decrypt is
-- its own check: a wrong key gives bytes that are not a Data message.
function M.open(frame, key)
	local h, cipher = M.parse(frame)

	if not h then
		return nil, cipher
	end

	local plain, why = M.decrypt(key or M.DEFAULTKEY, h.id, h.from,
	    cipher)

	if not plain then
		return nil, why
	end

	local d, no = M.data(plain)

	if not d then
		return h, nil, no
	end
	return h, d
end

-- and the way out: a Data message, encrypted, behind a header
function M.seal(h, d, key)
	local plain, why = M.encodedata(d)

	if not plain then
		return nil, why
	end

	local cipher = M.encrypt(key or M.DEFAULTKEY, h.id or 0, h.from or 0,
	    plain)

	if not cipher then
		return nil, "no aes here"
	end
	return M.frame(h, cipher)
end

return M
