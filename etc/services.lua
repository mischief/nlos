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
	-- names to addresses, for anything above it. First, because a
	-- service is a capability to whatever comes after it and the
	-- panel's programs name this one.
	{ path = "/task/dns.lua", caps = { "ip", "dhcpd" }, ns = false },

	-- the radio's control plane as /net/wifi, so a program can pick a
	-- network without being handed the NIC. Before the panel, because
	-- `mount` is inherited by what starts after it and the panel's
	-- programs are what read it. A machine whose interface has nothing
	-- to associate serves nothing and the mount does not appear.
	{ path = "/task/wifisrv.lua", caps = { "eth" }, ns = false,
	  mount = "/net/wifi" },

	-- the panel, the keyboard and the pointer, as the machine's own
	-- interface: a tray of apps, one of them a terminal, which starts
	-- at boot so the board still comes up at a prompt.
	--
	-- ptr is the pointer: dio holds the receive right and hands each
	-- app its own, as it already did for the keyboard.

	-- Naming it also decides the machine: a service naming a
	-- capability the machine has not got is skipped, and a board with
	-- a panel and no pointer wants task/fbterm.lua instead, which is
	-- the entry below.
	--
	-- tcp is optional rather than required: a panel is still a panel
	-- on a board with no stack. Where there is one it reaches the
	-- shell in the window, which is how fetch finds a network.
	--
	-- power is optional on the same terms, and is what bin/reboot.lua
	-- spends. A panel you have to be holding the board to touch is
	-- allowed to restart it; a session that arrives over the network
	-- is not, which is why the grant is here and not in dos.
	-- kbd is optional, and the pointer is not: a tray is reached by
	-- touching it, and dio drops the key pump where there is no
	-- keyboard. That is a machine whose keys arrive over the console
	-- rather than as a device of their own, which is every efi one.
	{ path = "/task/dio.lua", caps = { "fb", "ptr", "cons" },
	  optcaps = { "kbd", "tcp", "ip", "dns", "power" } },

	-- the panel and the keyboard as a plain terminal, for a board
	-- with no pointer. Exactly one of this and dio above belongs in a
	-- machine's file: both name fb and kbd, so both would start, and
	-- two consoles drawing on one screen is two consoles drawing on
	-- one screen.
	-- { path = "/task/fbterm.lua", caps = { "fb", "kbd", "cons" },
	--   optcaps = { "tcp", "ip", "power" } },

	-- the browser shell. off by default: it hands anonymous visitors a
	-- shell, which is a decision to make deliberately rather than
	-- inherit from a default config.
	-- note port 80 rather than 7777: init's 9p-over-tcp server holds
	-- 7777, and two listeners on one port is EFI_INVALID_PARAMETER.
	-- { path = "/task/webterm.lua", caps = { "tcp" },
	--   args = { port = 80 } },

	-- the wall clock. "time" is the right to sys.settime, and this is
	-- the only entry naming it: everything else reads the clock and
	-- cannot move it. The lease names the server, read as /net/ntp through
	-- the namespace; dns is the pool fallback where it carried none.
	{ path = "/task/timed.lua", caps = { "ip", "time" },
	  optcaps = { "dns" } },

	-- an ssh server, putting a visitor at the same lua console the
	-- serial port gives. Off by default, on the same terms as webterm
	-- -- an anonymous visitor gets a shell -- and more so, since it
	-- accepts any public key. It also costs about 284KB of a board
	-- whose ceiling is memory, idle or not.
	--
	-- args.trace = true logs every packet's message number to the
	-- console, which is what to turn on when working on the protocol.
	-- { path = "/task/sshd.lua", caps = { "tcp" },
	--   args = { port = 2222 } },
}
