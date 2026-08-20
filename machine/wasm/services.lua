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

	-- No disk, no network and no panel: there is nothing here to grant
	-- for any of them.
}
