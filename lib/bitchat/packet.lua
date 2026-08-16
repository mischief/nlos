-- BitChat's wire format, from BinaryProtocol.swift and BitchatMessage.
--
-- Two layers: an outer packet that the mesh relays by ttl, and a public
-- message inside it. Everything is big-endian, which is the one thing
-- here that differs from every other protocol in this tree.

local inflate = require("zlib.inflate")

local M = {}

M.V1_HEADER = 14
M.SENDER_ID = 8
M.RECIPIENT_ID = 8
M.SIGNATURE = 64

-- packet types. The public three need no encryption at all, which is
-- what makes a mesh readable before any handshake exists.
M.ANNOUNCE = 0x01
M.MESSAGE = 0x02
M.LEAVE = 0x03
M.NOISE_HANDSHAKE = 0x10
M.NOISE_ENCRYPTED = 0x11
M.FRAGMENT = 0x20

-- header flags.
M.HAS_RECIPIENT = 0x01
M.HAS_SIGNATURE = 0x02
M.IS_COMPRESSED = 0x04

-- ---- the outer packet ----

-- A packet, or nil and why. Compression is refused rather than
-- guessed at: the payload would be zlib, and inflating it is work this
-- does not do, so saying so beats handing up rubbish.
function M.decode(b)
	if #b < 21 then
		return nil, "shorter than a header and a sender"
	end

	local version = b:byte(1)

	if version ~= 1 then
		return nil, "version " .. version
	end

	local ptype, ttl = b:byte(2), b:byte(3)
	local timestamp = string.unpack(">I8", b:sub(4))
	local flags = b:byte(12)
	local plen = string.unpack(">I2", b:sub(13))
	local at = M.V1_HEADER + 1

	local sender = b:sub(at, at + M.SENDER_ID - 1)

	at = at + M.SENDER_ID
	if #sender < M.SENDER_ID then
		return nil, "truncated sender"
	end

	local recipient

	if (flags & M.HAS_RECIPIENT) ~= 0 then
		recipient = b:sub(at, at + M.RECIPIENT_ID - 1)
		at = at + M.RECIPIENT_ID
		if #recipient < M.RECIPIENT_ID then
			return nil, "truncated recipient"
		end
	end

	local payload = b:sub(at, at + plen - 1)

	at = at + plen
	if #payload < plen then
		return nil, "truncated payload"
	end

	-- a compressed payload is preceded by the length it had before, and
	-- the header counts those two bytes as part of it. What follows is
	-- raw deflate: their COMPRESSION_ZLIB has no zlib wrapper on it.
	if (flags & M.IS_COMPRESSED) ~= 0 then
		if plen < 3 then
			return nil, "compressed payload without a size"
		end

		local want = string.unpack(">I2", payload)
		local out = inflate.decompress(payload:sub(3))

		if not out then
			return nil, "payload did not inflate"
		end
		if #out ~= want then
			return nil, "inflated to the wrong size"
		end
		payload = out
	end

	local signature

	if (flags & M.HAS_SIGNATURE) ~= 0 then
		signature = b:sub(at, at + M.SIGNATURE - 1)
		if #signature < M.SIGNATURE then
			return nil, "truncated signature"
		end
	end

	return {
		version = version, type = ptype, ttl = ttl,
		timestamp = timestamp, sender = sender,
		recipient = recipient, payload = payload,
		signature = signature,
	}
end

-- PKCS#7 to the next block, where every pad byte is the pad count. A
-- frame needing more than 255 bytes of it is left alone, since the count
-- must fit in one byte.
M.BLOCKS = { 256, 512, 1024, 2048 }

function M.pad(b)
	local want = #b

	for _, n in ipairs(M.BLOCKS) do
		if #b + 16 <= n then
			want = n
			break
		end
	end

	local need = want - #b

	if need <= 0 or need > 255 then
		return b
	end
	return b .. string.char(need):rep(need)
end

