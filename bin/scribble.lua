-- scribble: draw on the panel with your finger.
--
--	> scribble
--
-- A pointer program, which is a thing this machine could not have had
-- before /dev/mouse. It reads the mouse the way any program reads a
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
local draw = require("draw")


local fb = prog.screen()

if not fb then
	io.stderr:write("scribble: no framebuffer on this machine\n")
	os.exit(1)
end

local N = prog.ns()
local mouse, err = N and N:open("/dev/mouse", "r")

if not mouse then
	io.stderr:write("scribble: no /dev/mouse: " .. tostring(err) .. "\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h

-- plan 9's mouse record, fixed width: 'm' then x, y, buttons and a
-- millisecond clock. Fixed width is why a read of 49 bytes is exactly
-- one event and this needs no framing of its own.
local function event()
	local rec, rerr = mouse:read(49)

	if not rec then
		io.stderr:write("scribble: read: " .. tostring(rerr) .. "\n")
		return nil
	end

	local x, y, b = rec:match("^m%s*(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)")

	if not x then
		return nil
	end
	return tonumber(x), tonumber(y), tonumber(b)
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
	fb.fill(draw.rect(W - SW - 2, 2, SW, SW), palette[pen])
	fb.fill(draw.rect(W - SW - 3, 1, 1, SW + 2), 0x808080)
	fb.fill(draw.rect(W - SW - 2, 1, SW, 1), 0x808080)
end

local function clear()
	fb.fill(draw.rect(0, 0, W, H), 0x000000)
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
		fb.fill(draw.rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1), c)
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

clear()

-- the corner that clears, which is a button without a widget: there is
-- no toolbar here and a program with one screen and one pointer can
-- afford to name a place instead.
local CORNER = 28

local lastx, lasty, drawing = nil, nil, false

-- One loop, in the main body rather than a thread: os.exit unwinds
-- through prog's runner, and a thread that raises it is a fault printed
-- to the console instead of a program leaving.
while true do
	local x, y, b = event()

	if not x then
		break
	end

	if b & WHEELUP ~= 0 then
		pen = pen % #palette + 1
		swatch()
	elseif b & WHEELDOWN ~= 0 then
		pen = (pen - 2) % #palette + 1
		swatch()
	elseif b & BUT1 ~= 0 then
		if x < CORNER and y < CORNER then
			clear()
			drawing = false
		elseif drawing and lastx then
			-- joined to where it was: a finger moves further
			-- than one dab between reads, so without the line a
			-- quick stroke comes out dotted.
			line(lastx, lasty, x, y, palette[pen])
			lastx, lasty = x, y
		else
			dab(x, y, palette[pen])
			lastx, lasty, drawing = x, y, true
		end
	else
		drawing = false
		lastx, lasty = nil, nil
	end
end

mouse:close()
fb.fill(draw.rect(0, 0, W, H), 0x000000)
