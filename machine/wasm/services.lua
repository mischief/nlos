-- what a wasm machine runs, and what each of those may touch.
--
-- Read by lib/svc.lua from init.lua, exactly as the other machines'
-- lists are. This one is the shortest there is: a module has a console
-- and the tree built into it, and no device of any kind.

return {
	-- names for rights, at /srv. Early, because the mount it declares
	-- is inherited by everything after it.
	{ path = "/task/srvd.lua", name = "srv",
	  mount = "/srv", mountfs = "srvfs" },

	-- the panel, where the embedder opened a screen: a tray of apps,
	-- one of them a terminal. Naming fb, kbd and ptr is what decides
	-- it -- an embedder that opened none has all three absent, skips
	-- this, and comes up on its console alone.
	-- what survives a reload: a FAT volume on the small disk the
	-- embedder keeps. Before dio, so an app started from the tray
	-- inherits the mount and can keep a key or a setting.
	{ path = "/task/cfgsrv.lua", name = "config", caps = { "blk" },
	  mount = "/config" },

	{ path = "/task/dio.lua", caps = { "fb", "kbd", "ptr", "cons" },
	  optcaps = { "power", "ws" } },

	-- No disk, and no tcp or udp: what this machine has of the network
	-- is websockets, which the panel lends on to an app whose entry
	-- asks for one.
}
