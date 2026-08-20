-- what the panel may start on a wasm machine, read by task/dio.lua.
--
-- The shape and every field are etc/dio.lua's; read that one for what
-- they mean. This list is shorter because this machine has no network,
-- no radio and no disk: an entry needing any of them would show in the
-- launcher and fail when touched.

return {
	width = 28,

	apps = {
		{ name = "term", cmd = "/bin/term.lua", keys = true,
		  power = true, boot = true, label = ">", color = 0x0074d9,
		  category = "shell",
		  desc = "a shell, and everything run from one" },

		{ name = "files", cmd = "/bin/files.lua",
		  category = "files", label = "/", color = 0xff851b,
		  keys = true, opens = true, handles = { "dir" },
		  desc = "the namespace, and what is in it" },
		{ name = "view", cmd = "/bin/view.lua",
		  category = "files", label = "T", color = 0x39cccc,
		  keys = true,
		  handles = { "%.lua$", "%.txt$", "%.md$", "%.csv$",
		    "%.conf$", "^[^.]*$" },
		  desc = "read a file" },

		-- the relays, over the only network this machine has. The
		-- identity is generated and kept in memory: there is no
		-- /config here to write an nsec to, so a reload is a new
		-- one.
		{ name = "nostr", cmd = "/bin/nostrui.lua",
		  category = "chat", label = "N", color = 0x8e44ad,
		  keys = true, net = true,
		  desc = "read and post notes over nostr" },

		{ name = "2048", cmd = "/bin/2048.lua", category = "games",
		  label = "2", color = 0xedc22e, keys = true,
		  desc = "slide the tiles together" },

		{ name = "scribble", cmd = "/bin/scribble.lua",
		  category = "toys", label = "S", color = 0x2ecc40,
		  desc = "draw on the screen with a finger" },
		{ name = "smiley", cmd = "/bin/smiley.lua", category = "toys",
		  label = "O", color = 0xffdc00,
		  desc = "a face, for testing the framebuffer" },
		{ name = "clock", cmd = "/bin/clock.lua", category = "toys",
		  label = "T", color = 0xff2418,
		  desc = "the time; touch it to turn it over" },

		{ name = "settings", cmd = "/bin/settings.lua",
		  category = "system", label = "=", color = 0xaaaaaa,
		  keys = true, desc = "memory, network and uptime" },
	},
}
