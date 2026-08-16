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
--		to a program that never reads them would fill a port. A
--		terminal gets them whatever this says.
--	ble	lend this one the bluetooth adapter. Off by default and
--		named per entry rather than given to everything: the
--		radio is a singleton, and a program that never asked for
--		it cannot advertise as somebody else.
--	kind	"term" for the console stack, which takes a framebuffer
--		and a keyboard rather than the program ABI. Anything else
--		is an ordinary program.
--	category
--		which heading the launcher files it under. Groups appear
--		in the order first named below. Entries naming none go
--		under "other", last; all-one-category gets no headings.
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
		-- shell. kind = "term" is the one entry dio starts
		-- differently -- task/fbterm.lua takes a framebuffer and a
		-- keyboard rather than the program ABI, and dio gives it
		-- the window and the keys it was lent.
		-- boot = true starts it before anything is touched, so the
		-- machine comes up at a prompt rather than at a tray and
		-- an empty rectangle.
		{ name = "term", cmd = "/task/fbterm.lua", kind = "term",
		  boot = true, label = ">", color = 0x0074d9, category = "shell",
		  desc = "a shell, and everything run from one" },

		{ name = "scribble", cmd = "/bin/scribble.lua", category = "toys",
		  label = "S", color = 0x2ecc40,
		  desc = "draw on the screen with a finger" },
		{ name = "smiley", cmd = "/bin/smiley.lua", category = "toys",
		  label = "O", color = 0xffdc00,
		  desc = "a face, for testing the framebuffer" },
		-- the radio. It reads and writes /net/wifi, which is a
		-- mount rather than a capability, so it appears here on a
		-- board that has one and does nothing on a board that
		-- does not.
		{ name = "wifi", cmd = "/bin/wifiui.lua", category = "system",
		  label = "W", color = 0x7fdbff, keys = true,
		  desc = "join a network" },
		-- the mesh. Keys, because a chat is typed, and the radio,
		-- which is what ble = true above means.
		{ name = "bitchat", cmd = "/bin/bitchatui.lua",
		  category = "system", label = "B", color = 0xb10dc9,
		  keys = true, ble = true,
		  desc = "the bitchat mesh, over bluetooth" },
		-- what the machine is and what it is holding. Reads only,
		-- so it needs nothing granted; the controls it is named
		-- for are the TODOs in its own header.
		{ name = "settings", cmd = "/bin/settings.lua",
		  category = "system", label = "=", color = 0xaaaaaa,
		  keys = true, desc = "memory, network and uptime" },
		-- the namespace. `opens` is the one entry given the door,
		-- since it is the one that asks dio to open what was
		-- touched; `handles = dir` is what a directory opens in,
		-- so opening one from anywhere lands back here.
		{ name = "files", cmd = "/bin/files.lua",
		  category = "system", label = "/", color = 0xff851b,
		  keys = true, opens = true, handles = { "dir" },
		  desc = "the namespace, and what is in it" },
		{ name = "view", cmd = "/bin/view.lua",
		  category = "system", label = "T", color = 0x39cccc,
		  keys = true,
		  -- what claims a file. Last of the three, so a rule
		  -- above it wins: this is the fallback, not the choice.
		  handles = { "%.lua$", "%.txt$", "%.md$", "%.csv$",
		    "%.conf$", "^[^.]*$" },
		  desc = "read a file" },
		{ name = "clock", cmd = "/bin/clock.lua", category = "toys",
		  label = "T", color = 0xff2418,
		  desc = "the time; touch it to turn it over" },
	},
}
