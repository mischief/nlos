-- the out argument on the native bindings.
--
-- These produce as many bytes as they are given, and the caller
-- usually has somewhere for them already. What is checked is that the
-- bytes are the same either way, that a cipher may write into its own
-- input, and that a buffer nobody may write -- read-only, or too small
-- -- is refused rather than written past.

local tap = require("tap")

tap.plan(7)
local nat = require("crypto.native")
local buf = require("los.buf")

local key = string.rep("k", 32)
local nonce = string.rep("n", 12)
local msg = string.rep("hello ssh buffers ", 16)

local want = nat.chacha20_xor(key, 1, nonce, msg)
local out = buf.new(#msg)
local got = nat.chacha20_xor(key, 1, nonce, msg, out)

tap.ok(out:str() == want, "the same bytes as without an out buffer")
tap.ok(got == out, "and hands back the buffer it was given")

-- in place: the input buffer is the output buffer
local both = buf.new(#msg)

both:copy(1, msg)
nat.chacha20_xor(key, 1, nonce, both, both)
tap.ok(both:str() == want, "a cipher may write into its own input")

-- and back again, which is what a stream cipher owes
nat.chacha20_xor(key, 1, nonce, both, both)
tap.is(both:str(), msg, "and xoring again is the plaintext")

-- a read-only view must be refused
local ro = buf.new(#msg):ro()

tap.ok(not pcall(nat.chacha20_xor, key, 1, nonce, msg, ro),
    "a read-only buffer is refused")

-- too small is refused rather than truncated
local small = buf.new(4)

tap.ok(not pcall(nat.chacha20_xor, key, 1, nonce, msg, small),
    "a buffer too small is refused rather than written past")

-- and a string result is still what you get without one
tap.is(type(want), "string", "without one the result is a string")
tap.done()
