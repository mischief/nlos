-- what may be started, read by task/dio.lua at startup.
--
-- A catalogue rather than a set of tray slots: the tray shows what is
-- RUNNING, and an entry here may be started more than once. Two
-- terminals are two instances of the one entry below.
--
-- A lua chunk rather than a data format, for the reason
-- etc/services.lua is one: the machine decides what it offers from what
-- it can see, and a table is enough syntax for that.
--
-- Each entry:
--	name	what it is called, and what the tray says if there is no
--		label. The proc runs under it too, numbered where more
--		than one instance is up: term, term(2).
--	cmd	the program, as a path in the namespace dio was given.
--	desc	one line about it, shown in the launcher's list.
--	label	one character for the button. The tray is 28 pixels wide
--		and a glyph is 8, so a word does not fit.
--	color	the button, 0xRRGGBB.
--	keys	give this one the keyboard while it is in front. Off by
--		default: an app is reached with the pointer, and keys sent
--		to a program that never reads them would fill a port.
--	power	let this one restart the machine, which bin/reboot.lua
--		spends. Off by default.
--	ble	lend this one the bluetooth adapter. Off by default and
--		named per entry rather than given to everything: the
--		radio is a singleton, and a program that never asked for
--		it cannot advertise as somebody else.
--	mesh	lend this one the lora mesh, on the same terms as ble.
--	gps	lend this one the gnss receiver, on the same terms. Where
--		the machine is is not something every entry is told.
--	category
--		which heading the launcher files it under. Groups appear
--		in the order first named below, one open at a time, and
--		the first is what opens. Entries naming none go under
--		"other", last; all-one-category gets no headings.
--		An entry whose program is absent greys as "(missing)".
--	boot	start this one when dio starts, and the one the launcher
--		starts another of. One entry at most.
--
-- width is the tray, in pixels. Everything right of it is the app, and
-- an app is told that rectangle is the screen.

