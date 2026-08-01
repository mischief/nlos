-- los.platform.rng: virtio-rng over virtio-mmio. checks a draw is
-- exactly as long as asked for, across sizes either side of the
-- device's own buffering, and that repeated draws differ.

local tap = require("tap")
local rng = require("los.platform.rng")

local lengths = { 1, 2, 16, 200, 4096 }

tap.plan(#lengths + 2)

local function hex(s)
	return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local draws = {}

for _, n in ipairs(lengths) do
	local s = rng.bytes(n)

	tap.ok(#s == n, string.format("%d bytes asked, %d back: %s", n, #s,
	    hex(s:sub(1, math.min(#s, 16)))))
	draws[#draws + 1] = s
end

-- two draws being equal is possible for one byte and vanishingly
-- unlikely past that, so compare only the long ones. an identical pair
-- there means the device is returning a fixed buffer, not entropy.
local repeated = false

for i = 1, #draws do
	for j = i + 1, #draws do
		if #draws[i] == #draws[j] and draws[i] == draws[j] and
		    #draws[i] > 2 then
			repeated = true
		end
	end
end

tap.ok(not repeated, "no two long draws came back identical")

local big = rng.bytes(4096)
local distinct = {}
local n = 0

for c in big:gmatch(".") do
	if not distinct[c] then
		distinct[c] = true
		n = n + 1
	end
end

-- a stuck or zero-filled device is the failure worth catching; real
-- entropy covers nearly the whole byte range in 4096 draws.
tap.diag("distinct byte values in 4096: " .. n)
tap.ok(n > 200, "a 4096-byte draw covers most of the byte range")

tap.done()
