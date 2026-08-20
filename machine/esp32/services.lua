-- what the board runs, and what each of those may touch. Read by
-- init.lua on this board; machine/efi/services.lua is the same for a
-- machine with a disk.
--
-- `caps` names are looked up in sys.granted() and are all the authority
-- a service gets. An entry naming one this board lacks is skipped.

return {
	-- the network, from the wire up. eth owns the radio and stays a
	-- kernel driver; each of these owns no device and holds one send
	-- right to the layer below it. They start before the radio has
	-- associated and carry nothing until it does.
	-- ns = false: this one resolves no path. A namespace costs ~100K a
	-- proc, and what a service without one still reaches is the
	-- ambient searcher over the firmware image -- which is where every
	-- lib it requires already lives.
	{ path = "/task/ip.lua", capname = "ip", caps = { "eth" },
	  ns = false },

	-- capname "tcp", not "tcp4": a client asks for the protocol, and
	-- lib/http.lua and lib/ssh cannot tell what implements it.
	{ path = "/task/tcp4.lua", capname = "tcp", caps = { "ip" } },

	-- the address, and keeping it. What it serves is the /net mounted
	-- below.
	{ path = "/task/dhcpd.lua", capname = "dhcpd", caps = { "ip" },
	  ns = false },

	-- the lease as a filesystem: addr, mask, gw, dns, ntp, domain, one
	-- per file. `from` mounts a capability the kernel already started,
	-- with no proc to spawn -- dhcpd is a driver, not a service.
	{ from = "dhcpd", mount = "/net" },

	-- names for rights, at /srv. Early, because the mount it declares
	-- is inherited by everything after it. No esp to post here: this
	-- board's volume is flash, and fatsrv already serves it at /.
	-- ns = false here too: it serves /srv rather than reading it, and
	-- the mount it declares is built in whoever inherits it.
	{ path = "/task/srvd.lua", name = "srv",
	  mount = "/srv", mountfs = "srvfs", ns = false,
	  post = { net = "dhcpd" } },

	-- names to addresses, for anything above it. Early, because a
	-- service is a capability to whatever comes after it and the
	-- panel's programs name this one.
	{ path = "/task/dns.lua", caps = { "ip", "dhcpd" }, ns = false },

	-- the radio's control plane as /net/wifi, so a program can pick a
	-- network without being handed the NIC. Before the panel, because
	-- `mount` is inherited by what starts after it and the panel's
	-- programs are what read it.
	-- with a namespace, unlike the services around it: this one keeps
	-- /config/wifi.lua, so it opens files as well as serving them.
	{ path = "/task/wifisrv.lua", caps = { "eth" },
	  mount = "/net/wifi" },

	-- the panel, the keyboard and the pointer, as the machine's own
	-- interface: a tray of apps, one of them a terminal, which starts
	-- at boot so the board comes up at a prompt.
	-- the bluetooth controller, which is a singleton: one advertising
	-- set, one scan, one attribute database and a budget of ten
	-- activities between them. Programs hold a right to this rather
	-- than to raw hci, and bin/hcitool.lua is the exception that
	-- proves it -- a diagnostic, granted the transport directly.
	-- Before the panel, because dio lends this to the apps it starts.
	{ path = "/task/blesrv.lua", caps = { "hci" }, capname = "ble" },

	-- the mesh, over the radio. Programs hold a right to this rather
	-- than to the radio: keys, dedup and the node table are its, and
	-- two clients driving one chip would be two nodes on one antenna.
	-- The public channel, which is a real network with real people on
	-- it: a nodeinfo every three hours is what their firmware does and
	-- all this sends unasked. Naming a channel here picks a slot of
	-- its own instead -- `channel = "luaos"` sits about nine megahertz
	-- off -- and `mesh tune` visits without transmitting.
	{ path = "/task/meshsrv.lua", caps = { "lora" }, capname = "mesh",
	  args = { preset = "MEDIUM_FAST", region = "US", hop = 3 } },

	{ path = "/task/dio.lua", caps = { "fb", "kbd", "ptr", "cons" },
	  optcaps = { "tcp", "ip", "dns", "power", "ble", "mesh" } },

	-- the wall clock. "time" is the right to sys.settime, and this is
	-- the only entry naming it: everything else reads the clock and
	-- cannot move it.
	-- gps is optional and asked first: a receiver needs no lease and
	-- no server, and this is the one proc that may move the clock, so
	-- the choice of source belongs here rather than in gpsd.
	{ path = "/task/timed.lua", caps = { "ip", "time" },
	  optcaps = { "dns", "gps" } },

	-- No 9P export here. task/9pexport.lua ships to this board like
	-- everything else under task/, and a machine with a disk runs it
	-- from its own list -- but a handheld does not put its namespace
	-- on the network because it happens to have joined one.
}
