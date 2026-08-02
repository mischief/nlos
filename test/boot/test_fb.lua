-- the framebuffer, end to end: proc 0 holds a right to the fb task and
-- nothing else does, and every pixel that goes out can be read back.
--
-- readback is what makes this a real test rather than a smoke test. a
-- fill that silently did nothing looks identical to a fill that worked
-- if all you check is that the call returned -- which is the failure
-- mode graphics code actually has.
local sys = require("los.sys")
local caps = require("caps")
local draw = require("draw")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(11)

tap.ok(caps_of.fb ~= nil, "boot payload was granted fb")
if not caps_of.fb then
	tap.done()
	return
end

local fb = caps.fb(caps_of.fb)
local mode = fb.mode()

tap.ok(mode ~= nil and mode.w > 0 and mode.h > 0,
    ("mode is %sx%s (%s)"):format(mode and mode.w, mode and mode.h,
        mode and mode.format))

local modes = fb.modes()

tap.ok(#modes >= 1, "at least one mode is enumerable")

-- ---- fill, then read it back ----

local r = draw.rect(0, 0, 64, 32)

fb.fill(r, draw.red, true)

local pix = fb.unload(r)

tap.is(#pix, 64 * 32 * 4, "unload returns w*h*4 bytes")

local img = draw.fromBytes(64, 32, pix)

tap.is(draw.at(img, 0, 0), draw.red, "the filled corner really is red")
tap.is(draw.at(img, 63, 31), draw.red, "and so is the far corner")

-- ---- load an image built in lua ----
--
-- two quadrants of one 16x16 image, so a wrong stride or a swapped
-- x/y shows up as the wrong colour rather than as nothing.

local src = draw.image(16, 16, draw.blue)

src:fill(draw.rect(8, 0, 8, 8), draw.green)
fb.load(draw.rect(100, 100, 16, 16), draw.bytes(src), true)

local back = draw.fromBytes(16, 16, fb.unload(draw.rect(100, 100, 16, 16)))

tap.is(draw.at(back, 0, 0), draw.blue, "loaded image: left is blue")
tap.is(draw.at(back, 12, 4), draw.green, "loaded image: top right is green")
tap.is(draw.at(back, 12, 12), draw.blue, "loaded image: bottom right is blue")

-- ---- refusals ----
--
-- a rectangle off the edge must raise rather than let the firmware
-- decide what to do with it, and a short buffer must be caught before
-- the firmware reads past its end.

local ok, err = fb.load(draw.rect(0, 0, 4, 4), "short", true)

tap.ok(not ok and tostring(err):find("bytes"),
    "a short pixel buffer is refused: " .. tostring(err))

ok, err = fb.fill(draw.rect(mode.w, mode.h, 8, 8), draw.white, true)
tap.ok(not ok and tostring(err):find("off a"),
    "a rectangle off the screen is refused: " .. tostring(err))

tap.done()
