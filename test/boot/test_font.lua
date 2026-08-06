-- los.font is ambient: glyphs are data, not a device, so every proc can
-- require it the same way it can require los.crc. This proves that the
-- move out of the esp32 platform and into the shared kernel module table
-- reaches a plain proc on efi/microvm, and that the rasteriser packs the
-- BGRx layout fb.load consumes.
local tap = require("tap")

tap.plan(11)

-- reachable without any capability. a proc that holds no PRIV can still
-- turn a string into pixels; only putting them on a screen needs the fb
-- right.
local ok, font = pcall(require, "los.font")

tap.ok(ok, "los.font is requireable by an ordinary proc")
if not ok then
	return
end

-- the cell. callers size a screen in columns and rows off this without
-- knowing which font it is.
local w, h = font.size()

tap.is(w, 6, "font.size width is the cell width")
tap.is(h, 12, "font.size height is the cell height")

-- the empty string is a real answer, not an error: zero-width, full
-- height, no bytes.
local pix, rw, rh = font.render("", 0xffffff, 0)

tap.is(rw, 0, "render('') is zero columns wide")
tap.is(rh, h, "render('') keeps the cell height")
tap.is(#pix, 0, "render('') has no pixels")

-- one glyph: width is one cell, four bytes a pixel.
pix, rw, rh = font.render("A", 0xffffff, 0)
tap.is(rw, w, "render('A') is one cell wide")
tap.is(#pix, w * h * 4, "render('A') is w*h*4 bytes of BGRx")

-- n glyphs: width scales, so a line is one render and one load.
pix = font.render("AB", 0xffffff, 0)
tap.is(#pix, 2 * w * h * 4, "render scales width with the string")

-- BGRx order and packing, glyph-shape-blind: with fg == bg every pixel
-- is that one colour whatever the glyph, so the bytes must read B,G,R,0
-- for 0xRRGGBB.
pix = font.render("M", 0x112233, 0x112233)
local packed = true
for i = 1, #pix, 4 do
	if pix:byte(i) ~= 0x33 or pix:byte(i + 1) ~= 0x22 or
	    pix:byte(i + 2) ~= 0x11 or pix:byte(i + 3) ~= 0x00 then
		packed = false
		break
	end
end
tap.ok(packed, "fg==bg fills every pixel as BGRx 0x112233")

-- the decoder actually distinguishes ink from paper: a non-blank glyph
-- drawn with distinct colours yields both. proves it reads the bitmap
-- rather than flooding one value.
pix = font.render("M", 0xffffff, 0x000000)
local sawfg, sawbg = false, false
for i = 1, #pix, 4 do
	local b = pix:byte(i)
	if b == 0xff then sawfg = true elseif b == 0x00 then sawbg = true end
end
tap.ok(sawfg and sawbg, "a glyph has both ink and paper pixels")
