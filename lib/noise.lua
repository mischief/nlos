-- The Noise protocol framework, revision 34, for the XX pattern.
--
-- Sans-io: write() returns bytes to send, read() takes bytes that
-- arrived. The cipher and hash are passed in, since the protocol name
-- names them and two peers must agree on it byte for byte.

local x25519 = require "crypto.x25519"
local hkdf = require "crypto.hkdf"

local M = {}

local HASHLEN = 32
local DHLEN = 32

-- Noise's HKDF is RFC 5869 with the chaining key as the salt and no
-- info, taking the first two blocks of output.
local function hkdf2(suite, ck, ikm)
	local prk = hkdf.extract(suite.hash, ck, ikm)
	local okm = hkdf.expand(suite.hash, prk, "", 2 * HASHLEN)

	return okm:sub(1, HASHLEN), okm:sub(HASHLEN + 1, 2 * HASHLEN)
end

-- ---- CipherState ----
--
-- One key and the counter that must never repeat under it.

local Cipher = {}

Cipher.__index = Cipher

local function newcipher(suite, k)
	return setmetatable({ suite = suite, k = k, n = 0 }, Cipher)
end

function Cipher:encrypt(ad, plaintext)
	if not self.k then
		return plaintext
	end

	local out = self.suite.seal(self.k, self.suite.nonce(self.n),
	    plaintext, ad)

	self.n = self.n + 1
	return out
end

function Cipher:decrypt(ad, ciphertext)
	if not self.k then
		return ciphertext
	end

	local out = self.suite.open(self.k, self.suite.nonce(self.n),
	    ciphertext, ad)

	if not out then
		return nil, "noise: authentication failed"
	end
	self.n = self.n + 1
	return out
end

-- The counter, for a transport that carries it rather than keeping it
-- in step. Reading it back is what lets a receiver take messages out of
-- order or drop them.
function Cipher:nonce()
	return self.n
end

function Cipher:sealat(n, ad, plaintext)
	return self.suite.seal(self.k, self.suite.nonce(n), plaintext, ad)
end

function Cipher:openat(n, ad, ciphertext)
	return self.suite.open(self.k, self.suite.nonce(n), ciphertext, ad)
end

function Cipher:advance()
	self.n = self.n + 1
end

-- ---- SymmetricState ----
--
-- The chaining key and the running hash of everything both sides have
-- seen, which is what binds a transcript to the keys it produced.

local Sym = {}

Sym.__index = Sym

