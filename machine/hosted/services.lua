-- what a hosted machine runs, and what each of those may touch.
--
-- Read by lib/svc.lua from init.lua, exactly as the other machines'
-- lists are. This one is short because a process has no devices: a
-- terminal, a directory, and whatever file -d named.

return {
	-- names for rights, at /srv. Early, because the mount it declares
	-- is inherited by everything after it.
	{ path = "/task/srvd.lua", name = "srv",
	  mount = "/srv", mountfs = "srvfs",
	  post = { esp = "esp" } },

	-- the disk, in two steps over the kernel's blk driver: partsrv
	-- slices the gefs partition off it, and gefssrv serves that at
	-- /n/gefs. A machine started with no -d grants no blk, so both are
	-- skipped and it comes up without /n/gefs.
	{ path = "/task/partsrv.lua", name = "part", caps = { "blk" },
	  args = { partition = "gefs" } },

	{ path = "/task/gefssrv.lua", name = "gefs",
	  caps = { blk = "part" }, args = { label = "main" },
	  mount = "/n/gefs" },

	-- No network: raw ethernet is not something an unprivileged
	-- process gets, so there is no eth to build ip and tcp on.

	-- No panel: the display is the terminal this was started from.
}
