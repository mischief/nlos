-- what a hosted machine runs, and what each of those may touch.
--
-- Read by lib/svc.lua from init.lua, exactly as the other machines'
-- lists are. This one is short because a process has no devices: a
-- terminal, a directory, and whatever file -d named.

-- boot parameters, the same channel qemu's -fw_cfg is on the machines
-- with firmware. Absent is normal: a machine told nothing runs with
-- what its defaults give it.
local ok_efi, efi = pcall(require, "los.efi")
local resolver = ok_efi and type(efi) == "table" and efi.fwcfg and
    efi.fwcfg("opt/org.luaos.resolver") or nil

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

	-- names to addresses, over the udp the kernel granted. Named `ip`
	-- because that is what task/dns.lua calls whatever gives it udp.
	-- The resolver is the host's own, read from its resolv.conf and
	-- passed in as a boot parameter: there is no lease to learn one
	-- from, and no default is right on an unknown network.
	{ path = "/task/dns.lua", caps = { ip = "udp" }, ns = false,
	  args = { resolver = resolver } },

	-- the panel, where --gui opened a window: a tray of apps, one of
	-- them a terminal. Naming fb, kbd and ptr is what decides it --
	-- a machine started headless has none of the three and skips this,
	-- and comes up on its console alone.
	{ path = "/task/dio.lua", caps = { "fb", "kbd", "ptr", "cons" },
	  optcaps = { "tcp", "dns", "power" } },

	-- No ip or tcp4 task: raw ethernet is not something an
	-- unprivileged process gets, so there are no frames to build them
	-- on. tcp and udp come from the kernel instead, as capabilities
	-- this machine was born holding.

	-- No panel: the display is the terminal this was started from.
}
