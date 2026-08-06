-- fbterm: the panel and the keyboard, as a second terminal.
--
-- A proc of its own, the way task/sshd.lua is: the serial line stays
-- the console and this is another one beside it, so a machine on a
-- bench keeps the terminal you debug it from while the terminal in your
-- hands runs a shell. Two consoles, two keyboards, one kernel -- the
-- kernel keeps their keystrokes on separate ports (devkbdport, granted
-- as "kbd") precisely so they do not race for each other's input.
--
-- The stack, bottom to top, is the same as the serial one with the
-- bottom swapped: lib/fbcons.lua draws glyphs where task/cons.lua
-- writes bytes, lib/console.lua is the tty logic in both, and what a
-- program is handed at the top is the identical capability. That is why
-- the shell here needs no special case, and why bin/smiley.lua can take
-- the screen from a prompt that is drawn on it.
--
-- Spawned with a message carrying its rights:
--	{ fb = {__right=}, kbd = {__right=} }

local sys = require("los.sys")
local thread = require("los.thread")

local job = thread.recv(sys.SELF)
local fb = job.fb.__right
local kbd = job.kbd.__right

-- the serial console, for saying what went wrong.
--
-- lib/thread prints a thread's error and drops it (docs/scheduling.md:
-- a fault in a thread never breaks the proc), and print() from here
-- reaches nobody -- so a shell that raised looked exactly like a shell
-- that was idle, twice. The panel cannot be relied on to report its own
-- failure: whatever broke may be the thing that draws.
local logright = job.cons and job.cons.__right

local function say(s)
	if logright then
		sys.send(logright, { op = "write", data = s })
	end
end

local console = require("console")
local fbcons = require("fbcons")
local dos = require("dos")
local ns = require("ns")

local con = console.new(fbcons.new({
	fb = fb,
	keyport = kbd,
	font = require("los.font"),
}))

-- the console serves on this proc's own port, so what the shell writes
-- to comes back here. A send right to ourselves is the whole of it.
local consright = sys.sendright(sys.SELF)

thread.spawn(function()
	con:serve()
end)

-- The namespace the shell looks programs up in.
--
-- Mounted rather than faked. An unprivileged proc has no io.open
-- (kernel_strip_io: files come through a mount, not through ambient
-- authority), and on this platform the files live in the app image
-- with no server in front of them -- so lib/romfs.lua serves the image
-- as a local dev backend, the way lib/procfs.lua serves the process
-- table, and this is an ordinary read-only mount over it.
local N = ns.new()
local mok, merr = N:mount("/", require("romfs").new(), "romfs")

if not mok then
	say("fbterm: mount failed: " .. tostring(merr) .. "\n")
end

thread.spawn(function()
	local sh = dos.new({
		ns = N,
		cons = consright,
		fb = fb,
	})
	local ok, err = xpcall(function()
		sh:repl("> ")
	end, debug.traceback)

	if not ok then
		say("fbterm: shell died: " .. tostring(err) .. "\n")
	end
end)

thread.run()
