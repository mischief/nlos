-- the payload scripts/screenshot.lua boots: draw enough that a human
-- looking at the picture can tell the layer works, then say so on the
-- serial line and stop.
--
-- it must NOT power off. qemu exiting takes the framebuffer with it and
-- there is nothing left to capture -- see screenshot.lua's header.
--
-- what is drawn is chosen so that a WRONG picture is obviously wrong
-- rather than merely different:
--   * colour bars name their own colours, so a red/blue swap (the BGRx
--     mistake) is visible and not a matter of taste
--   * the gradient is a load of pixels built in lua, so a stride bug
--     skews it into diagonal stripes
--   * the checkerboard is drawn by compositing one image into another
--     before any of it reaches the screen, which is the operation a
--     window system is going to lean on
local sys = require("los.sys")
local capfb = require("caps.fb")
local draw = require("draw")

local caps_of = sys.granted()

if not caps_of.fb then
	print("no framebuffer on this machine")
	print("SCREENSHOT READY")
	while true do
		sys.yield()
	end
end

local fb = capfb.new(caps_of.fb)
local mode = fb.mode()
local W, H = mode.w, mode.h

print(("framebuffer: %dx%d %s"):format(W, H, mode.format))

fb.fill(draw.rect(0, 0, W, H), 0x101018)

-- ---- colour bars ----

local bars = {
	{ draw.red, "red" },
	{ draw.green, "green" },
	{ draw.blue, "blue" },
	{ 0xffff00, "yellow" },
	{ 0x00ffff, "cyan" },
	{ 0xff00ff, "magenta" },
	{ draw.white, "white" },
}
local bw = W // #bars

for i, bar in ipairs(bars) do
	fb.fill(draw.rect((i - 1) * bw, 0, bw, 80), bar[1])
end

-- ---- a gradient, built pixel by pixel in lua ----
--
-- the one thing here that goes through load() with real per-pixel data.
-- 256x64 is small on purpose: this is the expensive shape (a string per
-- row, rebuilt once) and the point is to show it works, not to pretend
-- it is how you would fill a screen.

local grad = draw.image(256, 64, draw.black)

for x = 0, 255 do
	grad:fill(draw.rect(x, 0, 1, 64), (x << 16) | ((255 - x) << 8) | 0x40)
end
fb.load(draw.rect(20, 100, 256, 64), draw.bytes(grad))

-- ---- compositing: a checkerboard assembled off-screen ----
--
-- two images and a draw() into a third, so the whole thing crosses to
-- the screen as ONE load. that is the shape a window system wants --
-- compose, then load the damaged rectangle once -- rather than a fill
-- per square straight to the screen.

local sq = 16
local board = draw.image(sq * 8, sq * 8, draw.black)
local light = draw.image(sq, sq, 0xc0c0d0)

for row = 0, 7 do
	for col = 0, 7 do
		if (row + col) % 2 == 0 then
			board:draw(draw.pt(col * sq, row * sq), light)
		end
	end
end
fb.load(draw.rect(320, 100, sq * 8, sq * 8), draw.bytes(board))

-- ---- scroll: an on-screen copy the firmware does for us ----
--
-- copy the colour bars down the screen without the pixels ever entering
-- our address space.
fb.scroll(draw.rect(0, 0, W, 80), draw.pt(0, H - 80))

-- one round trip, so every load above has certainly landed before we
-- announce that the screen is ready to photograph.
fb.sync()

print("SCREENSHOT READY")

-- stay alive and off the cpu. the host screendumps and then quits us.
while true do
	sys.yield()
end
