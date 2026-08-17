-- the framebuffer, end to end: proc 0 holds a right to the fb task and
-- nothing else does, and every pixel that goes out can be read back.
--
-- readback is what makes this a real test rather than a smoke test. a
-- fill that silently did nothing looks identical to a fill that worked
-- if all you check is that the call returned -- which is the failure
-- mode graphics code actually has.
local sys = require("los.sys")
local draw = require("draw")
local memdraw = require("memdraw")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(36)

tap.ok(caps_of.fb ~= nil, "boot payload was granted fb")
if not caps_of.fb then
	tap.done()
	return
end

local fb = draw.new(caps_of.fb)
local mode = fb.mode()

tap.ok(mode ~= nil and mode.w > 0 and mode.h > 0,
    ("mode is %sx%s (%s)"):format(mode and mode.w, mode and mode.h,
        mode and mode.format))

local modes = fb.modes()

tap.ok(#modes >= 1, "at least one mode is enumerable")

-- ---- fill, then read it back ----

local r = memdraw.rect(0, 0, 64, 32)

fb.fill(r, memdraw.red, true)

local pix = fb.unload(r)

tap.is(#pix, 64 * 32 * 4, "unload returns w*h*4 bytes")

local img = memdraw.fromBytes(64, 32, pix)

tap.is(memdraw.at(img, 0, 0), memdraw.red, "the filled corner really is red")
tap.is(memdraw.at(img, 63, 31), memdraw.red, "and so is the far corner")

-- ---- the same rectangle with the pad left off ----
--
-- What task/shot.lua reads, so that a screenshot is not a string.char
-- per pixel. The check that matters is not the length: it is that the
-- three bytes are the same three the BGRx answer carries, in the order
-- a PPM wants -- a driver writing them backwards passes a length test
-- and hands back a picture with red and blue swapped.
local rgb = fb.unload(r, "rgb")

tap.is(#rgb, 64 * 32 * 3, "unload rgb returns w*h*3 bytes")

local sheared = false

for i = 0, 64 * 32 - 1 do
	if rgb:sub(i * 3 + 1, i * 3 + 3) ~=
	    string.char(pix:byte(i * 4 + 3), pix:byte(i * 4 + 2),
	        pix:byte(i * 4 + 1)) then
		sheared = true
		break
	end
end
tap.ok(not sheared, "every rgb pixel is its bgrx pixel, unpadded")

-- ---- load an image built in lua ----
--
-- two quadrants of one 16x16 image, so a wrong stride or a swapped
-- x/y shows up as the wrong colour rather than as nothing.

local src = memdraw.image(16, 16, memdraw.blue)

src:fill(memdraw.rect(8, 0, 8, 8), memdraw.green)
fb.load(memdraw.rect(100, 100, 16, 16), memdraw.bytes(src), true)

local back = memdraw.fromBytes(16, 16, fb.unload(memdraw.rect(100, 100, 16, 16)))

tap.is(memdraw.at(back, 0, 0), memdraw.blue, "loaded image: left is blue")
tap.is(memdraw.at(back, 12, 4), memdraw.green, "loaded image: top right is green")
tap.is(memdraw.at(back, 12, 12), memdraw.blue, "loaded image: bottom right is blue")

-- ---- a load bigger than one message ----
--
-- the regression test for the bug that drew a smiley as a yellow arc.
-- 320 wide is 1280 bytes a row, so ~50 rows per band and this goes out
-- as several -- and MAXQUEUE is the same 64KiB as MAXMSG, so at most
-- one of them is in flight. before draw applied backpressure, every
-- band after the first was dropped by a full queue and sys.send's
-- return said so to nobody.
--
-- checking the LAST row is the whole point: the first band always
-- worked, so anything that only samples the top of the rectangle passes
-- while the picture is visibly wrong.
local tall = memdraw.image(320, 320, memdraw.blue)

tall:fill(memdraw.rect(0, 319, 320, 1), memdraw.green)
tall:fill(memdraw.rect(0, 160, 320, 1), memdraw.red)

fb.load(memdraw.rect(0, 0, 320, 320), memdraw.bytes(tall), true)

local got = memdraw.fromBytes(320, 320, fb.unload(memdraw.rect(0, 0, 320, 320)))

tap.is(memdraw.at(got, 160, 0), memdraw.blue, "banded load: first row survives")
tap.is(memdraw.at(got, 160, 160), memdraw.red, "banded load: a middle row survives")
tap.is(memdraw.at(got, 160, 319), memdraw.green, "banded load: the LAST row survives")

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
local wide = memdraw.image(mode.w, 24, memdraw.blue)

wide:fill(memdraw.rect(mode.w - 1, 23, 1, 1), memdraw.green)
wide:fill(memdraw.rect(0, 23, 1, 1), memdraw.red)

fb.load(memdraw.rect(0, 200, mode.w, 24), memdraw.bytes(wide), true)

local wback = memdraw.fromBytes(mode.w, 24,
    fb.unload(memdraw.rect(0, 200, mode.w, 24)))

tap.is(memdraw.at(wback, 0, 23), memdraw.red, "full-width load: last row, left edge")
tap.is(memdraw.at(wback, mode.w - 1, 23), memdraw.green,
    "full-width load: last row, right edge")

-- ---- images the server keeps ----

-- what devdraw's ids buy: pixels cross once, and a frame made of them
-- is a message. Everything below is checked by reading the screen back,
-- so it proves the server's own memory reached the glass.

local id = fb.alloc(16, 16, nil, memdraw.blue)

tap.ok(type(id) == "number", "alloc answers an image id")

-- into the image, not the screen: the glass must not change yet
fb.fill(memdraw.rect(0, 0, 16, 8), memdraw.green, true, id)

local before = memdraw.fromBytes(16, 16, fb.unload(memdraw.rect(0, 0, 16, 16)))

tap.ok(memdraw.at(before, 0, 0) ~= memdraw.green,
    "a fill into an image leaves the screen alone")

-- and now the same pixels, in one message carrying none of them
fb.draw(nil, id, memdraw.rect(0, 0, 16, 16), memdraw.pt(0, 0), true)

local shown = memdraw.fromBytes(16, 16, fb.unload(memdraw.rect(0, 0, 16, 16)))

tap.is(memdraw.at(shown, 0, 0), memdraw.green, "drawn to the screen: top")
tap.is(memdraw.at(shown, 15, 15), memdraw.blue, "drawn to the screen: bottom")

-- image to image, which never touches the glass
local other = fb.alloc(16, 16, nil, memdraw.red)

fb.draw(other, id, memdraw.rect(0, 0, 16, 4), memdraw.pt(0, 0), true)
fb.draw(nil, other, memdraw.rect(0, 0, 16, 16), memdraw.pt(0, 0), true)

local both = memdraw.fromBytes(16, 16, fb.unload(memdraw.rect(0, 0, 16, 16)))

tap.is(memdraw.at(both, 0, 0), memdraw.green, "image into image: the part copied")
tap.is(memdraw.at(both, 0, 8), memdraw.red, "image into image: the part not")

-- the whole of src into the whole of dst, which is what a caller
-- writes when it means "copy this over that" and is the shape a
-- pristine background is blitted with
local under = fb.alloc(16, 16, nil, memdraw.white)

fb.draw(under, id, nil, nil, true)
fb.draw(nil, under, memdraw.rect(0, 0, 16, 16), memdraw.pt(0, 0), true)

local whole = memdraw.fromBytes(16, 16, fb.unload(memdraw.rect(0, 0, 16, 16)))

tap.is(memdraw.at(whole, 0, 0), memdraw.green,
    "draw with no rectangle takes all of the source")
tap.is(memdraw.at(whole, 15, 15), memdraw.blue,
    "and lands it at the destination's origin")

fb.free(under)

-- a line is drawn in the server, so a diagonal costs one message
fb.line(other, memdraw.pt(0, 0), memdraw.pt(15, 15), 1, memdraw.white, true)
fb.draw(nil, other, memdraw.rect(0, 0, 16, 16), memdraw.pt(0, 0), true)

local lined = memdraw.fromBytes(16, 16, fb.unload(memdraw.rect(0, 0, 16, 16)))

tap.is(memdraw.at(lined, 7, 7), memdraw.white, "a line reaches its middle")

fb.free(id)
fb.free(other)

local gone, ferr = fb.draw(nil, id, memdraw.rect(0, 0, 4, 4),
    memdraw.pt(0, 0), true)

tap.ok(not gone and tostring(ferr):find("no such image"),
    "a freed id is refused: " .. tostring(ferr))

-- ---- an image space per client ----

-- Ids are small integers, so a shared table would let one client name
-- another's image by guessing. Two sessions each allocate first, both
-- get the same number, and neither can see the other's pixels.

local s1 = fb.session()
local s2 = fb.session()

tap.ok(s1 ~= nil and s2 ~= nil, "a client can ask for its own image space")

local i1 = s1.alloc(8, 8, nil, memdraw.green)
local i2 = s2.alloc(8, 8, nil, memdraw.red)

tap.is(i1, i2, "each session numbers its own images from the same start")

s1.draw(nil, i1, memdraw.rect(0, 0, 8, 8), memdraw.pt(0, 0), true)

local mine = memdraw.fromBytes(8, 8, fb.unload(memdraw.rect(0, 0, 8, 8)))

tap.is(memdraw.at(mine, 0, 0), memdraw.green, "one session's id is its own")

s2.draw(nil, i2, memdraw.rect(0, 0, 8, 8), memdraw.pt(0, 0), true)

local theirs = memdraw.fromBytes(8, 8, fb.unload(memdraw.rect(0, 0, 8, 8)))

tap.is(memdraw.at(theirs, 0, 0), memdraw.red,
    "and the other's id of the same number is not")

-- the task's own port is a third space. Its ids carry on from the
-- allocations above rather than restarting, which is what says it is a
-- space of its own and not one the sessions share.
local anon = fb.alloc(8, 8, nil, memdraw.blue)

fb.draw(nil, anon, memdraw.rect(0, 0, 8, 8), memdraw.pt(0, 0), true)

local third = memdraw.fromBytes(8, 8, fb.unload(memdraw.rect(0, 0, 8, 8)))

tap.is(memdraw.at(third, 0, 0), memdraw.blue,
    "the task's own port is a third space, numbered separately")

-- ---- and a client that goes away takes its images with it ----

-- The reason ids are per client rather than merely tidy: nothing else
-- can free them. A big image makes the drop measurable in the server's
-- own memory rather than inferred.

local function fbused()
	for _, pid in ipairs(sys.procs()) do
		local st = sys.pidstat(pid)

		if st.name == "fb" then
			return st.used
		end
	end
end

local doomed = fb.session()
local before2 = fbused()

doomed.alloc(256, 256, nil, memdraw.red)

local held = fbused()

tap.ok(before2 == nil or held > before2 + 200000,
    "a 256x256 image is charged to the server that holds it")

-- dropping the right is all a dying program does
sys.close(doomed.handle)
fb.mode()			-- a message, so the loop notices the hangup
fb.mode()

local after2 = fbused()

tap.ok(before2 == nil or after2 < held - 200000,
    "and it goes when the client's right does (" .. tostring(held) ..
    " -> " .. tostring(after2) .. ")")

-- ---- refusals ----
--
-- a rectangle off the edge must raise rather than let the firmware
-- decide what to do with it, and a short buffer must be caught before
-- the firmware reads past its end.

local ok, err = fb.load(memdraw.rect(0, 0, 4, 4), "short", true)

tap.ok(not ok and tostring(err):find("bytes"),
    "a short pixel buffer is refused: " .. tostring(err))

ok, err = fb.fill(memdraw.rect(mode.w, mode.h, 8, 8), memdraw.white, true)
tap.ok(not ok and tostring(err):find("off a"),
    "a rectangle off the screen is refused: " .. tostring(err))

-- ---- a client that stops reading must not stop the screen ----
--
-- One loop serves every window on the machine. Waiting for room in a
-- client's queue would let any app freeze the panel for all of them, so
-- an undeliverable reply is dropped. The port below is never read, which
-- is what a wedged or dying app looks like from here.
local deaf = sys.newport("test_fb.deaf")
local deafsend = sys.sendright(deaf)

for _ = 1, 400 do
	sys.send(fb.handle, { op = "mode", reply = { __right = deafsend } })
end

local still = fb.mode()

tap.ok(type(still) == "table" and still.w == mode.w,
    "the screen answers after a client stopped reading its replies")

sys.close(deafsend)
sys.close(deaf)

tap.done()
