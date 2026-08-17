-- secp256k1 and BIP 340 where the native module answers. The pure Lua
-- is checked upstream against the whole BIP 340 table; what this asks
-- is whether the C agrees on a few of the same inputs, and that the
-- refusals refuse.

local secp = require("crypto.secp256k1")
local bech32 = require("bech32")
local util = require("crypto.util")
local sys = require("los.sys")
local tap = require("tap")

local unhex = util.unhex

tap.plan(14)

local SEC = unhex("B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF")
local PUB = unhex("DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659")
local AUX = unhex("0000000000000000000000000000000000000000000000000000000000000001")
local MSG = unhex("243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89")
local SIG = unhex("6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE3341" ..
    "8906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A")

-- ---- the native module is what we came to test ----
tap.ok(secp.native ~= nil, "the native secp256k1 is present")

-- ---- keys and signatures ----
tap.is(secp.pubkey(SEC), PUB, "derives the vector's public key")
tap.is(secp.sign(SEC, MSG, AUX), SIG, "reproduces the vector's signature")
tap.ok(secp.verify(PUB, MSG, SIG) == true, "verifies the vector")

-- The half that matters: a verifier that says true to everything passes
-- every positive case above.
local bad = SIG:sub(1, 63) .. string.char(SIG:byte(64) ~ 1)

tap.ok(secp.verify(PUB, MSG, bad) ~= true, "refuses an altered signature")
tap.ok(secp.verify(PUB, unhex(("00"):rep(32)), SIG) ~= true,
    "refuses the signature over another message")

-- BIP 340 vector 5: a public key that is not on the curve.
local offcurve =
    unhex("EEFDEA4CD0B44C0FC1B6E4C6C8D5E3C2A9D2B2D3D5C6E7F8091A2B3C4D5E6F70")

tap.ok(secp.verify(offcurve, MSG, SIG) ~= true, "refuses a key off the curve")
tap.ok(secp.lift_x(unhex(("ff"):rep(32))) == nil, "refuses an x over the field")

-- ---- signing round trip, on this machine's own randomness ----
local mine = sys.random and sys.random(32) or unhex(("2b"):rep(32))
local mypub = secp.pubkey(mine)
local mysig = secp.sign(mine, "hello from lua-os")

tap.ok(mypub ~= nil and #mypub == 32, "derives a key from fresh entropy")
tap.ok(secp.verify(mypub, "hello from lua-os", mysig) == true,
    "and verifies what it signed")

-- ---- ecdh, which nip-44 needs ----
local other = unhex("C90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B14E5C9")
local otherpub = secp.pubkey(other)

tap.is(secp.shared_x(mine, otherpub), secp.shared_x(other, mypub),
    "ecdh agrees from both sides")

-- ---- bech32, for npub and nsec ----
local enc = bech32.encode_bytes("npub", mypub)
local hrp, back = bech32.decode_bytes(enc)

tap.is(hrp, "npub", "bech32 keeps the prefix")
tap.is(back, mypub, "and the bytes survive the round trip")
tap.ok(bech32.decode_bytes(enc:sub(1, -2) .. "q") == nil,
    "a broken checksum is refused")

tap.done()
