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

-- started either way: as a service, lib/svc.lua hands the capabilities
-- to the chunk as its argument; started by hand from the repl, they
-- arrive in a message.
local job = ... or thread.recv(sys.SELF)
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

-- The shell runs in a proc of its own.
--
-- lib/console.lua serves on this proc's mailbox, and a shell waits on
-- its own mailbox for the exit notice of every program it starts. Both
-- in one proc means two consumers of one port: the console takes the
-- notice, does not recognise it, and drops it, and the shell waits for
-- a program that has already gone. task/cons.lua and its shells are
-- separate procs on the other platforms for the same reason.
local f = io and io.open and io.open("/task/fbsh.lua")
local src = f and f:read("a")

if f then
	f:close()
end
if not src then
	src = require("los.rom").read("/task/fbsh.lua")
end

if src then
	local _, sh = sys.spawn(src, { name = "fbsh" })

	-- the namespace travels as a description, not as a mount: the
	-- child rebuilds it from the kinds it has registered, and the
	-- rights inside it are copied on the way as any other right is.
	-- Without it the shell sees the embedded image alone, which holds
	-- no programs.
	--
	-- Described from this proc's own namespace rather than taken from
	-- the spawn message. lib/svc.lua hands the description to
	-- proc.spawn, which adopts it before this chunk runs; what arrives
	-- in the message is the capability table alone.
	local N = require("ns").current()

	sys.send(sh, {
		cons = { __right = consright },
		fb = { __right = fb },
		ns = N and N:describe(),
	})
	sys.close(sh)
else
	say("fbterm: no /task/fbsh.lua\n")
end

thread.run()
