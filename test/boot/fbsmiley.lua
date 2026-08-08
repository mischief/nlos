-- a smiley face, drawn on the framebuffer. run it with
-- `ninja -C build-gop smiley`, which opens a qemu window.
--
-- it is a demo and it is also the cheapest test of the thing readback
-- cannot check: whether a person looking at the screen sees what we
-- meant. a circle drawn with the wrong stride is still a valid
-- rectangle of pixels and still passes test/boot/test_fb.lua.
--
-- everything is composed into ONE off-screen image and loaded once, so
-- the picture appears whole rather than assembling itself in front of
-- you. that is the same discipline a window system needs -- compose,
-- then ship the damaged rectangle -- and at this size it is also just
-- faster than a fill per span.
local sys = require("los.sys")
local capfb = require("caps.fb")
local draw = require("draw")

local caps_of = sys.granted()

if not caps_of.fb then
	print("no framebuffer on this machine")
	while true do
		sys.yield()
	end
end

local fb = capfb.new(caps_of.fb)
local mode = fb.mode()
local W, H = mode.w, mode.h

-- a filled circle as one horizontal span per row. no antialiasing:
-- blending needs an alpha channel, and adding one to draw.lua is a
-- real design rather than a tweak (see its header).
local function disc(img, cx, cy, rad, color)
	for dy = -rad, rad do
		local dx = math.floor(math.sqrt(rad * rad - dy * dy) + 0.5)

		img:fill(draw.rect(cx - dx, cy + dy, dx * 2 + 1, 1), color)
	end
end

-- the same, minus a disc of its own: an annulus, used for the mouth so
-- the smile is a crescent rather than a half-disc.
local function arc(img, cx, cy, rad, thick, color, from, to)
	for dy = -rad, rad do
		local y = cy + dy

		if y >= from and y <= to then
			local outer = math.floor(
			    math.sqrt(rad * rad - dy * dy) + 0.5)
			local inner = 0
			local ir = rad - thick

			if math.abs(dy) < ir then
				inner = math.floor(
				    math.sqrt(ir * ir - dy * dy) + 0.5)
			end
			img:fill(draw.rect(cx - outer, y, outer - inner, 1),
			    color)
			img:fill(draw.rect(cx + inner, y, outer - inner, 1),
			    color)
		end
	end
end

local size = 320
local face = draw.image(size, size, 0x101018)
local c = size // 2
local yellow = 0xffcc00
local dark = 0x101018

disc(face, c, c, size // 2 - 4, yellow)
disc(face, c - 55, c - 45, 22, dark)		-- left eye
disc(face, c + 55, c - 45, 22, dark)		-- right eye
arc(face, c, c - 10, 105, 18, dark, c + 20, size)	-- the smile

print(("drawing a smiley on a %dx%d framebuffer"):format(W, H))

fb.fill(draw.rect(0, 0, W, H), 0x101018)
fb.load(draw.rect((W - size) // 2, (H - size) // 2, size, size),
    draw.bytes(face))
fb.sync()

print("SCREENSHOT READY")

-- stay up so there is something to look at. the window is closed by
-- quitting qemu (ctrl-alt-q, or just close it).
while true do
	sys.yield()
end
