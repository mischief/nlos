-- what the board runs, and what each of those may touch. Read by
-- boot/esp32.lua; etc/services.lua is the same for a machine with a
-- disk.
--
-- `caps` names are looked up in sys.granted() and are all the authority
-- a service gets. An entry naming one this board lacks is skipped.

return {
	-- names to addresses, for anything above it. First, because a
	-- service is a capability to whatever comes after it and the
	-- panel's programs name this one.
	{ path = "/task/dns.lua", caps = { "ip", "dhcpd" }, ns = false },

	-- the radio's control plane as /net/wifi, so a program can pick a
	-- network without being handed the NIC. Before the panel, because
	-- `mount` is inherited by what starts after it and the panel's
	-- programs are what read it.
	{ path = "/task/wifisrv.lua", caps = { "eth" }, ns = false,
	  mount = "/net/wifi" },

	-- the panel, the keyboard and the pointer, as the machine's own
	-- interface: a tray of apps, one of them a terminal, which starts
	-- at boot so the board comes up at a prompt.
	{ path = "/task/dio.lua", caps = { "fb", "kbd", "ptr", "cons" },
	  optcaps = { "tcp", "ip", "dns", "power" } },

	-- the panel and the keyboard as a plain terminal, for a board
	-- with no pointer. Exactly one of this and dio above belongs in a
	-- machine's file: both name fb and kbd, so both would start, and
	-- two consoles drawing on one screen is two consoles drawing on
	-- one screen.
	-- { path = "/task/fbterm.lua", caps = { "fb", "kbd", "cons" },
	--   optcaps = { "tcp", "ip", "power" } },

	-- the wall clock. "time" is the right to sys.settime, and this is
	-- the only entry naming it: everything else reads the clock and
	-- cannot move it.
	{ path = "/task/timed.lua", caps = { "ip", "time" },
	  optcaps = { "dns" } },

	-- No 9P export here. task/9pexport.lua ships to this board like
	-- everything else under task/, and a machine with a disk runs it
	-- from its own list -- but a handheld does not put its namespace
	-- on the network because it happens to have joined one.
}
