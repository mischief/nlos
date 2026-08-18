-- term: the panel and the keyboard, as a second terminal.
--
--	> term
--
-- A proc of its own, the way task/sshd.lua is: the serial line stays the
-- console and this is another one beside it, so a machine on a bench
-- keeps the terminal you debug it from while the terminal in your hands
-- runs a shell.

-- The kernel keeps the two keyboards on separate ports (devkbdport,
-- granted as "kbd") precisely so they do not race for each other's
-- input.

-- The stack, bottom to top, is the same as the serial one with the
-- bottom swapped: lib/fbcons.lua draws glyphs where task/cons.lua writes
-- bytes, and lib/console.lua is the tty logic in both. What a program is
-- handed at the top is the identical capability, so the shell here needs
-- no special case.

local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")

local ctx = prog.ctx or {}
local fb = ctx.fb

-- Under a window system the event port carries keystrokes and window
-- state both; from a shell it is the keyboard the shell was lent.
local kbd = ctx.ev or ctx.kbd

if not fb then
	io.stderr:write("term: no screen on this machine\n")
	os.exit(1)
end
if not kbd then
	io.stderr:write("term: no keyboard on this machine\n")
	os.exit(1)
end

-- stderr is the serial line, for saying what went wrong.
--
-- lib/thread prints a thread's error and drops it (docs/scheduling.md: a
-- fault in a thread never breaks the proc), so a shell that raised looks
-- exactly like a shell that is idle. The panel cannot be relied on to
-- report its own failure: whatever broke may be the thing that draws.
local function say(s)
	io.stderr:write(s)
end

local console = require("console")
local fbcons = require("fbcons")

local backend = fbcons.new({
	fb = fb,
	keyport = kbd,
	font = require("los.font"),
})

-- where the shell reads its exit notices. The console owns the proc's
-- mailbox, and the kernel delivers sys.monitor's notices there whoever
-- asked for them, so the console forwards them on.
--
-- One send right, minted once: the console calls this for every message
-- it does not recognise, and a right per message is a right leaked.
local notices = sys.newport("term.notices")
local noticeto = assert(sys.sendright(notices), "out of rights")

-- ---- the window, where there is one ----
--
-- Under task/dio.lua the event port carries window state as well as
-- keys: hidden the terminal stops drawing, so output produced behind
-- another app costs one repaint on the way back rather than a span per
-- write. On a machine with no window system it never arrives.
local con = console.new(backend, {
	other = function(m)
		sys.send(noticeto, m)
	end,
	kbdother = function(m)
		if m.t ~= "win" then
			return
		end
		if m.state == "redraw" then
			backend.redraw()
		elseif m.state == "hidden" then
			backend.hide()
		elseif m.state == "visible" then
			backend.show()
		end
	end,
})

-- the grid, on the serial line. A program that lays out columns asks the
-- console for this, and the panel is the only console that can answer --
-- so when a table or a page comes out the wrong height, this says
-- whether the console knew its own size or the program guessed.
say(("term: %sx%s\n"):format(tostring(backend.cols),
    tostring(backend.rows)))

-- the console serves on this proc's own port, so what the shell writes
-- to comes back here. A send right to ourselves is the whole of it.
local consright = sys.sendright(sys.SELF)

thread.spawn(function()
	con:serve()
end)

-- The shell runs here, as a thread. Sharing the proc means it needs no
-- namespace description, no monitor on the terminal and no rights of its
-- own: it has this proc's namespace and cannot outlive the terminal.

-- The network is lent to every program the shell runs, which is how
-- bin/fetch.lua reaches the stack -- see prog.net. And power, on the
-- same terms, which is how bin/reboot.lua restarts the machine. This
-- terminal is a local one -- the panel and the keyboard in your hands --
-- so it holds what the serial console holds. A public session (sshd,
-- webterm) does not.
thread.spawn(function()
	require("fbsh").run({
		cons = consright,
		notices = notices,
		ns = prog.ns() or require("ns").current(),
		fb = fb,
		-- the pointer, for the programs run here: this reads keys
		-- and never a record.
		ptr = ctx.ptr,
		net = ctx.net,
		udp = ctx.udp,
		dns = ctx.dns,
		seed = ctx.seed,
		power = ctx.power,
	})
end)

thread.run()
