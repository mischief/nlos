#!/usr/bin/env lua
-- lib/frame.lua on the host: geometry, selection and editing are pure
-- computation, so the part of a text window most likely to hold an
-- off-by-one is the part that needs no machine to check.
--
-- TAP direct: lib/tap.lua wants los.sys.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local frame = require("frame")

local n, fails = 0, 0

local function ok(cond, what)
	n = n + 1
	if cond then
		print(string.format("ok %d - %s", n, what))
	else
		fails = fails + 1
		print(string.format("not ok %d - %s", n, what))
	end
end

local function eq(got, want, what)
	ok(got == want, string.format("%s (got %s, want %s)", what,
	    tostring(got), tostring(want)))
end

-- ---- wrapping ----

local f = frame.new(10, 4)

f:settext("hello\nworld\n")
eq(f:nlines(), 3, "two lines and the tail after a trailing newline")
eq(f:line(1), "hello", "the first line is its own text")
eq(f:line(2), "world", "and so is the second")

f:settext("abcdefghijklm")
eq(f:nlines(), 2, "a line longer than the frame wraps")
eq(f:line(1), "abcdefghij", "the first cell row is exactly the width")
eq(f:line(2), "klm", "and the rest follows")

f:settext("")
eq(f:nlines(), 1, "empty text still has a line to put a cursor on")

-- ---- points and offsets ----

f:settext("hello\nworld")
eq(f:charofpt(0, 0), 0, "the top left is offset zero")
eq(f:charofpt(3, 0), 3, "a column is an offset along the line")
eq(f:charofpt(99, 0), 5, "past the end of a line clamps to its length")
-- "hello" is 5 runes plus the newline, so the second line starts at 6
eq(f:charofpt(0, 1), 6, "the newline is an offset and not a cell")

local c, r = f:ptofchar(6)

eq(c, 0, "and back: the second line starts at column zero")
eq(r, 1, "on the second row")
ok(f:ptofchar(99) == nil, "an offset past the text is nowhere on screen")

-- ---- utf8 ----
--
-- The whole reason offsets are codepoints. A byte-indexed frame puts
-- the cursor inside a sequence and an edit there cuts it in half.

f:settext("héllo")
eq(f.nchars, 5, "five codepoints, not six bytes")
eq(f:charofpt(2, 0), 2, "a point past a two-byte rune counts one cell")

local col = f:ptofchar(3)

eq(col, 3, "and an offset after it maps back to its own column")

f:settext("héllo")
f:delete(1, 2)
eq(f.text, "hllo", "deleting a multibyte rune takes both its bytes")

f:settext("hllo")
f:insert(1, "é")
eq(f.text, "héllo", "and inserting one puts them back")

f:settext("aé")
eq(f:insert(2, "z"), 3, "an insert returns the offset after it")
eq(f.text, "aéz", "appending after a multibyte rune lands at the end")

-- ---- selection ----

f = frame.new(10, 4)
f:settext("hello\nworld")
f:select(2, 4)
eq(f.p0, 2, "a selection keeps its start")
eq(f.p1, 4, "and its end")

f:select(4, 2)
eq(f.p0, 2, "a backwards selection is put in order")

local a, b = f:selspan(1)

eq(a, 2, "the visible span of the first line starts where it does")
eq(b, 4, "and ends where it does")
ok(f:selspan(2) == nil, "a line outside the selection has no span")

f:cursor(3)
ok(f:selspan(1) == nil, "a cursor selects nothing")
eq(f.p0, f.p1, "and is an empty selection")

-- ---- scrolling ----

f = frame.new(10, 2)
f:settext("1\n2\n3\n4\n5")
eq(f:nlines(), 5, "five lines")
ok(f:scroll(1), "scrolling down moves")
eq(f.top, 1, "by one line")
eq(f:line(1), "2", "and the top line is the next one")

f:scroll(99)
eq(f.top, 3, "scrolling past the end stops with the last line in view")

f:scroll(-99)
eq(f.top, 0, "and back up stops at the top")

ok(not f:scroll(0), "a scroll of nothing reports no movement")

f:scroll(0)
ok(f:show(0) == false, "an offset already on screen scrolls nothing")
ok(f:show(8) == true, "one below it scrolls")
ok(f:ptofchar(8) ~= nil, "and puts it on screen")

print("1.." .. n)
os.exit(fails == 0 and 0 or 1)
