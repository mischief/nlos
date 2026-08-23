-- menu: a popup list over a panel app, and the corner button that
-- opens it.

-- Nothing here draws. The caller passes two primitives -- fill a
-- rectangle, put a string somewhere -- so this holds only the geometry
-- and what a point or a key means, which is what a host can test with
-- no framebuffer at all.

-- On a screen this size a menu is how a program says what it can do.
-- Keys alone are invisible, and a row of buttons is the width the
-- content wanted. So: one square in a corner, and a list that covers
-- the page while it is up and is gone the moment it is answered.

local M = {}

local Menu = {}

Menu.__index = Menu

-- the corner square, in cells of the font the caller draws with
M.BUTTON = 11

-- items are { id, label, key }. id is what a pick returns and defaults
-- to the label; key is the keystroke that does the same thing, shown
-- on the right so the menu teaches what it is a substitute for.
function M.new(o)
	local m = setmetatable({
		items = o.items or {},
		title = o.title,
		fw = o.fw or 6,
		fh = o.fh or 12,
		rowh = o.rowh or 13,
		pad = o.pad or 3,
		-- the screen it has to fit inside
		w = o.w or 320,
		h = o.h or 240,
		top = o.top or 0,
		open = false,
		sel = 1,
	}, Menu)

	m:measure()
	return m
end

function Menu:measure()
	local wide = 0

	for _, it in ipairs(self.items) do
		local n = #it.label + (it.key and (#it.key + 3) or 0)

		if n > wide then
			wide = n
		end
	end
	if self.title and #self.title > wide then
		wide = #self.title
	end

	self.bw = math.min(self.w, wide * self.fw + self.pad * 4)
	self.bh = (#self.items + (self.title and 1 or 0)) * self.rowh
	    + self.pad * 2
	if self.bh > self.h - self.top then
		self.bh = self.h - self.top
	end
end

-- where the popup sits: under the button, and pulled back inside the
-- screen rather than drawn off the edge of it
function Menu:rect()
	local x = 0
	local y = self.top

	if y + self.bh > self.h then
		y = self.h - self.bh
	end
	if y < 0 then
		y = 0
	end
	return x, y, self.bw, self.bh
end

function Menu:isopen()
	return self.open
end

function Menu:show()
	self.open = true
	self.sel = 1
end

function Menu:hide()
	self.open = false
end

-- ---- drawing ----

-- d.fill(x, y, w, h, color) and d.text(x, y, s, color) are the
-- caller's. c is the palette: bg, fg, dim, sel and edge.
function Menu:draw(d, c)
	if not self.open then
		return
	end

	local x, y, w, h = self:rect()

	d.fill(x, y, w, h, c.bg)
	d.fill(x + w - 1, y, 1, h, c.edge or c.dim)
	d.fill(x, y + h - 1, w, 1, c.edge or c.dim)

	local ty = y + self.pad

	if self.title then
		d.text(x + self.pad, ty, self.title, c.dim)
		ty = ty + self.rowh
	end
	for i, it in ipairs(self.items) do
		local fg = c.fg

		if i == self.sel then
			d.fill(x + 1, ty - 1, w - 2, self.rowh, c.sel)
		end
		d.text(x + self.pad, ty, it.label, fg)
		if it.key then
			d.text(x + w - self.pad - #it.key * self.fw, ty,
			    it.key, c.dim)
		end
		ty = ty + self.rowh
	end
end

-- the corner square: three bars, so it needs no glyph the font may not
-- have and reads the same at any size
function M.drawbutton(d, x, y, fg, bg)
	local s = M.BUTTON

	d.fill(x, y, s, s, bg)
	for i = 0, 2 do
		d.fill(x + 2, y + 2 + i * 3, s - 4, 1, fg)
	end
end

function M.inbutton(x, y, bx, by)
	bx, by = bx or 0, by or 0
	return x >= bx and x < bx + M.BUTTON and y >= by
	    and y < by + M.BUTTON
end

-- ---- answering ----

-- a point, while the menu is up: "pick" with an id, or "dismiss" for
-- anywhere outside it, which is what a tap off a menu means everywhere
function Menu:click(px, py)
	if not self.open then
		return nil
	end

	local x, y, w, h = self:rect()

	if px < x or px >= x + w or py < y or py >= y + h then
		return "dismiss"
	end

	local row = (py - y - self.pad) // self.rowh

	if self.title then
		row = row - 1
	end

	local it = self.items[row + 1]

	if not it then
		return nil
	end
	self.sel = row + 1
	return "pick", it.id or it.label
end

function Menu:key(k)
	if not self.open then
		return nil
	end
	if k == "\27" then
		return "dismiss"
	end
	if k == "\27[A" then
		self.sel = self.sel > 1 and self.sel - 1 or #self.items
		return "moved"
	end
	if k == "\27[B" then
		self.sel = self.sel < #self.items and self.sel + 1 or 1
		return "moved"
	end
	if k == "\r" or k == "\n" then
		local it = self.items[self.sel]

		return it and "pick" or "dismiss", it and (it.id or it.label)
	end

	-- the key the row names, which is the point of showing it: the
	-- menu is a way to learn the shortcut, not a replacement for it
	for _, it in ipairs(self.items) do
		if it.key == k then
			return "pick", it.id or it.label
		end
	end
	return "dismiss"
end

return M
