-- top: ps, repainting.
--
--   > top           every two seconds
--   > top -d 5      every five
--   > top -n 3      three frames, then stop
--
-- q or Escape ends it. So does ctrl-c on a cooked terminal, but not
-- here: raw mode is what stops the console line-editing the keystrokes,
-- and it turns the interrupt character off with it (lib/console.lua).
-- A full-screen program has to offer its own way out.
--
-- The table is bin/ps.lua's, formatted by the same lib/ps.lua and cut
-- to the window. Two programs showing the same columns differently
-- would be two things to keep in step.
--
-- No capability beyond the terminal: sys.procs and sys.stats are
-- observations of the machine, not authority over it.

local prog = require("prog")

local function die(s)
	io.stderr:write("top: " .. s .. "\n")
	os.exit(1)
end

local delay = 2
local frames = 0	-- 0 is "until told to stop"
local i = 1

while arg[i] do
	local a = arg[i]

	if a == "-d" or a == "-n" then
		local v = tonumber(arg[i + 1])

		if not v or v < 0 then
			die("usage: top [-d seconds] [-n frames]")
		end
		if a == "-d" then
			delay = v
		else
			frames = math.floor(v)
		end
		i = i + 2
	else
		die("usage: top [-d seconds] [-n frames]")
	end
end

local ok, ps = pcall(require, "ps")

if not ok then
	die("cannot load lib/ps.lua: " .. tostring(ps))
end

local term = require("ed.terminfo").new()
local tty = prog.tty()

if not term:ok() or not tty then
	die("not a terminal")
end

term:detect_size()
term:raw()
term:hide_cursor()

-- put the terminal back however this ends, including on an error: a
-- program that exits leaving the console raw and the cursor hidden has
-- broken the shell that ran it.
local function restore()
	term:show_cursor()
	term:restore()
	term:clear()
end

-- one frame, assembled whole and written once.
--
-- Written once because a write is a message: a line at a time is two
-- dozen sends per frame, each one a string copied into the console's
-- proc, for a picture that is redrawn as a unit anyway.
--
-- The buffer is reused rather than built fresh. A frame is a few tens
-- of kilobytes of strings whichever way it is done -- the table itself
-- is the small part -- but the loop below runs forever, and a program
-- that allocates nothing it can avoid is one whose footprint says
-- something when it moves.
local buf = {}

local function frame()
	local rows = term.rows or 24
	local n = 0

	local function put(s)
		n = n + 1
		buf[n] = s
	end

	-- home, then each line with a clear-eol after it. Clearing line by
	-- line rather than clearing the screen first is what stops the
	-- terminal flickering between frames.
	put("\27[H")
	put(tostring(ps.stats))
	put("\27[K\r\n\27[K\r\n")

	local shown = 2

	for line in (ps.psfmt(term.cols) .. "\n"):gmatch("([^\n]*)\n") do
		if shown >= rows - 1 then
			break
		end
		put(line)
		put("\27[K\r\n")
		shown = shown + 1
	end

	-- blank the rest, so a proc that exited leaves no row behind
	for _ = shown, rows - 2 do
		put("\27[K\r\n")
	end
	put("q to quit\27[K")

	term:write(table.concat(buf, "", 1, n))
	for i = 1, n do
		buf[i] = nil
	end
end

-- xpcall, so a fault still restores the terminal and says where it
-- came from. A full-screen program that dies without restoring leaves
-- the shell raw and the cursor hidden, and the message where the frame
-- was. kernel_strip_debug takes sethook and nothing else, so
-- debug.traceback is here.
local n = 0
local run, err = xpcall(function()
	while true do
		frame()
		n = n + 1
		if frames > 0 and n >= frames then
			return
		end

		-- collect before sleeping rather than when the allocator
		-- next decides to. A frame's worth of strings is dead the
		-- moment it is written, and this program is idle between
		-- frames -- so the pass is free here, and it keeps `top`
		-- from being the reason `top` shows memory climbing.
		collectgarbage("collect")

		-- the wait is the keyboard read: a key ends the frame early,
		-- and "" means the delay elapsed with nothing typed.
		local k = tty.getch(math.floor(delay * 1000))

		if k == "q" or k == "\27" or k == nil then
			return
		end
	end
end, function(e)
	return debug.traceback(tostring(e), 2)
end)

restore()
if not run then
	die(tostring(err))
end
