#!/usr/bin/env lua5.4
-- lib/noise: the XX handshake, both ends of it.
--
-- The two ends are the same code, so agreeing with each other proves
-- less than it looks. The digest below came from sha256sum, and the
-- real proof of the rest is a phone at the other end of a radio.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" ..
    scriptdir .. "/../lib/?/init.lua;" .. package.path

local noise = require("noise")
local suites = require("noise.suites")
local x25519 = require("crypto.x25519")

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

local function key(b)
	return string.char(b):rep(32)
end

local function hexof(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- run a whole XX handshake, and hand back both sides.
local function handshake(suite, name, payloads)
	local i = noise.new({ suite = suite, name = name, initiator = true,
	    s = key(1) })
	local r = noise.new({ suite = suite, name = name, initiator = false,
	    s = key(2) })

	i:ephemeral(key(3))
	r:ephemeral(key(4))

	payloads = payloads or { "", "", "" }

	local m1 = assert(i:write(payloads[1]))
	local p1, e1 = r:read(m1)

	if not p1 then
		return nil, "message 1: " .. tostring(e1)
	end

	local m2 = assert(r:write(payloads[2]))
	local p2, e2 = i:read(m2)

	if not p2 then
		return nil, "message 2: " .. tostring(e2)
	end

	local m3 = assert(i:write(payloads[3]))
	local p3, e3 = r:read(m3)

	if not p3 then
		return nil, "message 3: " .. tostring(e3)
	end
	return i, r, { p1, p2, p3 }, { m1, m2, m3 }
end

for _, s in ipairs({ "chachapoly" }) do
	local suite = suites[s]
	local name = "Noise_XX_25519_ChaChaPoly_SHA256"

	local i, r, got, msgs = handshake(suite, name,
	    { "", "hello", "there" })

	ok(i ~= nil, s .. ": the handshake completes")
	if not i then
		io.write("# " .. tostring(r) .. "\n")
		goto continue
	end

	ok(got[2] == "hello" and got[3] == "there",
	    s .. ": handshake payloads arrive")
	ok(i:done() and r:done(), s .. ": both ends say so")

	-- each side learned the other's static key, which is the whole
	-- point of XX over a pattern that needs one in advance.
	ok(i:peerstatic() == x25519.scalarmult_base(key(2)),
	    s .. ": the initiator learned the responder's static key")
	ok(r:peerstatic() == x25519.scalarmult_base(key(1)),
	    s .. ": and the responder the initiator's")

	-- message 1 is an unencrypted ephemeral and nothing else.
	ok(#msgs[1] == 32, s .. ": message 1 is one public key")
	ok(#msgs[2] == 32 + 48 + #"hello" + 16, s .. ": message 2's shape")
	ok(#msgs[3] == 48 + #"there" + 16, s .. ": message 3's shape")

	do
		local isend, irecv = i:split()
		local rsend, rrecv = r:split()
		local ct = isend:encrypt("", "ping")

		ok(rrecv:decrypt("", ct) == "ping",
		    s .. ": a transport message, initiator to responder")

		local back = rsend:encrypt("", "pong")

		ok(irecv:decrypt("", back) == "pong", s .. ": and back")

		-- the counter moves, so the same plaintext differs.
		ok(isend:encrypt("", "ping") ~= ct,
		    s .. ": the nonce advances")

		-- a flipped bit must not decrypt to anything at all.
		local bad = rsend:encrypt("", "tamper")

		bad = bad:sub(1, 1) ..
		    string.char(bad:byte(2) ~ 0xff) .. bad:sub(3)
		ok(irecv:decrypt("", bad) == nil,
		    s .. ": a tampered message is refused")
	end

	::continue::
end

-- ---- the transcript, against values computed outside lua ----
--
-- Two ends of the same code agreeing proves little. sha256sum wrote
-- the digest below.
do
	local name = "Noise_XX_25519_ChaChaPoly_SHA256"

	-- exactly 32 bytes, so it is the initial hash verbatim rather than
	-- its digest. One byte either way changes every key that follows.
	ok(#name == 32, "the protocol name is exactly a hash long")

	local hs = noise.new({ suite = suites.chachapoly, name = name,
	    initiator = true, s = key(1) })

	-- an empty prologue is still mixed in, so h has been hashed once.
	ok(hexof(hs.sym.h) ==
	    "f3d15e6108ed9556171207baa58f97d29a13c6be40595166066e2e0958dc002d",
	    "and the empty prologue leaves the hash sha256sum says")
end

-- a peer that does not know the pattern gets nothing: the same keys
-- under a different protocol name must not interoperate.
do
	local suite = suites.chachapoly
	local i = noise.new({ suite = suite, name = "Noise_XX_25519_ChaChaPoly_SHA256",
	    initiator = true, s = key(1) })
	local r = noise.new({ suite = suite, name = "Noise_XX_25519_ChaChaPoly_SHA512",
	    initiator = false, s = key(2) })

	i:ephemeral(key(3))
	r:ephemeral(key(4))

	local m1 = assert(i:write(""))

	ok(r:read(m1) ~= nil, "message 1 carries no key, so it reads")

	local m2 = assert(r:write(""))

	ok(i:read(m2) == nil, "but a different protocol name cannot agree")
end

-- out of turn is an error rather than a wrong key later.
do
	local suite = suites.chachapoly
	local r = noise.new({ suite = suite,
	    name = "Noise_XX_25519_ChaChaPoly_SHA256", initiator = false,
	    s = key(2) })

	r:ephemeral(key(4))
	ok(r:write("") == nil, "a responder cannot write first")
end

io.write("1.." .. count .. "\n")
os.exit(failed == 0 and 0 or 1)
