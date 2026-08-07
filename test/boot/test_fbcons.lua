-- the fb console as a terminal: the escape sequences reach the glass.
--
-- lib/fbcons.lua is the terminal emulator, so what it emulates is a
-- claim about pixels, not about a return value. This drives it against
-- the real fb task and reads the cells back, the way test/boot/test_fb.lua
-- proves a fill really filled. A color that was parsed but never drawn,
-- or drawn in the wrong cell, fails here and nowhere else.
--
-- the pen is persistent, as on any terminal, so each case starts with
-- ESC[0m (default pen) ESC[2J (clear) ESC[H (home).
local sys = require("los.sys")
local caps = require("caps")
local draw = require("draw")
local fbcons = require("fbcons")
local font = require("los.font")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(16)

tap.ok(caps_of.fb ~= nil, "boot payload holds the screen")
if not caps_of.fb then
	return
end

-- the fb task speaks one protocol; fbcons drives it, and this wraps the
-- same right for readback. Two holders of one send right is fine.
local fb = caps.fb(caps_of.fb)
local cw, ch = font.size()
local con = fbcons.new({
	fb = caps_of.fb, font = font,
	keyport = sys.newport("test_fbcons.key"),	-- fbcons only passes it through
})

tap.ok(con.cols > 0 and con.rows > 0,
    ("grid is %sx%s cells"):format(con.cols, con.rows))

local HOME = "\27[0m\27[2J\27[H"

-- the set of distinct colors in one character cell, read from the panel.
local function cell(cx, cy)
	local pix = fb.unload(draw.rect(cx * cw, cy * ch, cw, ch))
	local img = draw.fromBytes(cw, ch, pix)
	local seen = {}

	for y = 0, ch - 1 do
		for x = 0, cw - 1 do
			seen[draw.at(img, x, y)] = true
		end
	end
	return seen
end

local function has(cx, cy, color)
	return cell(cx, cy)[color] == true
end

-- every pixel of a cell is one color (a space glyph: all paper).
local function solid(cx, cy, color)
	local seen = cell(cx, cy)

	for c in pairs(seen) do
		if c ~= color then
			return false
		end
	end
	return seen[color] == true
end

-- ---- a plain glyph in the default pen ----
con.write(HOME .. "A")
tap.ok(has(0, 0, 0xc0c0c0), "default ink is light grey")
tap.ok(has(0, 0, 0x000000), "default paper is black")

-- ---- SGR foreground ----
con.write(HOME .. "\27[31mB")
tap.ok(has(0, 0, 0xcc0000), "SGR 31 draws red ink")
tap.ok(has(0, 0, 0x000000), "paper stays black under colored ink")

-- ---- SGR background: a space fills the cell with the paper color ----
con.write(HOME .. "\27[44m ")
tap.ok(solid(0, 0, 0x0000cc), "SGR 44 fills the cell blue")

-- ---- reverse video swaps the pen: a space becomes solid foreground ----
con.write(HOME .. "\27[7m ")
tap.ok(solid(0, 0, 0xc0c0c0), "SGR 7 paints the space in the foreground")

-- ---- SGR 0 puts the pen back after a color was set ----
con.write(HOME .. "\27[44m\27[0m ")
tap.ok(solid(0, 0, 0x000000), "SGR 0 restores the default paper")

-- ---- bright foreground via bold ----
con.write(HOME .. "\27[1;32mC")
tap.ok(has(0, 0, 0x55ff55), "SGR 1;32 draws bright green")

-- ---- cursor addressing: X at home, Y jumped to row 3 col 5 ----
con.write(HOME .. "X\27[3;5HY")
tap.ok(has(4, 2, 0xc0c0c0), "CSI H places the glyph at row 3 col 5")

-- ---- erase display down from a cursor with content above and below ----
-- cursor to row 2 col 1 (between the X on row 1 and the Y on row 3).
con.write("\27[2;1H\27[0J")
tap.ok(has(0, 0, 0xc0c0c0), "CSI 0J leaves the rows above the cursor")
tap.ok(solid(4, 2, 0x000000), "CSI 0J clears from the cursor down")

-- ---- a scroll carries the line that triggered it ----
-- park the cursor on the last row, put a red marker there and a newline,
-- which scrolls. The marker must land one row up, not vanish -- a fast
-- scroll that moves the glass but forgets the line still being written.
con.write("\27[0m\27[2J\27[H" .. string.rep("\n", con.rows - 1))
con.write("\27[31mX\27[0m\n")
tap.ok(has(0, con.rows - 2, 0xcc0000),
    "the line that triggered the scroll is carried up, not lost")

-- ---- a line that fills the width costs one row, not two ----
--
-- A character written into the last column leaves the wrap owed rather
-- than taken. Without that, the newline after a full-width line lands on
-- a row the write had already moved to, and every such line is followed
-- by a blank one -- which is what a wrapped irc message looks like when
-- it is wrong.
con.write(HOME .. string.rep("A", con.cols) .. "\r\nB")
tap.ok(has(0, 1, 0xc0c0c0), "a full-width line is followed by the next row")
-- and two full-width lines in a row take two rows, not four: the owed
-- wrap must be cancelled by the carriage return that follows it rather
-- than saved up.
-- red, so the row it lands on is told from the rows of C above it.
con.write(HOME .. string.rep("C", con.cols) .. "\r\n" ..
    string.rep("C", con.cols) .. "\r\n\27[31mE\27[0m")
tap.ok(has(0, 2, 0xcc0000), "two full-width lines take two rows")
