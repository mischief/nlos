-- draw: rectangles and in-memory images, in the proc that wants to
-- draw. no capability lives here -- nothing in this file can reach a
-- screen. it is the pixel arithmetic every client of task/fb.lua would
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
-- Row-major, no padding, and an image says which format its bytes are:
-- bgrx, four bytes, EFI_GRAPHICS_OUTPUT_BLT_PIXEL's layout; or r5g6b5,
-- two bytes, which an ST7789 takes. That is plan 9's chan, and it is
-- here for the same reason -- see fb.mode().format.

-- Colours in the API are 0xRRGGBB integers whichever it is, so the
-- packing happens once and only M.pixel and pixel16 know the layout.
--
-- ---- one buffer, written in place ----
--
-- plan 9's Memimage is one flat byte array, and so is this: a los.buf
-- of w*h*4, which is the layout task/fb.lua's load already wants.
--
-- A buffer is what makes that possible. Lua strings are immutable, so a
-- flat image made of them would rebuild itself on every write, and a
-- table of per-pixel integers costs sixteen bytes to store four. With
-- neither of those, a fill is bytes written where they belong and
-- allocates nothing at all.
--
-- bytes() is how pixels leave. For a whole image it is a view -- the
-- same bytes, no copy -- and a message takes a buffer wherever it takes
-- a string, so a picture reaches the screen without being cut up on the
-- way.

local buf = require("los.buf")

local M = {}

-- ---- points and rectangles ----
--
-- a rectangle is {x=,y=,w=,h=}, not plan 9's {min,max} pair. the two
-- are the same information and this is the form the wire protocol in
-- task/fb.lua and the Blt arguments underneath both already take, so
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

-- ---- formats ----

-- plan 9's chan, with two of them. An image says what its bytes mean
-- and a screen says what it takes, so a client allocating the screen's
-- format is never converted on the way there. bgrx is the default: it
-- is what EFI's Blt takes.
M.BGRX = "bgrx"
M.RGB16 = "r5g6b5"

-- Big-endian, which is what an ST7789 takes on the wire -- so a driver
-- copies rather than walking pixels. The order costs nothing here: a
-- fill packs one pixel and repeats it.
local function pixel16(color)
	local v = ((color >> 8) & 0xf800) | ((color >> 5) & 0x07e0) |
	    ((color >> 3) & 0x001f)

	return schar((v >> 8) & 0xff, v & 0xff)
end

local FMT = {
	[M.BGRX] = { bpp = 4, pixel = M.pixel },
	[M.RGB16] = { bpp = 2, pixel = pixel16 },
}

-- bytes per pixel of a format, so a caller can size a buffer without
-- knowing how the pixels are laid out.
function M.bpp(fmt)
	local f = FMT[fmt or M.BGRX]

	return f and f.bpp
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
function M.image(w, h, color, fmt)
	local f = FMT[fmt or M.BGRX]

	if not f then
		error("memdraw: no such format: " .. tostring(fmt), 2)
	end

	local img = setmetatable({ w = w, h = h, fmt = fmt or M.BGRX,
	    bpp = f.bpp, pix = f.pixel,
	    b = buf.new(w * h * f.bpp) }, Image)

	-- black is already what a new buffer holds, and it is the common
	-- case: a buffer arrives zeroed.
	if img.pix(color or M.black):find("[^%z]") then
		img:fill(img:rect(), color)
	end
	return img
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

	-- one run, copied into every row of the rectangle. The run is the
	-- only allocation, and it is one whatever the height.
	local bpp = self.bpp
	local run = self.pix(color):rep(c.w)
	local stride = self.w * bpp

	for y = c.y, c.y + c.h - 1 do
		self.b:copy(y * stride + c.x * bpp + 1, run)
	end
	return self
end

function Image:set(x, y, color)
	return self:fill(M.rect(x, y, 1, 1), color)
end

