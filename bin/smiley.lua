-- smiley: a graphical program you run from the dos prompt.
--
--   > smiley
--   > smiley ff0000
--
-- it takes the whole screen, draws, waits for a line on stdin, clears up
-- and exits back to the prompt. that is the windows 3.1 bargain and it
-- is deliberate: the shell is DOS, a graphical program is `win`, and
-- when it ends you are looking at the prompt again.
--
-- restoring on the way out is the part that is easy to skip and should
-- not be. a program that draws and exits leaves its picture on the
-- screen forever, because nothing else here is going to repaint it --
-- there is no window system to expose the desktop underneath. so
-- whoever took the screen puts it back.
--
-- it reaches the framebuffer through prog.screen(), which returns a
-- capability object or nil. nil is not an error worth a traceback: a
-- machine with no display is an ordinary machine, and this says so and
-- exits 1.
local prog = require("prog")
local memdraw = require("memdraw")
local unistd = require("posix.unistd")

local fb = prog.screen()

if not fb then
	io.stderr:write("smiley: no framebuffer on this machine\n")
	os.exit(1)
end

local color = tonumber(arg[1] or "", 16) or 0xffcc00
local mode = fb.mode()
local W, H = mode.w, mode.h

-- ---- drawn as spans, onto the screen ----
--
-- Every shape here is already one horizontal span per row, so the
-- screen can be the target directly and no picture is built anywhere:
-- nothing is composed off-screen, nothing is kept, and drawing the face
-- again costs what drawing it the first time cost.
--
-- The alternative -- compose the whole face and load it once -- arrives
-- in one piece rather than assembling in front of you, and is why this
-- program used to do that. It costs about 900KB while composing and
-- 230KB to keep, on a board where four apps at once is already most of
-- the heap. A face that draws itself in a moment is worth more than a
-- face that appears at once.
--
-- No antialiasing: blending needs an alpha channel, which lib/memdraw.lua
-- deliberately does not have (see its header).
local ox, oy		-- where the face sits on the screen

local function span(x, y, w, c)
	if w > 0 then
		fb.fill(memdraw.rect(ox + x, oy + y, w, 1), c)
	end
end

local function disc(cx, cy, rad, c)
	for dy = -rad, rad do
		local dx = math.floor(math.sqrt(rad * rad - dy * dy) + 0.5)

		span(cx - dx, cy + dy, dx * 2 + 1, c)
	end
end

-- an annulus clipped to a row range, so the smile is a crescent rather
-- than half a disc.
local function arc(cx, cy, rad, thick, c, from, to)
	for dy = -rad, rad do
		local y = cy + dy

		if y >= from and y <= to then
			local outer = math.floor(
			    math.sqrt(rad * rad - dy * dy) + 0.5)
			local inner = 0
			local ir = rad - thick

			if math.abs(dy) < ir then
				inner = math.floor(
				    math.sqrt(ir * ir - dy * dy) + 0.5)
			end
			span(cx - outer, y, outer - inner, c)
			span(cx + inner, y, outer - inner, c)
		end
	end
end

local BG = 0x101018
local size = math.min(320, W, H)
local c = size // 2
local unit = size / 320		-- the drawing is designed at 320

ox, oy = (W - size) // 2, (H - size) // 2

local function paint()
	fb.fill(memdraw.rect(0, 0, W, H), BG)
	disc(c, c, size // 2 - 4, color)
	disc(c - math.floor(55 * unit), c - math.floor(45 * unit),
	    math.floor(22 * unit), BG)
	disc(c + math.floor(55 * unit), c - math.floor(45 * unit),
	    math.floor(22 * unit), BG)
	arc(c, c - math.floor(10 * unit), math.floor(105 * unit),
	    math.floor(18 * unit), BG, c + math.floor(20 * unit), size)
	fb.sync()
end

paint()

-- Under a launcher with a keyboard this waits to be dismissed. Under a
-- window system there is no keyboard to dismiss it with -- an app is
-- given a screen and a pointer -- so it holds the screen until it is
-- stopped from the tray.
--
-- The distinction has to be made here rather than by reading and
-- seeing eof: fd 0 always exists, and a program handed no input reads
-- eof at once, which is indistinguishable from a person pressing enter
-- the instant it drew.
if not prog.stdin() then
	local N = prog.ns()
	local wctl = N and N:open("/dev/wctl", "r")

	if not wctl then
		-- parked, not spinning: nothing will ever be sent here,
		-- and the point is to cost nothing until killed.
		require("los.thread").recv(require("los.sys").SELF)
		return
	end

	-- an app keeps no pixels on the glass: another app draws over
	-- them while this one is behind, so coming back to the front is
	-- being told to paint again.
	while true do
		local s = wctl:read(16)

		if not s then
			break
		end
		if s:match("redraw") then
			paint()
		end
	end
	wctl:close()
	return
end

io.write("smiley: press enter to return to dos\n")

-- unistd.read on fd 0 rather than io.read, which the program
-- environment does not provide (see lib/prog.lua's install: io is a
-- three-function shim over the ABI streams, not lua's io). the read
-- goes to whatever the launcher gave us as stdin -- the console when
-- run interactively, and a pipe or a file when not, which is why this
-- does not reach for the console itself.
unistd.read(0, 256)

-- give the screen back the way we found it. black rather than the
-- background above, because that is what a text console with nothing on
-- it looks like.
fb.fill(memdraw.rect(0, 0, W, H), 0x000000, true)
