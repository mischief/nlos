-- drawbench: what a frame costs.
--
--	> drawbench [ROUNDS]
--
-- Fills carry no reply, so a loop without sync() times the enqueue and
-- nothing else. Every case here syncs.

local prog = require("prog")
local memdraw = require("memdraw")
local sys = require("los.sys")
local unistd = require("posix.unistd")

local fb = prog.screen()

if not fb then
	io.stderr:write("drawbench: no framebuffer on this machine\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h
local rounds = tonumber(arg[1] or "") or 5

-- to the log as well as to stdout: the screen is what this is
-- measuring, so a result drawn over is a result lost.
local function out(s)
	unistd.write(1, s)
	sys.log("drawbench: " .. (s:gsub("\n$", "")))
end

-- the best of several runs, in ms. The worst is kept too: a garbage
-- collection inside one round is what separates them.
local function bench(name, calls, fn)
	local best, worst

	for _ = 1, rounds do
		local t0 = sys.uptime_ms()

		fn()
		fb.sync()

		local dt = sys.uptime_ms() - t0

		if not best or dt < best then best = dt end
		if not worst or dt > worst then worst = dt end
	end

	out(string.format("%-28s %5d calls %6d ms %6d ms %8.1f fps\n",
	    name, calls, best, worst, best > 0 and 1000 / best or 0))
end

out(string.format("screen %dx%d, best of %d\n\n", W, H, rounds))
out(string.format("%-28s %11s %9s %9s %11s\n",
    "case", "calls", "best", "worst", "best fps"))

-- one message, the whole screen. The floor for anything full frame.
bench("full screen, one fill", 1, function()
	fb.fill(memdraw.rect(0, 0, W, H), 0x102030)
end)

-- the same pixels, one message a scanline: what smiley does drawing a
-- circle, and the reason its face is slow.
bench("full screen, per scanline", H, function()
	for y = 0, H - 1 do
		fb.fill(memdraw.rect(0, y, W, 1), 0x203040)
	end
end)

-- a cell grid, which is what a board game repaints.
local CELL = 16
local cols, rows = W // CELL, H // CELL

bench("16x16 cells, whole board", cols * rows, function()
	for cy = 0, rows - 1 do
		for cx = 0, cols - 1 do
			fb.fill(memdraw.rect(cx * CELL, cy * CELL,
			    CELL - 1, CELL - 1), 0x304050)
		end
	end
end)

-- what a snake actually costs: two cells a step.
bench("two cells, a snake step", 2, function()
	fb.fill(memdraw.rect(32, 32, CELL, CELL), 0x40e080)
	fb.fill(memdraw.rect(64, 64, CELL, CELL), 0x000000)
end)

-- a falling tetromino: four erased, four drawn.
bench("eight cells, a tetromino", 8, function()
	for i = 0, 3 do
		fb.fill(memdraw.rect(100 + i * CELL, 40, CELL, CELL),
		    0x000000)
		fb.fill(memdraw.rect(100 + i * CELL, 56, CELL, CELL),
		    0xe08040)
	end
end)

-- a sprite held by the server, blitted rather than drawn. This is the
-- number that decides whether an action game is possible.
local SPR = 32
local sprite = fb.alloc(SPR, SPR, nil, 0xff0000)

if sprite then
	bench("one 32x32 sprite blit", 1, function()
		fb.draw(nil, sprite, memdraw.rect(0, 0, SPR, SPR),
		    { x = 120, y = 100 })
	end)

	bench("sixteen sprite blits", 16, function()
		for i = 0, 15 do
			fb.draw(nil, sprite,
			    memdraw.rect(0, 0, SPR, SPR),
			    { x = (i % 8) * 36, y = 20 + (i // 8) * 36 })
		end
	end)

	-- a plausible frame: background, a few obstacles, one sprite.
	bench("a flappy frame", 6, function()
		fb.fill(memdraw.rect(0, 0, W, H), 0x203050)
		fb.fill(memdraw.rect(80, 0, 24, 90), 0x30a030)
		fb.fill(memdraw.rect(80, 150, 24, H - 150), 0x30a030)
		fb.fill(memdraw.rect(220, 0, 24, 60), 0x30a030)
		fb.fill(memdraw.rect(220, 120, 24, H - 120), 0x30a030)
		fb.draw(nil, sprite, memdraw.rect(0, 0, SPR, SPR),
		    { x = 40, y = 110 })
	end)

	fb.free(sprite)

	-- the same blits from an image in the screen's own format, which
	-- is the difference between a row copy and a pixel loop.
	local same = mode.format and fb.alloc(SPR, SPR, mode.format,
	    0x00ff00)

	if same then
		bench("one blit, screen format", 1, function()
			fb.draw(nil, same, memdraw.rect(0, 0, SPR, SPR),
			    { x = 160, y = 100 })
		end)

		bench("sixteen blits, screen format", 16, function()
			for i = 0, 15 do
				fb.draw(nil, same,
				    memdraw.rect(0, 0, SPR, SPR),
				    { x = (i % 8) * 36,
				      y = 60 + (i // 8) * 36 })
			end
		end)
		fb.free(same)
	else
		out(string.format("no image in format %s\n",
		    tostring(mode.format)))
	end
else
	out("no server-side image: alloc refused\n")
end

fb.fill(memdraw.rect(0, 0, W, H), 0x000000, true)