return {
	width = 28,

	apps = {
		-- a terminal, and through it everything that is not a
		-- pointer program: a shell in the window, and vi in the
		-- shell. boot = true starts it before anything is touched,
		-- so the machine comes up at a prompt rather than at a
		-- tray and an empty rectangle.
		{ name = "term", cmd = "/bin/term.lua", keys = true,
		  net = true, power = true,
		  boot = true, label = ">", color = 0x0074d9, category = "shell",
		  desc = "a shell, and everything run from one" },

		-- the namespace. `opens` is the one entry given the door,
		-- since it is the one that asks dio to open what was
		-- touched; `handles = dir` is what a directory opens in,
		-- so opening one from anywhere lands back here.
		{ name = "files", cmd = "/bin/files.lua",
		  category = "files", label = "/", color = 0xff851b,
		  keys = true, opens = true, handles = { "dir" },
		  desc = "the namespace, and what is in it" },
		{ name = "view", cmd = "/bin/view.lua",
		  category = "files", label = "T", color = 0x39cccc,
		  keys = true,
		  -- what claims a file. Last of the three, so a rule
		  -- above it wins: this is the fallback, not the choice.
		  handles = { "%.lua$", "%.txt$", "%.md$", "%.csv$",
		    "%.conf$", "^[^.]*$" },
		  desc = "read a file" },
		{ name = "edit", cmd = "/bin/editui.lua",
		  category = "files", label = "E", color = 0xff7f0e,
		  keys = true, desc = "change a file, not only read one" },

		-- a model, with this machine as its tools. Keys because it
		-- is typed at, and net because it talks to a server -- the
		-- key it uses is on /config, not in the image.
		{ name = "agent", cmd = "/bin/agentui.lua",
		  category = "net", label = "?", color = 0x2ecc40,
		  keys = true, net = true,
		  desc = "ask a model, and let it use the machine" },
		{ name = "gemini", cmd = "/bin/geminiui.lua",
		  category = "net", label = "@", color = 0x1f77b4,
		  keys = true, net = true,
		  desc = "read a capsule, and follow its links" },

		-- the mesh. Keys, because a chat is typed, and the radio,
		-- which is what ble = true above means.
		{ name = "bitchat", cmd = "/bin/bitchatui.lua",
		  category = "chat", label = "B", color = 0xb10dc9,
		  keys = true, ble = true,
		  desc = "the bitchat mesh, over bluetooth" },
		-- the lora mesh. Keys to type, and mesh = true for the
		-- service: the radio is one node and this holds a right
		-- to it rather than to the chip.
		{ name = "mesh", cmd = "/bin/meshui.lua",
		  category = "chat", label = "M", color = 0x2ecc40,
		  keys = true, mesh = true,
		  desc = "the meshtastic network, over lora" },
		-- notes off the relays. Keys to type one, net to reach a
		-- relay; the identity is an nsec on /config, not here.
		{ name = "nostr", cmd = "/bin/nostrui.lua",
		  category = "chat", label = "N", color = 0x8e44ad,
		  keys = true, net = true,
		  desc = "read and post notes over nostr" },
		{ name = "irc", cmd = "/bin/ircui.lua", category = "chat",
		  label = "I", color = 0xd62728, keys = true, net = true,
		  desc = "a channel, over lib/irc" },

		-- keys as well as the pointer: the ball is the controller,
		-- and wasd is what a board without one is played on.
		{ name = "2048", cmd = "/bin/2048.lua", category = "games",
		  label = "2", color = 0xedc22e, keys = true,
		  desc = "slide the tiles together" },
		{ name = "mines", cmd = "/bin/mines.lua", category = "games",
		  label = "M", color = 0x4a90d9, keys = true,
		  desc = "touch reveals, the ball flags" },
		{ name = "sokoban", cmd = "/bin/sokoban.lua",
		  category = "games", label = "K", color = 0x8b5a2b,
		  keys = true, desc = "push every crate onto a mark" },

		-- a playlist and a player. Keys for q; the device it
		-- plays through is asked for by name at the sys level
		-- rather than granted here, so nothing is lent to it.
		{ name = "amp", cmd = "/bin/amp.lua", category = "media",
		  label = "A", color = 0x2ecc40, keys = true,
		  desc = "browse tracks, build a playlist, play it" },

		{ name = "scribble", cmd = "/bin/scribble.lua",
		  category = "toys", label = "S", color = 0x2ecc40,
		  desc = "draw on the screen with a finger" },
		{ name = "smiley", cmd = "/bin/smiley.lua", category = "toys",
		  label = "O", color = 0xffdc00,
		  desc = "a face, for testing the framebuffer" },
		{ name = "clock", cmd = "/bin/clock.lua", category = "toys",
		  label = "T", color = 0xff2418,
		  desc = "the time; touch it to turn it over" },

		-- the radio. It reads and writes /net/wifi, which is a
		-- mount rather than a capability, so it appears here on a
		-- board that has one and does nothing on a board that
		-- does not.
		{ name = "wifi", cmd = "/bin/wifiui.lua", category = "system",
		  label = "W", color = 0x7fdbff, keys = true,
		  desc = "join a network" },
		-- what the machine is and what it is holding. Reads only,
		-- so it needs nothing granted; the controls it is named
		-- for are the TODOs in its own header.
		{ name = "settings", cmd = "/bin/settings.lua",
		  category = "system", label = "=", color = 0xaaaaaa,
		  keys = true, desc = "memory, network and uptime" },
		-- where the machine is, on a board that can tell. gps
		-- rather than net: the receiver answers without one.
		{ name = "gps", cmd = "/bin/gpsui.lua",
		  category = "system", label = "*", color = 0x2ca02c,
		  keys = true, gps = true,
		  desc = "position and time, off the sky" },
		{ name = "procs", cmd = "/bin/procsui.lua",
		  category = "system", label = "P", color = 0x9467bd,
		  keys = true, desc = "what is running, and what it holds" },
		{ name = "log", cmd = "/bin/logui.lua", category = "system",
		  label = "L", color = 0x7f7f7f, keys = true,
		  desc = "the kernel ring, as it fills" },
	},
}
