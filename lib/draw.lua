-- draw: rectangles and in-memory images, in the proc that wants to
-- draw. no capability lives here -- nothing in this file can reach a
-- screen. it is the pixel arithmetic every client of lib/fb.lua would
-- otherwise write for itself, and the layer a rio-shaped thing would be
-- built on.
--
-- the vocabulary is plan 9's because the layering is: an Image is a
-- rectangle of pixels you can draw into, and the screen is one more
-- Image that happens to live behind a capability. that is what lets
-- libmemlayer exist above libmemdraw without either knowing about the
-- other, and it is the reason a window here will be able to be an
-- ordinary Image with a save area rather than a special case.
--
-- ---- pixels ----
--
-- BGRx, four bytes per pixel, row-major, no padding between rows. that
-- is EFI_GRAPHICS_OUTPUT_BLT_PIXEL's layout and it is the same whatever
-- the hardware format underneath is, because Blt converts (see
-- src/platform/efi/gop.c). colours in the API are 0xRRGGBB integers,
-- which is what anyone writing one by hand expects; the packing to BGRx
-- happens once, here.
--
-- ---- why rows and not one buffer ----
--
-- plan 9's Memimage is one flat byte array. lua strings are immutable,
-- so the flat version would rebuild the whole image on every write, and
-- a table of per-pixel integers costs sixteen bytes to store four.
--
-- so an image is a table of one string per row. a fill or a blit
-- touches only the rows in its rectangle and rebuilds each of those
-- once, which makes the cost proportional to the area changed rather
-- than to the image -- the property that actually matters. a single-
-- pixel write is the bad case (it rebuilds a whole row) and it is the
-- operation you should not be writing loops of anyway; use fill.
--
-- this shape is not load-bearing for anything outside this file:
-- bytes() is how pixels leave, and only it and the drawing operations
-- know about rows.

local M = {}

-- ---- points and rectangles ----
--
-- a rectangle is {x=,y=,w=,h=}, not plan 9's {min,max} pair. the two
-- are the same information and this is the form the wire protocol in
-- lib/fb.lua and the Blt arguments underneath both already take, so
-- carrying min/max would mean converting at every boundary to gain
-- nothing but the ability to write r.max.x.

function M.rect(x, y, w, h)
	return { x = x, y = y, w = w, h = h }
end

function M.pt(x, y)
	return { x = x, y = y }
end

-- the intersection, which may be empty (w or h <= 0). callers that must
-- not draw an empty rectangle check with M.empty rather than getting a
-- nil they have to test for separately.
function M.clip(a, b)
	local x0 = a.x > b.x and a.x or b.x
	local y0 = a.y > b.y and a.y or b.y
	local x1 = a.x + a.w < b.x + b.w and a.x + a.w or b.x + b.w
	local y1 = a.y + a.h < b.y + b.h and a.y + a.h or b.y + b.h

	return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

function M.empty(r)
	return r.w <= 0 or r.h <= 0
end

function M.contains(r, p)
	return p.x >= r.x and p.y >= r.y and p.x < r.x + r.w and
	    p.y < r.y + r.h
end

-- ---- colour ----

local schar = string.char

-- 0xRRGGBB -> the four bytes Blt wants. the fourth is the "Reserved"
-- byte of EFI_GRAPHICS_OUTPUT_BLT_PIXEL, which is not alpha and is not
-- looked at; zero is what the spec says to put there.
function M.pixel(color)
	return schar(color & 0xff, (color >> 8) & 0xff,
	    (color >> 16) & 0xff, 0)
end

M.black = 0x000000
M.white = 0xffffff
M.red = 0xff0000
M.green = 0x00ff00
M.blue = 0x0000ff

-- ---- images ----

local Image = {}
Image.__index = Image

