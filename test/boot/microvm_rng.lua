-- exercises los.platform.rng (virtio-rng over virtio-mmio) with a few
-- random-length requests, checking the returned string is exactly the
-- requested length and that two draws aren't identical.

local sys = require("los.sys")
local stdout = require("stdout")
local rng = require("los.platform.rng")

stdout.set(sys.granted().cons)

local function hex(s)
	return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local lengths = { 1, 2, 16, 200, 4096 }
local prev = nil
local ok = true

for _, n in ipairs(lengths) do
	local s = rng.bytes(n)
	if #s ~= n then
		print(string.format("FAIL: asked for %d bytes, got %d", n, #s))
		ok = false
	else
		print(string.format("ok: %d bytes: %s", n,
		    hex(s:sub(1, math.min(#s, 16)))))
	end
	if prev and #prev == n and prev == s then
		print("FAIL: two draws of the same length were identical")
		ok = false
	end
	prev = s
end

print(ok and "microvm: rng test PASSED" or "microvm: rng test FAILED")

-- cons/wire/power are real daemons now (see microvm_hello.lua's note);
-- ask power to end the guest explicitly.
sys.send(sys.granted().power, { op = "reset" })
