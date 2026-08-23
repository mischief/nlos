#!/usr/bin/env lua5.4
-- lib/menu.lua on the host. It holds geometry and what a point or a
-- key means, and draws through primitives the caller passes, so all of
-- that runs here with no framebuffer under it.
-- TAP direct: lib/tap.lua needs los.sys.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local menu = require("menu")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
end

local function is(got, want, name)
	ok(got == want, ("%s (got %s, want %s)"):format(name, tostring(got),
	    tostring(want)))
end

local ITEMS = {
	{ id = "back", label = "back", key = "b" },
	{ id = "reload", label = "reload", key = "r" },
	{ id = "home", label = "start page", key = "h" },
	{ id = "quit", label = "quit", key = "q" },
}

local function new(o)
	o = o or {}
	o.items = o.items or ITEMS
	o.w = o.w or 292
	o.h = o.h or 240
	return menu.new(o)
end

-- ---- what it is until it is asked for ----

local m = new()

ok(not m:isopen(), "a menu starts closed")
is(m:click(10, 10), nil, "and a point means nothing to it")
is(m:key("b"), nil, "nor does a key: the app still owns them")

m:show()
ok(m:isopen(), "show opens it")

-- ---- where it sits ----

local x, y, w, h = m:rect()

is(x, 0, "it hangs off the left edge")
ok(w <= 292, "and is no wider than the screen")
ok(h == #ITEMS * 13 + 6, "one row an item, plus the padding")

m = new({ top = 16 })
local _, ty = m:rect()

is(ty, 16, "it opens under the button that opened it")

-- a menu taller than what is left below the button is pulled up
-- rather than drawn off the bottom
m = new({ top = 220 })
m:show()
local _, py, _, ph = m:rect()

ok(py + ph <= 240, "a menu near the bottom stays on the screen")

-- ---- what a point means ----

m = new({ top = 16 })
m:show()
x, y = m:rect()

local act, id = m:click(x + 5, y + 3 + 13 * 0)

is(act, "pick", "a point on a row picks")
is(id, "back", "the row it landed on")

act, id = m:click(x + 5, y + 3 + 13 * 2)
is(id, "home", "counting down the list")

act = m:click(x + m.bw + 4, y + 4)
is(act, "dismiss", "and a point beside it dismisses")

act = m:click(x + 5, y - 4)
is(act, "dismiss", "as does one above it")

-- a title takes the first row, so every item moves down one
m = new({ top = 16, title = "gemini" })
m:show()
x, y = m:rect()
act, id = m:click(x + 5, y + 3 + 13)
is(id, "back", "a title pushes the first item down a row")

-- ---- what a key means ----

m = new()
m:show()
act, id = m:key("r")
is(act, "pick", "the key a row names picks it")
is(id, "reload", "which is the whole point of showing the key")

m:show()
is(m:key("\27"), "dismiss", "escape closes")

m:show()
act, id = m:key("\27[B")
is(act, "moved", "down moves the selection")
is(m.sel, 2, "to the next row")
act, id = m:key("\r")
is(id, "reload", "and enter takes it")

m:show()
m:key("\27[A")
is(m.sel, #ITEMS, "up from the first wraps to the last")
m:key("\27[B")
is(m.sel, 1, "and down from the last wraps to the first")

m:show()
is(m:key("z"), "dismiss",
    "a key the menu does not know closes it rather than eating it")

-- ---- the button ----

ok(menu.inbutton(2, 2), "a point in the corner square is on the button")
ok(not menu.inbutton(menu.BUTTON + 1, 2), "and one to its right is not")
ok(menu.inbutton(30, 3, 28, 0), "the square can sit anywhere")

-- ---- drawing, through primitives that only count ----

local fills, texts = 0, 0
local d = {
	fill = function() fills = fills + 1 end,
	text = function() texts = texts + 1 end,
}
local pal = { bg = 1, fg = 2, dim = 3, sel = 4, edge = 5 }

m = new({ title = "gemini" })
m:draw(d, pal)
is(fills + texts, 0, "a closed menu draws nothing")

m:show()
m:draw(d, pal)
is(texts, 1 + #ITEMS * 2, "the title, and a label and a key an item")
ok(fills > 0, "and the box under them")

menu.drawbutton(d, 0, 0, 1, 2)
ok(fills > 0, "the button is bars, not a glyph the font may not have")

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
