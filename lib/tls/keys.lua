-- The TLS 1.3 key schedule, and the suite it is fixed to.
--
-- Both halves of the handshake derive the same secrets from the same
-- transcript, so the schedule is here rather than in either. That is
-- also what keeps them apart: a client that reached these through
-- tls/server.lua would load the whole server -- accept, the certificate
-- flight, ed25519 -- to call two functions, and a proc doing an https
-- fetch has no use for any of it.
--
-- One suite, TLS_CHACHA20_POLY1305_SHA256. See tls/hello.lua.

local hkdf = require "crypto.hkdf"
local hmac = require "crypto.hmac"
local sha256 = require "crypto.sha256"
local hello = require "tls.hello"

local M = {}

M.SUITE = hello.CHACHA20_POLY1305_SHA256
M.KEY_LEN = 32				-- of the AEAD the suite names

-- one stage of the schedule. The label is what separates a secret from
-- the one derived beside it, and "derived" between stages is what keeps
-- a secret from being usable as the input of the stage that produced
-- it.
function M.derive(secret, label, transcript_hash)
	return hkdf.expand_label(sha256, secret, label, transcript_hash, 32)
end

-- The verify_data of a Finished message: an HMAC under a key derived
-- from the traffic secret, over the transcript so far. Not a signature:
-- both ends already hold the traffic secret, so this proves the key
-- schedule agrees rather than proving identity.
function M.finished(secret, transcript_hash)
	local key = hkdf.expand_label(sha256, secret, "finished", "", 32)

	return hmac.auth(sha256, key, transcript_hash)
end

return M