local function newsym(suite, name)
	local h

	if #name <= HASHLEN then
		h = name .. ("\0"):rep(HASHLEN - #name)
	else
		h = suite.hash.hash(name)
	end
	return setmetatable({ suite = suite, h = h, ck = h,
	    cs = newcipher(suite, nil) }, Sym)
end

function Sym:mixhash(data)
	self.h = self.suite.hash.hash(self.h .. data)
end

function Sym:mixkey(input)
	local ck, temp = hkdf2(self.suite, self.ck, input)

	self.ck = ck
	self.cs = newcipher(self.suite, temp)
end

function Sym:encrypt(plaintext)
	local out = self.cs:encrypt(self.h, plaintext)

	self:mixhash(out)
	return out
end

function Sym:decrypt(ciphertext)
	local out, err = self.cs:decrypt(self.h, ciphertext)

	if not out then
		return nil, err
	end
	self:mixhash(ciphertext)
	return out
end

-- the two transport keys, in the initiator's order: the first is what
-- the initiator sends with.
function Sym:split()
	local k1, k2 = hkdf2(self.suite, self.ck, "")

	return newcipher(self.suite, k1), newcipher(self.suite, k2)
end

-- ---- HandshakeState, XX ----
--
-- Neither side needs the other's static key beforehand.
--	-> e
--	<- e, ee, s, es
--	-> s, se

local HS = {}

HS.__index = HS

-- new{suite=, name=, initiator=, s=, prologue=} -> handshake
-- `s` is our static secret; the public half is derived from it.
function M.new(o)
	local hs = setmetatable({
		suite = o.suite,
		initiator = o.initiator,
		s = o.s,
		spub = x25519.scalarmult_base(o.s),
		sym = newsym(o.suite, o.name),
		step = 0,
	}, HS)

	hs.sym:mixhash(o.prologue or "")
	return hs
end

local function dh(sec, pub)
	local k, err = x25519.shared(sec, pub)

	if not k then
		return nil, err
	end
	return k
end

-- the ephemeral key. Split out so a test can pin one and check the
-- transcript against a vector.
function HS:ephemeral(secret)
	self.e = secret
	self.epub = x25519.scalarmult_base(secret)
end

function HS:write(payload)
	payload = payload or ""

	if not self.e then
		return nil, "noise: no ephemeral key"
	end

	local out

	if self.step == 0 and self.initiator then
		-- -> e
		self.sym:mixhash(self.epub)
		out = self.epub .. self.sym:encrypt(payload)
	elseif self.step == 1 and not self.initiator then
		-- <- e, ee, s, es
		self.sym:mixhash(self.epub)
		self.sym:mixkey(dh(self.e, self.re))
		local enc_s = self.sym:encrypt(self.spub)

		self.sym:mixkey(dh(self.s, self.re))
		out = self.epub .. enc_s .. self.sym:encrypt(payload)
	elseif self.step == 2 and self.initiator then
		-- -> s, se
		local enc_s = self.sym:encrypt(self.spub)

		self.sym:mixkey(dh(self.s, self.re))
		out = enc_s .. self.sym:encrypt(payload)
	else
		return nil, "noise: not our turn to write"
	end

	self.step = self.step + 1
	return out
end

local TAGLEN = 16

function HS:read(msg)
	local at = 1
	local payload, err

	if self.step == 0 and not self.initiator then
		-- -> e
		if #msg < DHLEN then
			return nil, "noise: short first message"
		end
		self.re = msg:sub(1, DHLEN)
		at = DHLEN + 1
		self.sym:mixhash(self.re)
		payload, err = self.sym:decrypt(msg:sub(at))
	elseif self.step == 1 and self.initiator then
		-- <- e, ee, s, es
		if #msg < DHLEN + DHLEN + TAGLEN then
			return nil, "noise: short second message"
		end
		self.re = msg:sub(1, DHLEN)
		at = DHLEN + 1
		self.sym:mixhash(self.re)
		self.sym:mixkey(dh(self.e, self.re))

		local enc_s = msg:sub(at, at + DHLEN + TAGLEN - 1)

		at = at + DHLEN + TAGLEN
		self.rs, err = self.sym:decrypt(enc_s)
		if not self.rs then
			return nil, err
		end
		self.sym:mixkey(dh(self.e, self.rs))
		payload, err = self.sym:decrypt(msg:sub(at))
	elseif self.step == 2 and not self.initiator then
		-- -> s, se
		if #msg < DHLEN + TAGLEN then
			return nil, "noise: short third message"
		end

		local enc_s = msg:sub(1, DHLEN + TAGLEN)

		at = DHLEN + TAGLEN + 1
		self.rs, err = self.sym:decrypt(enc_s)
		if not self.rs then
			return nil, err
		end
		self.sym:mixkey(dh(self.e, self.rs))
		payload, err = self.sym:decrypt(msg:sub(at))
	else
		return nil, "noise: not our turn to read"
	end

	if not payload then
		return nil, err
	end
	self.step = self.step + 1
	return payload
end

-- done after three messages; the keys are the caller's to keep.
function HS:done()
	return self.step >= 3
end

-- send, recv -- ours to send with and ours to receive with, whichever
-- end we are.
function HS:split()
	local k1, k2 = self.sym:split()

	if self.initiator then
		return k1, k2
	end
	return k2, k1
end

-- the peer's static public key, once a handshake has carried it.
function HS:peerstatic()
	return self.rs
end

M.Cipher = Cipher

return M
