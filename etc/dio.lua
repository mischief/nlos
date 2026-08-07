-- what the tray holds, read by bin/dio.lua at startup.
--
-- A lua chunk rather than a data format, for the reason
-- etc/services.lua is one: the machine decides what it offers from what
-- it can see, and a table is enough syntax for that.
--
-- Each entry:
--	name	what it is called, and what the tray says if there is no
--		label. Also the name the proc runs under.
--	cmd	the program, as a path in the namespace dio was given. A
--		program that is not there is drawn dimmed rather than
--		left out, so a missing file looks like a missing file.
--	label	one character for the button. The tray is 28 pixels wide
--		and a glyph is 8, so a word does not fit.
--	color	the button, 0xRRGGBB.
--
-- width is the tray, in pixels. Everything right of it is the app, and
-- an app is told that rectangle is the screen.

return {
	width = 28,

	apps = {
		{ name = "scribble", cmd = "/bin/scribble.lua",
		  label = "S", color = 0x2ecc40 },
		{ name = "smiley", cmd = "/bin/smiley.lua",
		  label = "O", color = 0xffdc00 },
	},
}
