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
local notices = sys.newport("fbterm.notices")
local noticeto = assert(sys.sendright(notices), "out of rights")

-- ---- the window, where there is one ----
--
-- Under task/dio.lua the keyboard port carries window state as well as
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

-- the grid, on the serial line. A program that lays out columns asks
-- the console for this, and the panel is the only console that can
-- answer -- so when a table or a page comes out the wrong height, this
-- says whether the console knew its own size or the program guessed.
say(("fbterm: %sx%s\n"):format(tostring(backend.cols),
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
--
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
		ns = require("ns").current(),
		fb = fb,
		-- the pointer, for the programs run here: this reads keys
		-- and never a record.
		ptr = job.ptr and job.ptr.__right,
		net = job.tcp and job.tcp.__right,
		udp = job.ip and job.ip.__right,
		dns = job.dns and job.dns.__right,
		seed = job.seed,
		power = job.power and job.power.__right,
	})
end)

thread.run()
