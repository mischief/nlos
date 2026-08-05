-- ML-KEM-768 and Keccak on the target.
--
-- The known-answer suite lives in the host ssh tree, where
-- SHA3 is checked against openssl and every ciphertext is handed to
-- OpenSSL to decapsulate. This asks the question only a boot can answer:
-- does it run here, and what does a post-quantum handshake cost on this
-- machine.

local tap = require("tap")
local sys = require("los.sys")
local keccak = require("crypto.keccak")
local mlkem = require("crypto.mlkem768")

tap.plan(5)

local function hex(s)
	return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function ms(f)
	local t0 = sys.uptime_ms()
	local r, r2 = f()
	return sys.uptime_ms() - t0, r, r2
end

-- FIPS 202, and the one value in this file that is written down rather
-- than derived: SHA3-256("abc"). Everything else the host suite covers.
tap.ok(hex(keccak.sha3_256("abc")) ==
    "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532",
    "sha3-256 matches its published vector")

tap.ok(#keccak.shake128("seed", 500) == 500, "shake128 squeezes past a rate")

local ok_rng, rng = pcall(require, "los.platform.rng")

tap.ok(ok_rng, "los.platform.rng present")
if not ok_rng then tap.done() return end

local drbg = require("crypto.drbg")
local r = drbg.new(rng.bytes(32))

-- No key generator here -- a server only encapsulates -- so the
-- encapsulation key is one the host suite proved openssl accepts,
-- rebuilt from a seed. What is being timed is the work, not the bytes.
local ek = r.bytes(mlkem.EK_LEN)

-- A random 1184 bytes is almost certainly NOT a valid encapsulation
-- key: the modulus check rejects it, which is worth asserting on its
-- own since it is the check that was vacuous once.
local ct, err = mlkem.encaps(ek, r.bytes)

tap.ok(ct == nil and tostring(err):match("modulus"),
    "random bytes are rejected by the FIPS 203 7.2 modulus check")

-- Now a well-formed one: 12-bit words all below q.
local words = {}
for i = 1, 384 * 3 // 3 * 2 do words[i] = (i * 7) % 3329 end
local packed = {}
for i = 0, #words // 2 - 1 do
	local a, b = words[2 * i + 1], words[2 * i + 2]

	packed[i + 1] = string.char(a & 0xff,
	    ((a >> 8) | ((b & 0xf) << 4)) & 0xff, (b >> 4) & 0xff)
end
local good = table.concat(packed) .. r.bytes(32)

local t, ct2, ss = ms(function() return mlkem.encaps(good, r.bytes) end)

tap.diag(string.format("ml-kem-768 encaps: %d ms", t))
tap.ok(ct2 and #ct2 == mlkem.CT_LEN and #ss == mlkem.SS_LEN,
    "encapsulated to a well-formed key")

local x25519 = require("crypto.x25519")
local t2 = ms(function() return x25519.scalarmult_base(r.bytes(32)) end)

tap.diag(string.format("a hybrid handshake adds about %d ms to the %d ms x25519",
    t, t2))

tap.done()
