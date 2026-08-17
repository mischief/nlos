#!/usr/bin/env lua5.4
-- lib/slide.lua, the 2048 board, on the host. The rand is injected, so
-- every board here is one the test chose rather than one it was dealt.
-- TAP direct: lib/tap.lua needs los.sys.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local slide = require("slide")

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

-- a board with the cells written out, so a case reads as the board it
-- is about. Rows top to bottom, each left to right.
local function board(rows)
	local b = slide.new({ n = #rows, empty = true,
	    rand = function() return 1 end })

	for y, row in ipairs(rows) do
		for x, v in ipairs(row) do
			b:set(x, y, v)
		end
	end
	return b
end

local function row(b, y)
	local out = {}

	for x = 1, b.n do
		out[x] = b:at(x, y)
	end
	return table.concat(out, ",")
end

-- ---- one line at a time ----

local function line(vals)
	local out, gained = slide.slide(vals, #vals)

	return table.concat(out, ","), gained
end

is(line({ 0, 0, 0, 2 }), "2,0,0,0", "a lone tile slides to the front")
is(line({ 2, 2, 0, 0 }), "4,0,0,0", "a pair merges")
is(line({ 2, 0, 0, 2 }), "4,0,0,0", "across a gap too")
is(line({ 2, 2, 2, 0 }), "4,2,0,0", "three make one pair and a single")
is(line({ 4, 2, 2, 0 }), "4,4,0,0", "the pair behind merges")

-- the rule the whole game turns on: a tile that just merged cannot
-- merge again in the same move.
is(line({ 2, 2, 2, 2 }), "4,4,0,0", "four make two pairs, not one eight")
is(line({ 4, 4, 8, 0 }), "8,8,0,0", "and the new 8 does not take the old")
is(line({ 2, 4, 8, 16 }), "2,4,8,16", "unlike tiles do not move")

local _, gained = line({ 2, 2, 4, 4 })

is(gained, 12, "a merge scores what it made")
is(select(2, line({ 2, 4, 8, 16 })), 0, "and no merge scores nothing")

-- ---- a move, in each direction ----

local b = board({
	{ 2, 2, 0, 0 },
	{ 0, 4, 4, 0 },
	{ 0, 0, 0, 0 },
	{ 8, 0, 0, 8 },
})

local moved, got = b:move("left")

ok(moved, "a move that changes the board says so")
is(got, 28, "and answers what it scored")
is(row(b, 1), "4,0,0,0", "the top row merged left")
is(row(b, 2), "8,0,0,0", "and the second")
is(row(b, 4), "16,0,0,0", "and the outer pair met")
is(b.score, 28, "the score is kept on the board")

b = board({
	{ 2, 0, 0, 2 },
	{ 0, 0, 0, 0 },
	{ 0, 0, 0, 0 },
	{ 0, 0, 0, 0 },
})
b:move("right")
is(row(b, 1), "0,0,0,4", "right merges to the far side")

b = board({
	{ 2, 0, 0, 0 },
	{ 2, 0, 0, 0 },
	{ 4, 0, 0, 0 },
	{ 4, 0, 0, 0 },
})
b:move("up")
is(row(b, 1) .. " " .. row(b, 2), "4,0,0,0 8,0,0,0",
    "up merges down the column")

b = board({
	{ 2, 0, 0, 0 },
	{ 2, 0, 0, 0 },
	{ 4, 0, 0, 0 },
	{ 4, 0, 0, 0 },
})
b:move("down")
is(row(b, 3) .. " " .. row(b, 4), "4,0,0,0 8,0,0,0",
    "and down merges the other way")

-- a move that changes nothing is not a move: the turn is not spent and
-- nothing new may be placed.
b = board({
	{ 2, 4, 8, 16 },
	{ 0, 0, 0, 0 },
	{ 0, 0, 0, 0 },
	{ 0, 0, 0, 0 },
})
moved, got = b:move("left")
ok(not moved, "a board that cannot slide that way does not move")
is(got, 0, "and scores nothing")

-- ---- when it is over ----

local full = board({
	{ 2, 4, 2, 4 },
	{ 4, 2, 4, 2 },
	{ 2, 4, 2, 4 },
	{ 4, 2, 4, 2 },
})

ok(not full:canmove(), "a full board with no neighbours is finished")

local nearly = board({
	{ 2, 4, 2, 4 },
	{ 4, 2, 4, 2 },
	{ 2, 4, 2, 4 },
	{ 4, 2, 4, 4 },
})

ok(nearly:canmove(), "one matching pair is enough to go on")

local room = board({
	{ 2, 4, 2, 4 },
	{ 4, 2, 4, 2 },
	{ 2, 4, 2, 4 },
	{ 4, 2, 4, 0 },
})

ok(room:canmove(), "and so is one empty cell")
is(full:best(), 4, "best is the largest tile")

-- ---- what is dealt ----

local placed = slide.new({ n = 4, empty = true,
    rand = function() return 1 end })

is(placed:spawn(), 1, "a tile lands in a free cell")
is(placed.cells[1], 2, "and eight times in ten it is a 2")

local four = slide.new({ n = 4, empty = true,
    rand = function(k) return k == 10 and 9 or 1 end })

four:spawn()
is(four.cells[1], 4, "the other two times it is a 4")

local start = slide.new({ n = 4, rand = function(k) return k end })
local n = 0

for i = 1, 16 do
	if start.cells[i] ~= 0 then
		n = n + 1
	end
end
is(n, 2, "a new board is dealt two tiles")

local none = slide.new({ n = 1, rand = function() return 1 end })

is(none:spawn(), nil, "a board with no room places nothing")

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
