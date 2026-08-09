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
--	kind	"term" for the console stack, which takes a framebuffer
--		and a keyboard rather than the program ABI. Anything else
--		is an ordinary program.
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
		  boot = true, label = ">", color = 0x0074d9,
		  desc = "a shell, and everything run from one" },

		{ name = "scribble", cmd = "/bin/scribble.lua",
		  label = "S", color = 0x2ecc40,
		  desc = "draw on the screen with a finger" },
		{ name = "smiley", cmd = "/bin/smiley.lua",
		  label = "O", color = 0xffdc00,
		  desc = "a face, for testing the framebuffer" },
		{ name = "clock", cmd = "/bin/clock.lua",
		  label = "T", color = 0xff2418,
		  desc = "the time; touch it to turn it over" },
	},
}
