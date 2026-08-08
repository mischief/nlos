-- where does the time go when drawing a screen?
--
-- the framebuffer is slow enough to notice, and "slow" has at least
-- four candidate causes here that want telling apart before anything is
-- optimised: building pixels in lua, flattening them to a string,
-- getting them through the serializer to the fb task, and the firmware
-- Blt at the far end. this measures each separately.
--
-- it is a benchmark, not a test: it asserts nothing about how long any
-- of it should take, only that the numbers are printed with names.
-- registered with meson's benchmark(), not test(), for the reason
-- test/bench_ipc.lua gives: it asserts nothing, and a timing floor in CI
-- would be flaky on a loaded host. run it with
--
--   meson test -C build-gop --benchmark
--
-- timed with sys.ticks() (raw TSC) rather than uptime_ms, again per
-- bench_ipc: 1ms granularity cannot see a 20% change on a 20ms
-- measurement, which is the size of change worth acting on.
local sys = require("los.sys")
local capfb = require("caps.fb")
local draw = require("draw")

print("1..1")

local caps_of = sys.granted()

if not caps_of.fb then
	print("ok 1 - no framebuffer on this machine, nothing to measure")
	sys.send(caps_of.power, { op = "reset", mode = "shutdown" })
	return
end

local CPMS = sys.stats().cycles_per_ms
local fb = capfb.new(caps_of.fb)
local mode = fb.mode()

-- best of three: the firmware is not a quiet neighbour and one slow lap
-- says nothing.
local function ms(fn, ...)
	local best

	for _ = 1, 3 do
		local t0 = sys.ticks()

		fn(...)

		local d = sys.ticks() - t0

		if not best or d < best then
			best = d
		end
	end
	return best // CPMS
end

print(("# framebuffer %dx%d %s"):format(mode.w, mode.h, mode.format))
print("#")

-- ---- the four stages, on one 320x320 image ----

local W, H = 320, 320
local img

print(("# --- one %dx%d image (%d KiB of pixels) ---"):format(W, H,
    W * H * 4 // 1024))

print(("# make (draw.image, one fill per row): %d ms"):format(ms(function()
	img = draw.image(W, H, 0x202030)
	for y = 0, H - 1 do
		img:fill(draw.rect(0, y, W, 1), (y * 0x10101) & 0xffffff)
	end
end)))

local bytes

print(("# flatten (draw.bytes):                %d ms"):format(ms(function()
	bytes = draw.bytes(img)
end)))

print(("# send + blt (banded load, waited):    %d ms"):format(ms(function()
	fb.load(draw.rect(0, 0, W, H), bytes, true)
end)))

-- fill is the same rectangle with no pixels crossing the boundary at
-- all, so the gap between it and the line above is what the copy costs.
print(("# fill, same rectangle, no pixels:     %d ms"):format(ms(function()
	fb.fill(draw.rect(0, 0, W, H), 0x202030, true)
end)))

print(("# unload, same rectangle:              %d ms"):format(ms(function()
	fb.unload(draw.rect(0, 0, W, H))
end)))

print("#")
print("# --- whole screen ---")

print(("# fill (one firmware call):            %d ms"):format(ms(function()
	fb.fill(draw.rect(0, 0, mode.w, mode.h), 0x000020, true)
end)))

local screen = draw.image(mode.w, 64, 0x304050)
local sbytes = draw.bytes(screen)

print(("# load one %dx64 band:                %d ms"):format(mode.w,
    ms(function()
	fb.load(draw.rect(0, 0, mode.w, 64), sbytes, true)
end)))

print(("# scroll that band (video to video):   %d ms"):format(ms(function()
	fb.scroll(draw.rect(0, 0, mode.w, 64), draw.pt(0, 100), true)
end)))

print("#")
print("ok 1 - framebuffer bench")
sys.send(caps_of.power, { op = "reset", mode = "shutdown" })
