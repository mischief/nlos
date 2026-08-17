-- zbench: what lib/zmodem costs with no line under it.
--
--	> zbench [KB]
--
-- The sink discards and the source is memory, so what is left is the
-- encoding: crc, escaping and whatever copying happens per chunk.

local zmodem = require("zmodem")
local sys = require("los.sys")
local unistd = require("posix.unistd")

local kb = tonumber(arg[1] or "") or 75
local body = string.rep("\x00\xff\x11\x7f\x18\x0d\x8d\x90", kb * 128)

local function out(s)
	unistd.write(1, s)
	sys.log("zbench: " .. (s:gsub("\n$", "")))
end

out(("body %d bytes\n"):format(#body))

-- ---- the pieces, one at a time ----

local t0 = sys.uptime_ms()

zmodem.crc32(body)
out(("crc32           %5d ms\n"):format(sys.uptime_ms() - t0))

-- the same escaping the sender does, reached through a whole subpacket
-- since esc itself is local to the module.
t0 = sys.uptime_ms()

local n = 0

for i = 1, #body, 8192 do
	local chunk = body:sub(i, i + 8191)

	n = n + #chunk
end
out(("slicing 8k      %5d ms\n"):format(sys.uptime_ms() - t0))
