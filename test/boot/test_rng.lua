-- los.platform.rng on EFI: EFI_RNG_PROTOCOL, if the firmware publishes
-- one. Same shape as test/boot/microvm_rng.lua, which checks the
-- virtio-rng path.

local tap = require("tap")

local ok, rng = pcall(require, "los.platform.rng")

if not ok then
	tap.plan(1)
	tap.ok(false, "no los.platform.rng: " .. tostring(rng))
	tap.done()
	return
end

tap.plan(4)

local a = rng.bytes(32)
tap.ok(#a == 32, "32 bytes asked, " .. #a .. " back")

local b = rng.bytes(32)
tap.ok(a ~= b, "two draws differ")

tap.ok(rng.bytes(0) == "", "a zero-length draw is empty, not an error")

local big = rng.bytes(4096)
local seen, n = {}, 0
for c in big:gmatch(".") do
	if not seen[c] then seen[c] = true; n = n + 1 end
end
tap.diag("distinct byte values in 4096: " .. n)
tap.ok(n > 200, "a 4096-byte draw covers most of the byte range")

tap.done()
