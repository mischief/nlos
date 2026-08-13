-- scribble: draw on the panel with your finger.
--
--	> scribble
--
-- A pointer program, which is a thing this machine could not have had
-- before a pointer. It reads the mouse the way any program reads a
-- file -- open, read 49 bytes, get one event -- and holds no capability
-- for it at all. What it does need a capability for is the screen,
-- which it takes whole and gives back on the way out, the Windows 3.1
-- bargain bin/smiley.lua explains.
--
--	finger        draw
--	trackball     change colour
--	ball press    clear the screen
--	q on the keyboard, or ^C   leave
--
-- The trackball is a wheel here rather than a second pointer, so it
-- picks from a list instead of moving anything -- which is what a wheel
-- is for, and why the palette is a list.

local prog = require("prog")
local memdraw = require("memdraw")


local fb = prog.screen()

if not fb then
	io.stderr:write("scribble: no framebuffer on this machine\n")
	os.exit(1)
end

local mousemod = require("mouse")
local ptr = prog.ctx and prog.ctx.ptr
local mouse = prog.mouse()

if not mouse then
	io.stderr:write("scribble: no pointer on this machine\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h

-- two answers, and they are deliberately different:
--	x, y, b   an event
--	nil, why  the pointer is gone, and so are we
--
-- Under a window the same port carries its state, and a redraw is
-- answered here: this is what the program waits in.
local event

local function pointerevent()
	local x, y, b, why = mouse.read()

	if not x then
		return nil, tostring(why)
	end
	return x, y, b
end

-- wheel bits, as plan 9 numbers them. 1 is a click, whether it came
-- from the panel or from the ball: the file does not say which, and a
-- program that drew differently for each would be wrong on the next
-- board.
local BUT1, WHEELUP, WHEELDOWN = 1, 8, 16

local palette = {
	0xff4136, 0xff851b, 0xffdc00, 0x2ecc40,
	0x0074d9, 0xb10dc9, 0xffffff, 0x111111,
}
local pen = 1

-- the swatch, drawn in the corner so the current colour is visible
-- without a menu. Small, because the screen belongs to the drawing.
local SW = 14

local function swatch()
	fb.fill(memdraw.rect(W - SW - 2, 2, SW, SW), palette[pen])
	fb.fill(memdraw.rect(W - SW - 3, 1, 1, SW + 2), 0x808080)
	fb.fill(memdraw.rect(W - SW - 2, 1, SW, 1), 0x808080)
end

local function clear()
	fb.fill(memdraw.rect(0, 0, W, H), 0x000000)
	swatch()
end

-- a dab, clipped: the pointer can sit on the edge and a fill that runs
-- off it is an error rather than a clipped rectangle.
local R = 2

local function dab(x, y, c)
	local x0 = math.max(0, x - R)
	local y0 = math.max(0, y - R)
	local x1 = math.min(W - 1, x + R)
	local y1 = math.min(H - 1, y + R)

	if x1 >= x0 and y1 >= y0 then
		fb.fill(memdraw.rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1), c)
	end
end

-- between two events, because a finger moves further than one dab
-- between reads: without this a quick stroke is a dotted line.
local function line(x0, y0, x1, y1, c)
	local dx, dy = x1 - x0, y1 - y0
	local steps = math.max(math.abs(dx), math.abs(dy))

	if steps == 0 then
		dab(x0, y0, c)
		return
	end
	for i = 0, steps do
		dab(math.floor(x0 + dx * i / steps + 0.5),
		    math.floor(y0 + dy * i / steps + 0.5), c)
	end
end

-- ---- what the drawing is, apart from the pixels ----
--
-- A window system here keeps no pixels for an app: another app draws
-- over them, and coming back to the front is being told to paint again.
-- So the drawing has to exist as something other than what is on the
-- glass, and for this program that is the strokes it has been given.
--
-- Bounded, because a picture that never forgets is memory that only
-- grows on a machine that has not got it. The oldest segment goes,
-- which loses the start of a long session rather than the end of it.
--
-- Five numbers in one flat array rather than a table per segment: a
-- table costs far more than the five numbers in it, and this is the one
-- thing here that grows.
local STROKEMAX = 1000		-- segments
local strokes = {}

