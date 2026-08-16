-- A private session with one peer: Noise XX, and what rides it.
--
-- The handshake is stock XX with empty payloads. The transport is not
-- stock: every message carries its own nonce in front, so a receiver
-- takes them in any order and a replay is caught by the window rather
-- than by a counter kept in step.

local noise = require("noise")
local suites = require("noise.suites")

local M = {}

M.NAME = "Noise_XX_25519_ChaChaPoly_SHA256"

-- what a decrypted plaintext says it is, in its first byte.
M.PRIVATE_MESSAGE = 0x01
M.READ_RECEIPT = 0x02
M.DELIVERED = 0x03
M.VERIFY_CHALLENGE = 0x10
M.VERIFY_RESPONSE = 0x11
M.PEER_STATE = 0x21

-- a fresh XX message 1 is a bare ephemeral key and nothing else, which
-- is how an unasked-for handshake is told from a reply to ours.
M.INIT_SIZE = 32

local Session = {}

Session.__index = Session

-- new(static secret, rand, initiator) -> session
-- `rand` draws bytes for the ephemeral key.
function M.new(s, rand, initiator)
	local hs = noise.new({ suite = suites.chachapoly, name = M.NAME,
	    initiator = initiator, s = s })

	hs:ephemeral(rand(32))
	return setmetatable({ hs = hs, initiator = initiator, n = 0,
	    seen = {} }, Session)
end

-- the next handshake message to send, or nil where it is not our turn.
function Session:handshake(msg)
	if msg then
		local ok, err = self.hs:read(msg)

		if not ok then
			return nil, err
		end
	end

	if self.hs:done() then
		self:ready()
		return nil
	end

	local out, err = self.hs:write("")

	if not out then
		return nil, err
	end
	if self.hs:done() then
		self:ready()
	end
	return out
end

function Session:ready()
	if self.send then
		return
	end
	self.send, self.recv = self.hs:split()
	self.peer = self.hs:peerstatic()
end

function Session:established()
	return self.send ~= nil
end

-- [4-byte big-endian nonce][ciphertext][tag]. The nonce goes on the
-- wire big-endian and into the cipher little-endian, which is a trap
-- worth stating: they are the same number written two ways.
function Session:encrypt(payloadtype, body)
	if not self.send then
		return nil, "no session yet"
	end

	local n = self.n

	if n >= 0xfffffffe then
		return nil, "session exhausted"
	end
	self.n = n + 1

	local ct = self.send:sealat(n, "", string.char(payloadtype) .. body)

	return string.pack(">I4", n) .. ct
end

function Session:decrypt(frame)
	if not self.recv then
		return nil, "no session yet"
	end
	if #frame < 4 + 16 then
		return nil, "short frame"
	end

	local n = string.unpack(">I4", frame)

	if self.seen[n] then
		return nil, "replayed nonce"
	end

	local pt = self.recv:openat(n, "", frame:sub(5))

	if not pt then
		return nil, "authentication failed"
	end
	self.seen[n] = true
	if #pt < 1 then
		return nil, "empty plaintext"
	end
	return pt:byte(1), pt:sub(2)
end

-- ---- what a private message looks like inside ----

local function tlv(t, v)
	if #v > 255 then
		return nil
	end
	return string.char(t, #v) .. v
end

function M.encodeprivate(m)
	local id = tlv(0x00, m.id)
	local content = tlv(0x01, m.content)

	if not id or not content then
		return nil, "a field longer than a byte holds"
	end
	return id .. content
end

function M.decodeprivate(b)
	local at = 1
	local out = {}

	while at + 1 <= #b do
		local t, n = b:byte(at), b:byte(at + 1)

		if at + 1 + n > #b then
			return nil, "a field claiming more than is here"
		end

		local v = b:sub(at + 2, at + 1 + n)

		if t == 0x00 then
			out.id = v
		elseif t == 0x01 then
			out.content = v
		else
			return nil, "unknown field"
		end
		at = at + 2 + n
	end
	if not out.id or not out.content then
		return nil, "a private message needs an id and content"
	end
	return out
end

M.Session = Session

return M
