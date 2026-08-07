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
-- three answers, and they are deliberately different:
--	x, y, b   an event
--	false     something that is not a record; say so and read again
--	nil, why  the file is gone, and so are we
--
-- A record that will not parse used to end the program, which is the
-- same silence as a crash from the outside: the drawing stops and
-- nothing says why. It is not even a good reason to stop -- one bad
-- read out of a device says nothing about the next.
local function event()
	local rec, rerr = mouse:read(49)

	if not rec then
		return nil, "read: " .. tostring(rerr)
	end

	local x, y, b = rec:match("^m%s*(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)")

	if not x then
		return false, ("%d bytes, %q"):format(#rec, rec:sub(1, 24))
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
local STROKEMAX = 1500
local strokes = {}

local function remember(x0, y0, x1, y1, c)
	if #strokes >= STROKEMAX then
		table.remove(strokes, 1)
	end
	strokes[#strokes + 1] = { x0, y0, x1, y1, c }
end

local function replay()
	clear()
	for _, s in ipairs(strokes) do
		line(s[1], s[2], s[3], s[4], s[5])
	end
end

clear()

-- the corner that clears, which is a button without a widget: there is
-- no toolbar here and a program with one screen and one pointer can
-- afford to name a place instead.
local CORNER = 28

local lastx, lasty, drawing = nil, nil, false

-- Two files are read at once -- the pointer and the window -- so each
-- gets a thread and the main body drives them. os.exit stays out of
-- both: it unwinds through prog's runner, and a thread that raises it
-- is a fault printed to the console instead of a program leaving.
--
-- A run of unreadable records is a broken pointer rather than a stray
-- one, and drawing nothing while reading it forever is no better than
-- leaving. So: report the first, count them, and give up with a reason.
local BADMAX = 8
local bad = 0

local thread = require("los.thread")
local N = prog.ns()
local wctl = N and N:open("/dev/wctl", "r")

if wctl then
	thread.spawn(function()
		while true do
			local s = wctl:read(16)

			if not s then
				break
			end
			if s:match("redraw") then
				replay()
			end
		end
		wctl:close()
	end)
end

thread.spawn(function()
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
end)

thread.run()

mouse:close()
fb.fill(draw.rect(0, 0, W, H), 0x000000)
