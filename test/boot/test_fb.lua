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

tap.plan(16)

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

-- ---- a load bigger than one message ----
--
-- the regression test for the bug that drew a smiley as a yellow arc.
-- 320 wide is 1280 bytes a row, so ~50 rows per band and this goes out
-- as several -- and MAXQUEUE is the same 64KiB as MAXMSG, so at most
-- one of them is in flight. before caps.fb applied backpressure, every
-- band after the first was dropped by a full queue and sys.send's
-- return said so to nobody.
--
-- checking the LAST row is the whole point: the first band always
-- worked, so anything that only samples the top of the rectangle passes
-- while the picture is visibly wrong.
local tall = draw.image(320, 320, draw.blue)

tall:fill(draw.rect(0, 319, 320, 1), draw.green)
tall:fill(draw.rect(0, 160, 320, 1), draw.red)

fb.load(draw.rect(0, 0, 320, 320), draw.bytes(tall), true)

local got = draw.fromBytes(320, 320, fb.unload(draw.rect(0, 0, 320, 320)))

tap.is(draw.at(got, 160, 0), draw.blue, "banded load: first row survives")
tap.is(draw.at(got, 160, 160), draw.red, "banded load: a middle row survives")
tap.is(draw.at(got, 160, 319), draw.green, "banded load: the LAST row survives")

-- ---- a row wider than a message ----
--
-- 1280 pixels is 5120 bytes, so a full-width row fits easily; the
-- horizontal split only triggers past ~16000 pixels a row, which no
-- mode here has. so exercise it the only way that is honest on this
-- hardware: a full-width band tall enough to need banding, checked at
-- both ends of a row as well as top and bottom.
--
-- (the recursion itself is what plan 9's loadimage does when
-- chunk/bpl comes out zero. we cannot reach it with a real mode, and
-- the code is there so that a machine with a 16k-wide framebuffer --
-- or a smaller MAXMSG -- does not meet an error instead.)
local wide = draw.image(mode.w, 24, draw.blue)

wide:fill(draw.rect(mode.w - 1, 23, 1, 1), draw.green)
wide:fill(draw.rect(0, 23, 1, 1), draw.red)

fb.load(draw.rect(0, 200, mode.w, 24), draw.bytes(wide), true)

local wback = draw.fromBytes(mode.w, 24,
    fb.unload(draw.rect(0, 200, mode.w, 24)))

tap.is(draw.at(wback, 0, 23), draw.red, "full-width load: last row, left edge")
tap.is(draw.at(wback, mode.w - 1, 23), draw.green,
    "full-width load: last row, right edge")

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
