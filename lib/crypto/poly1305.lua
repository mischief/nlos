-- The C primitives, under the names the Lua implementations had.
--
-- src/native.c is a verbatim copy of the host tree's, so it exposes one
-- module with chacha20_xor and friends -- upstream's Lua modules wrap it
-- and fall back to their own arithmetic when it is absent. Here it is
-- never absent: it is compiled into the kernel. So this is the wrapper
-- and not the fallback, which keeps the call sites reading as they did
-- and keeps two unused pure-Lua implementations out of the image.
local native = require "crypto.native"

return {
  auth = native.poly1305_auth,
}