-- a w-by-h image, filled with color (default black). the origin is
-- always 0,0: an image's own coordinates are its own, and where it goes
-- on a screen is the business of whoever draws it there. plan 9 allows
-- a non-zero Memimage.r origin and then spends real effort converting
-- between image and screen coordinates in libmemlayer; there is no
-- reason to inherit that here before something needs it.
function M.image(w, h, color)
	local row = M.pixel(color or M.black):rep(w)
	local rows = {}

	for y = 1, h do
		rows[y] = row
	end
	return setmetatable({ w = w, h = h, rows = rows }, Image)
end

function Image:rect()
	return M.rect(0, 0, self.w, self.h)
end

-- overwrite a rectangle with one colour. clipped, so a caller may pass
-- a rectangle that hangs off the edge and get the sane thing.
function Image:fill(r, color)
	local c = M.clip(r, self:rect())

	if M.empty(c) then
		return self
	end

	local run = M.pixel(color):rep(c.w)
	local head = c.x * 4
	local tail = (c.x + c.w) * 4 + 1

	for y = c.y + 1, c.y + c.h do
		local old = self.rows[y]

		self.rows[y] = old:sub(1, head) .. run .. old:sub(tail)
	end
	return self
end

function Image:set(x, y, color)
	return self:fill(M.rect(x, y, 1, 1), color)
end

-- copy src into self with src's origin landing at p. this is plan 9's
-- draw() with no mask and the S-over-D operator degenerating to a plain
-- copy: there is no alpha here, and adding one means adding a channel
-- descriptor to every image, which is a real design and not a tweak.
function Image:draw(p, src, sr)
	sr = sr or src:rect()

	local dst = M.clip(M.rect(p.x + sr.x, p.y + sr.y, sr.w, sr.h),
	    self:rect())

	if M.empty(dst) then
		return self
	end

	-- how far the clip moved the destination corner, so the source
	-- rectangle follows it rather than being copied from the wrong
	-- place when p is negative or the copy runs off an edge.
	local skipx = dst.x - (p.x + sr.x)
	local skipy = dst.y - (p.y + sr.y)
	local head = dst.x * 4
	local tail = (dst.x + dst.w) * 4 + 1

	for i = 0, dst.h - 1 do
		local from = src.rows[sr.y + skipy + i + 1]
		local piece = from:sub((sr.x + skipx) * 4 + 1,
		    (sr.x + skipx + dst.w) * 4)
		local old = self.rows[dst.y + i + 1]

		self.rows[dst.y + i + 1] = old:sub(1, head) .. piece ..
		    old:sub(tail)
	end
	return self
end

-- the raw BGRx bytes of a rectangle, in the layout lib/fb.lua's load
-- wants: rows concatenated, no padding. this is plan 9's unloadimage,
-- and it is the only way pixels leave an image.
function M.bytes(img, r)
	r = M.clip(r or img:rect(), img:rect())
	if M.empty(r) then
		return ""
	end

	local out = {}
	local from = r.x * 4 + 1
	local to = (r.x + r.w) * 4

	for i = 1, r.h do
		out[i] = img.rows[r.y + i]:sub(from, to)
	end
	return table.concat(out)
end

Image.bytes = function(self, r) return M.bytes(self, r) end

-- the inverse: wrap raw BGRx bytes as an image, so pixels read back off
-- a screen can be drawn into and compared like any other image.
function M.fromBytes(w, h, data)
	local rows = {}
	local stride = w * 4

	for y = 1, h do
		rows[y] = data:sub((y - 1) * stride + 1, y * stride)
	end
	return setmetatable({ w = w, h = h, rows = rows }, Image)
end

-- read one pixel as 0xRRGGBB. for tests and for asking questions at the
-- repl, not for loops.
function M.at(img, x, y)
	local row = img.rows[y + 1]

	if not row then
		return nil
	end
	local b, g, r = row:byte(x * 4 + 1, x * 4 + 3)

	if not b then
		return nil
	end
	return (r << 16) | (g << 8) | b
end

Image.at = M.at

M.Image = Image

return M
