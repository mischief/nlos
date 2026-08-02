-- The SSH crypto primitives on real hardware, with timings.
--
-- The KAT suite lives in the host-side tree (~/code/lua/ssh) and runs
-- under busted; this asks the different question that only a boot can
-- answer -- does it run here, and how long does a handshake's worth of
-- curve work actually take on this machine.

local tap = require("tap")
local sys = require("los.sys")

tap.plan(7)

local ok_rng, rng = pcall(require, "los.platform.rng")
tap.ok(ok_rng, "los.platform.rng present")
if not ok_rng then tap.done() return end

local drbg = require("crypto.drbg")
local sha256 = require("crypto.sha256")
local chacha20 = require("crypto.chacha20")
local poly1305 = require("crypto.poly1305")
local x25519 = require("crypto.x25519")
local ed25519 = require("crypto.ed25519")

local function hex(s)
	return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function ms(f)
	local t0 = sys.uptime_ms()
	local r = f()
	return sys.uptime_ms() - t0, r
end

-- RFC 6234: SHA-256 of "abc"
tap.ok(hex(sha256.hash("abc")) ==
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    "sha256 matches its published vector")

-- RFC 8439 2.5.2
local pk = poly1305.auth(
	string.char(0x85,0xd6,0xbe,0x78,0x57,0x55,0x6d,0x33,0x7f,0x44,0x52,
	    0xfe,0x42,0xd5,0x06,0xa8,0x01,0x03,0x80,0x8a,0xfb,0x0d,0xb2,0xfd,
	    0x4a,0xbf,0xf6,0xaf,0x41,0x49,0xf5,0x1b),
	"Cryptographic Forum Research Group")
tap.ok(hex(pk) == "a8061dc1305136c6c22b8baf0c0127a9",
    "poly1305 matches its published vector")

local seed = rng.bytes(32)
local r = drbg.new(seed)
local a, b = r.bytes(32), r.bytes(32)
tap.ok(#a == 32 and #b == 32 and a ~= b, "drbg produces distinct draws")

local t, kb = ms(function() return chacha20.xor(seed, 1, ("\0"):rep(12), ("x"):rep(65536)) end)
tap.diag(string.format("chacha20 64KB: %d ms (%.2f KB/s)", t,
    t > 0 and 65536 / t or 0))
tap.ok(#kb == 65536, "chacha20 over 64KB")

local t1, q = ms(function() return x25519.scalarmult_base(seed) end)
tap.diag(string.format("x25519 scalarmult: %d ms", t1))
tap.ok(#q == 32, "x25519 scalarmult_base")

local t2, pub = ms(function() return ed25519.publickey(seed) end)
tap.diag(string.format("ed25519 publickey: %d ms", t2))

local t3, sig = ms(function() return ed25519.sign(seed, "hello") end)
tap.diag(string.format("ed25519 sign: %d ms", t3))

local t4, good = ms(function() return ed25519.verify(pub, "hello", sig) end)
tap.diag(string.format("ed25519 verify: %d ms", t4))
tap.ok(good, "ed25519 sign/verify round trip")

tap.diag(string.format("a server handshake is about %d ms of curve work",
    t1 + t3 + t4))

tap.done()
