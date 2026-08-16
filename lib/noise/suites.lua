-- The cipher and hash a Noise protocol name names.
--
-- Only the one BitChat speaks is here. A suite is what lib/noise needs
-- of a cipher: seal, open, the nonce for a counter, and the hash.

local aead = require "crypto.aead"
local sha256 = require "crypto.sha256"

local M = {}

-- 4 zero bytes then the counter, little-endian, which is what the Noise
-- specification says for ChaChaPoly and is the opposite of AESGCM's.
local function nonce(n)
	return ("\0"):rep(4) .. string.pack("<I8", n)
end

M.chachapoly = {
	hash = sha256,
	nonce = nonce,
	seal = aead.seal,
	open = aead.open,
}

return M
