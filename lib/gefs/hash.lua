-- metrohash64_1, seeded with 0x6765, which is what gefs checksums blocks
-- with. The implementation is src/gefs_native.c; this file is the seam.
--
-- This is not a cryptographic hash and is not asked to be: it catches a
-- torn or misdirected write, and every block pointer carries the hash of
-- what it points at, so corruption is found on the way in rather than
-- discovered later as nonsense.
--
-- ---- why the lua one is gone ----
--
-- There was a pure-Lua metro64 here, and the two checked each other --
-- a differential test rather than a vector, since gefs publishes none.
-- It is deleted rather than kept as a fallback because it is the one
-- hot loop in the tree: every block read verifies a hash over the whole
-- 16KiB block and every block written computes one, and under load 88%
-- of the served volume's executed lines were in it (measured with
-- sys.trace, 3610 of 4096 sampled). A fallback that is never chosen is
-- a few kilobytes resident in every proc that touches a filesystem, and
-- a second implementation nobody runs is a second implementation nobody
-- checks.
--
-- The host tests load the same C module (meson.build builds gefs.so for
-- the host and puts it on LUA_CPATH), so what runs there is what runs
-- in the guest rather than a lookalike.
--
-- The standalone port this was copied from keeps its pure-Lua version:
-- running with no C at all is the whole point of that tree. This is the
-- one place the two copies deliberately differ -- see lib/ssh for the
-- same arrangement and the same warning that nothing enforces the sync.
--
-- Two things about the reads, which the C keeps. They are
-- little-endian, matching an unaligned load on amd64; a volume written
-- on a big-endian machine would checksum differently, and 9front's gefs
-- has the same property. And the tails below 8 bytes are unreachable
-- for every use gefs makes of this -- blocks are 16KiB, log bodies are
-- a multiple of 8, and the superblock prefix is 104+16n bytes.

local native = require("gefs.native")

local M = {}

local SEED = 0x6765

M.metro64 = native.metro64

-- the hash over a run of bytes: log bodies and the superblock prefix
function M.bufhash(s, from, len)
	return native.metro64(s, SEED, from, len)
end

-- the hash over a whole block, which is what a block pointer carries
function M.blkhash(s)
	return native.metro64(s, SEED, 1, #s)
end

-- the integer mix gefs uses for its in-memory hash tables. Not on disk,
-- but the deadlist cache keys off it and the shape is worth keeping.
-- Left in lua: it is called once per deadlist lookup, not once per
-- block, so it is not the loop that mattered.
function M.ihash(x)
	x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ~ (x >> 27)) * 0x94d049bb133111eb
	x = x ~ (x >> 31)
	return x & 0xffffffff
end

return M