local function remember(x0, y0, x1, y1, c)
	if #strokes >= STROKEMAX * 5 then
		-- drop the oldest, which is five numbers off the front
		table.move(strokes, 6, #strokes, 1)
		for i = #strokes, #strokes - 4, -1 do
			strokes[i] = nil
		end
	end

	local n = #strokes

	strokes[n + 1] = x0
	strokes[n + 2] = y0
	strokes[n + 3] = x1
	strokes[n + 4] = y1
	strokes[n + 5] = c
end

local function replay()
	clear()
	for i = 1, #strokes, 5 do
		line(strokes[i], strokes[i + 1], strokes[i + 2],
		    strokes[i + 3], strokes[i + 4])
	end
end

clear()

-- the corner that clears, which is a button without a widget: there is
-- no toolbar here and a program with one screen and one pointer can
-- afford to name a place instead.
local CORNER = 28

local lastx, lasty, drawing = nil, nil, false

-- The pointer and the window arrive on one port, so this is one loop
-- and no threads.
--
-- A run of unreadable records is a broken pointer rather than a stray
-- one, and reading it forever while drawing nothing is no better than
-- leaving. Report the first, count them, give up with a reason.
local BADMAX = 8
local bad = 0

local thread = require("los.thread")
local ev = prog.events()
-- answered onto the event port where there is one; off a window system
-- the reader makes its own and this is the only thing to wait on.
local point = ev and mousemod.onport(ptr, ev) or nil

-- off a window system there is no shared port, so the pull reader is
-- still the way to read a pointer.
if not point then
	event = pointerevent
else
	point.arm()
	event = function()
		while true do
			local m, why = thread.await(ev)

			if why then
				return nil, "window gone"
			end
			if type(m) ~= "table" then
				-- keys, which this program was lent none of
			elseif m.t == "win" then
				if m.state == "redraw" then
					replay()
				end
			elseif m.t == "ptr" then
				if not point.took(m) then
					return nil, "pointer hung up"
				end
				point.arm()
				return m.x, m.y, m.b
			end
		end
	end
end

while true do
	local x, y, b = event()

	if x == nil then
		io.stderr:write("scribble: " .. tostring(y) .. "\n")
		break
	end
	if x == false then
		bad = bad + 1
		if bad == 1 then
			io.stderr:write("scribble: not a mouse record: " ..
			    tostring(y) .. "\n")
		end
		if bad >= BADMAX then
			io.stderr:write(("scribble: %d bad records; giving up\n")
			    :format(bad))
			break
		end
		goto continue
	end
	bad = 0

	if b & WHEELUP ~= 0 then
		pen = pen % #palette + 1
		swatch()
	elseif b & WHEELDOWN ~= 0 then
		pen = (pen - 2) % #palette + 1
		swatch()
	elseif b & BUT1 ~= 0 then
		if x < CORNER and y < CORNER then
			-- the corner empties the picture, which is the
			-- strokes and not only the pixels: what is redrawn
			-- after a switch is this list.
			strokes = {}
			clear()
			drawing = false
		elseif drawing and lastx then
			-- joined to where it was: a finger moves further
			-- than one dab between reads, so without the line a
			-- quick stroke comes out dotted.
			line(lastx, lasty, x, y, palette[pen])
			remember(lastx, lasty, x, y, palette[pen])
			lastx, lasty = x, y
		else
			dab(x, y, palette[pen])
			remember(x, y, x, y, palette[pen])
			lastx, lasty, drawing = x, y, true
		end
	else
		drawing = false
		lastx, lasty = nil, nil
	end

	::continue::
end

fb.fill(memdraw.rect(0, 0, W, H), 0x000000)