function M.encode(p, pad)
	local flags = 0

	if p.recipient then
		flags = flags | M.HAS_RECIPIENT
	end
	if p.signature then
		flags = flags | M.HAS_SIGNATURE
	end

	local out = string.pack(">BBBI8BI2", 1, p.type, p.ttl or 7,
	    p.timestamp or 0, flags, #p.payload) .. p.sender

	if p.recipient then
		out = out .. p.recipient
	end
	out = out .. p.payload
	if p.signature then
		out = out .. p.signature
	end
	if pad then
		out = M.pad(out)
	end
	return out
end

-- what a signature covers: the packet without its own signature and
-- with ttl zero, padded. The ttl is left out because a relay decrements
-- it, and a signature over it would not survive the first hop.
function M.signinput(p)
	local q = {}

	for k, v in pairs(p) do
		q[k] = v
	end
	q.signature = nil
	q.ttl = 0
	return M.encode(q, true)
end

-- ---- a public message, inside a packet's payload ----

-- flags of the message itself, which are not the packet's.
M.MSG_RELAY = 0x01
M.MSG_PRIVATE = 0x02
M.MSG_ORIGINAL_SENDER = 0x04
M.MSG_RECIPIENT_NICK = 0x08
M.MSG_SENDER_PEERID = 0x10
M.MSG_MENTIONS = 0x20

local function lenstr(b, at, width)
	local n

	if width == 1 then
		n = b:byte(at)
		at = at + 1
	else
		if #b < at + 1 then
			return nil
		end
		n = string.unpack(">I2", b:sub(at))
		at = at + 2
	end
	if not n or #b < at + n - 1 then
		return nil
	end
	return b:sub(at, at + n - 1), at + n
end

function M.decodemessage(b)
	if #b < 13 then
		return nil, "too short for a message"
	end

	local flags = b:byte(1)
	local ts = string.unpack(">I8", b:sub(2))
	local at = 10
	local id, sender, content

	id, at = lenstr(b, at, 1)
	if not id then
		return nil, "truncated id"
	end
	sender, at = lenstr(b, at, 1)
	if not sender then
		return nil, "truncated sender"
	end
	content, at = lenstr(b, at, 2)
	if not content then
		return nil, "truncated content"
	end

	local m = {
		id = id, sender = sender, content = content,
		timestamp = ts,
		relay = (flags & M.MSG_RELAY) ~= 0,
		private = (flags & M.MSG_PRIVATE) ~= 0,
	}

	if (flags & M.MSG_ORIGINAL_SENDER) ~= 0 then
		m.origin, at = lenstr(b, at, 1)
	end
	if (flags & M.MSG_RECIPIENT_NICK) ~= 0 then
		m.to, at = lenstr(b, at, 1)
	end
	if (flags & M.MSG_SENDER_PEERID) ~= 0 then
		m.peerid, at = lenstr(b, at, 1)
	end
	return m
end

function M.encodemessage(m)
	local flags = 0

	if m.relay then
		flags = flags | M.MSG_RELAY
	end
	if m.peerid then
		flags = flags | M.MSG_SENDER_PEERID
	end

	local out = string.pack(">BI8", flags, m.timestamp or 0) ..
	    string.char(#m.id) .. m.id ..
	    string.char(#m.sender) .. m.sender ..
	    string.pack(">I2", #m.content) .. m.content

	if m.peerid then
		out = out .. string.char(#m.peerid) .. m.peerid
	end
	return out
end

-- an announce is type-length-value, not a bare name: the nickname is
-- one field beside the two public keys a peer needs to be spoken to
-- privately later.
M.TLV_NICKNAME = 0x01
M.TLV_NOISE_KEY = 0x02
M.TLV_SIGNING_KEY = 0x03
M.TLV_NEIGHBOURS = 0x04
M.TLV_CAPABILITIES = 0x05

function M.decodeannounce(payload)
	local out = {}
	local at = 1

	while at + 1 <= #payload do
		local t = payload:byte(at)
		local n = payload:byte(at + 1)

		if not n or at + 1 + n > #payload then
			break		-- a field claiming more than is here
		end

		local v = payload:sub(at + 2, at + 1 + n)

		if t == M.TLV_NICKNAME then
			out.nickname = v
		elseif t == M.TLV_NOISE_KEY then
			out.noisekey = v
		elseif t == M.TLV_SIGNING_KEY then
			out.signkey = v
		elseif t == M.TLV_CAPABILITIES then
			out.capabilities = v
		end
		at = at + 2 + n
	end
	return out
end

function M.encodeannounce(a)
	local out = string.char(M.TLV_NICKNAME, #a.nickname) .. a.nickname

	if a.noisekey then
		out = out .. string.char(M.TLV_NOISE_KEY, #a.noisekey) ..
		    a.noisekey
	end
	if a.signkey then
		out = out .. string.char(M.TLV_SIGNING_KEY, #a.signkey) ..
		    a.signkey
	end
	return out
end

return M