-- a line from p0 to p1, `thick` pixels wide, as a run of squares along
-- it. Square ends, no antialiasing: there is no alpha here to blend a
-- soft edge with. plan 9's line() takes end styles and a source image;
-- this takes a colour, which is what a caller has wanted so far.
function Image:line(p0, p1, thick, color)
	local dx, dy = p1.x - p0.x, p1.y - p0.y
	local n = math.max(math.abs(dx), math.abs(dy))
	local half = (thick or 1) // 2
	local w = thick or 1

	if n == 0 then
		return self:fill(M.rect(p0.x - half, p0.y - half, w, w), color)
	end
	for i = 0, n do
		local x = math.floor(p0.x + dx * i / n + 0.5)
		local y = math.floor(p0.y + dy * i / n + 0.5)

		self:fill(M.rect(x - half, y - half, w, w), color)
	end
	return self
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

	-- unlike formats have to go through a colour. Deliberately the
	-- slow way and not a converting blit: the point of asking the
	-- screen its format is that this path is not taken.
	if self.fmt ~= src.fmt then
		for i = 0, dst.h - 1 do
			for j = 0, dst.w - 1 do
				self:set(dst.x + j, dst.y + i,
				    M.at(src, sr.x + skipx + j,
				        sr.y + skipy + i))
			end
		end
		return self
	end

	local bpp = self.bpp
	local dstride = self.w * bpp
	local sstride = src.w * bpp
	local sx = (sr.x + skipx) * bpp

	for i = 0, dst.h - 1 do
		local sfrom = (sr.y + skipy + i) * sstride + sx

		-- buffer to buffer: no piece is cut out on the way
		self.b:copy((dst.y + i) * dstride + dst.x * bpp + 1, src.b,
		    sfrom + 1, sfrom + dst.w * bpp)
	end
	return self
end

-- the raw BGRx bytes of a rectangle, in the layout task/fb.lua's load
-- wants: rows concatenated, no padding. this is plan 9's unloadimage,
-- and it is the only way pixels leave an image.
function M.bytes(img, r)
	r = M.clip(r or img:rect(), img:rect())
	if M.empty(r) then
		return ""
	end

	-- the whole image is the common case and costs nothing: a view is
	-- the same bytes, and a message takes one wherever it takes a
	-- string.
	if r.x == 0 and r.y == 0 and r.w == img.w and r.h == img.h then
		return img.b:view()
	end

	-- a part of it has to be gathered, since the rows it wants are not
	-- next to each other. One buffer, and each row copied in once.
	local bpp = img.bpp
	local out = buf.new(r.w * r.h * bpp)
	local stride = img.w * bpp
	local rw = r.w * bpp

	for i = 0, r.h - 1 do
		local from = (r.y + i) * stride + r.x * bpp

		out:copy(i * rw + 1, img.b, from + 1, from + rw)
	end
	return out
end

Image.bytes = function(self, r) return M.bytes(self, r) end

-- raw bytes of the image's own format straight into a rectangle of it,
-- with no intermediate image. Refuses anything it cannot do as row
-- copies, so a caller falls back to fromBytes and draw.
function Image:rows(x, y, w, h, data, fmt)
	if (fmt or M.BGRX) ~= self.fmt or
	    x < 0 or y < 0 or x + w > self.w or y + h > self.h then
		return false
	end

	local bpp = self.bpp
	local stride = self.w * bpp
	local rw = w * bpp

	for i = 0, h - 1 do
		self.b:copy((y + i) * stride + x * bpp + 1, data,
		    i * rw + 1, (i + 1) * rw)
	end
	return true
end

-- the inverse: wrap raw BGRx bytes as an image, so pixels read back off
-- a screen can be drawn into and compared like any other image.
function M.fromBytes(w, h, data, fmt)
	local img = M.image(w, h, nil, fmt)

	img.b:copy(1, data)
	return img
end

-- read one pixel as 0xRRGGBB. for tests and for asking questions at the
-- repl, not for loops.
function M.at(img, x, y)
	if x < 0 or y < 0 or x >= img.w or y >= img.h then
		return nil
	end

	local i = (y * img.w + x) * img.bpp

	if img.bpp == 2 then
		local hi, lo = img.b:byte(i + 1, i + 2)
		local v = (hi << 8) | lo
		-- the low bits back, so a colour survives a round trip
		-- through 565 as the nearest one that fits rather than
		-- as a darker one
		local r = (v >> 11) & 0x1f
		local g = (v >> 5) & 0x3f
		local b = v & 0x1f

		return (((r << 3) | (r >> 2)) << 16) |
		    (((g << 2) | (g >> 4)) << 8) | ((b << 3) | (b >> 2))
	end

	local b, g, r = img.b:byte(i + 1, i + 3)

	return (r << 16) | (g << 8) | b
end

Image.at = M.at

M.Image = Image

return M
