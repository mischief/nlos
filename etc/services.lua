-- what this machine runs, and what each of those may touch.
--
-- read by lib/svc.lua from init.lua once the machine is up. `caps` names
-- are looked up in sys.granted(), and the rights found there are ALL the
-- authority a service gets -- it has no path to anything it did not name.
-- so this file is the machine's capability grant table, which is the job
-- unix would want users and mode bits for.
--
-- a service naming a capability this machine does not have (tcp with no
-- NIC) is skipped rather than started to fail.
--
-- it is a lua chunk rather than a data format so a machine can decide
-- what to run from what it can see, without this growing a syntax.

return {
	-- the panel, the keyboard and the pointer, as the machine's own
	-- interface: a tray of apps, one of them a terminal, which starts
	-- at boot so the board still comes up at a prompt.
	--
	-- ptr is named although dio never uses the right -- it reaches
	-- the pointer as /dev/mouse, like any other program. What naming
	-- it does is decide the machine: a service naming a capability
	-- the machine has not got is skipped, and every button in this
	-- one is a place to touch. A board with a panel and no pointer
	-- wants task/fbterm.lua instead, which is the entry below.
	--
	-- tcp is optional rather than required: a panel is still a panel
	-- on a board with no stack. Where there is one it reaches the
	-- shell in the window, which is how fetch finds a network.
	{ path = "/task/dio.lua", caps = { "fb", "kbd", "ptr", "cons" },
	  optcaps = { "tcp" } },

	-- the panel and the keyboard as a plain terminal, for a board
	-- with no pointer. Exactly one of this and dio above belongs in a
	-- machine's file: both name fb and kbd, so both would start, and
	-- two consoles drawing on one screen is two consoles drawing on
	-- one screen.
	-- { path = "/task/fbterm.lua", caps = { "fb", "kbd", "cons" },
	--   optcaps = { "tcp" } },

	-- the browser shell. off by default: it hands anonymous visitors a
	-- shell, which is a decision to make deliberately rather than
	-- inherit from a default config.
	-- note port 80 rather than 7777: init's 9p-over-tcp server holds
	-- 7777, and two listeners on one port is EFI_INVALID_PARAMETER.
	-- { path = "/task/webterm.lua", caps = { "tcp" },
	--   args = { port = 80 } },

	-- names to addresses, for anything above it. udp is served by
	-- task/ip.lua here and by the firmware elsewhere, so it is named
	-- by whichever this machine has.
	{ path = "/task/dns.lua", caps = { "ip" } },

	-- an ssh server, putting a visitor at the same lua console the
	-- serial port gives. same bargain as webterm -- an anonymous
	-- visitor gets a shell -- and additionally it accepts ANY public
	-- key so far, so it is on here only because this is a branch for
	-- working on it.
	-- trace = true logs every packet's message number to the console.
	-- It found two of this branch's bugs and is worth turning back on
	-- to find the next one, but it is debug output and does not belong
	-- in a default boot.
	{ path = "/task/sshd.lua", caps = { "tcp" },
	  args = { port = 2222 } },
}
