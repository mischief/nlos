-- fbcheck: does the screen read back as what was drawn?
--
--	> fbcheck
--
-- A screenshot is an unload of what the driver kept, not a read of the
-- glass. This fills, reads it back and counts what disagrees.

local prog = require("prog")
local memdraw = require("memdraw")
local sys = require("los.sys")
local unistd = require("posix.unistd")

local fb = prog.screen()

if not fb then
	io.stderr:write("fbcheck: no framebuffer here\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h

local function out(s)
	unistd.write(1, s)
	sys.log("fbcheck: " .. (s:gsub("\n$", "")))
end

-- what a colour becomes once the panel has narrowed it to 16 bits and
-- the readback has widened it again. Comparing against the original
-- would count every pixel as wrong.
local function narrowed(rgb)
	local r5 = (rgb >> 19) & 0x1f
	local g6 = (rgb >> 10) & 0x3f
	local b5 = (rgb >> 3) & 0x1f

	return string.char((r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4),
	    (b5 << 3) | (b5 >> 2))
end

local COLOR = 0x2050a0
local want = narrowed(COLOR)

fb.fill(memdraw.rect(0, 0, W, H), COLOR)
fb.sync()

local bad, first = 0, nil

for y = 0, H - 1, 16 do
	local n = math.min(16, H - y)
	local px = fb.unload({ x = 0, y = y, w = W, h = n }, "rgb")

	if type(px) ~= "string" or #px ~= W * n * 3 then
		out(("row %d: got %s, %d bytes\n"):format(y, type(px),
		    type(px) == "string" and #px or -1))
		break
	end
	for i = 0, W * n - 1 do
		if px:sub(i * 3 + 1, i * 3 + 3) ~= want then
			bad = bad + 1
			first = first or (y + i // W) * W + (i % W)
		end
	end
end

out(("%d of %d pixels differ%s\n"):format(bad, W * H,
    first and (", first at " .. (first // W) .. "," .. (first % W)) or ""))
