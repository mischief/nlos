-- what this machine runs, and what each of those may touch.
--
-- read by lib/svc.lua from init.lua once the machine is up. `caps` names
-- are looked up in sys.granted(), and the rights found there are ALL the
-- authority a service gets -- it has no path to anything it did not name.
-- so this file is the machine's capability grant table, which is the job
-- unix would want users and mode bits for.
--
-- a service naming a capability this machine does not have (tcp with no
-- NIC) is skipped rather than started to fail.
--
-- it is a lua chunk rather than a data format so a machine can decide
-- what to run from what it can see, without this growing a syntax.
--
-- The list for a machine with a disk: efi and microvm, read by
-- init.lua. The board has its own, etc/services-esp32.lua.

return {
	-- the network, from the wire up. eth owns the NIC and stays a
	-- kernel driver; each of these owns no device and holds one send
	-- right to the layer below it. A machine with no NIC grants no
	-- eth, so ip is skipped, and tcp and dhcpd skip after it.
	{ path = "/task/ip.lua", capname = "ip", caps = { "eth" } },

	-- capname "tcp", not "tcp4": a client asks for the protocol, and
	-- lib/http.lua and lib/ssh cannot tell what implements it.
	{ path = "/task/tcp4.lua", capname = "tcp", caps = { "ip" } },

	-- the address, and keeping it. What it serves is the /net mounted
	-- below.
	{ path = "/task/dhcpd.lua", capname = "dhcpd", caps = { "ip" } },

	-- the lease as a filesystem: addr, mask, gw, dns, ntp, domain, one
	-- per file. `from` mounts a capability the kernel already started,
	-- with no proc to spawn -- dhcpd is a driver, not a service. This
	-- is how a program finds the resolver without holding a right to
	-- dhcpd or being told an address at spawn.
	{ from = "dhcpd", mount = "/net" },

	-- names for rights, at /srv. Early, because the mount it declares
	-- is inherited by everything after it. `post` publishes a right
	-- under the name a shell says to mount it by; the listing is what
	-- `ls /srv` shows, and the rights come from messages to srvd
	-- rather than from reading those files.
	{ path = "/task/srvd.lua", name = "srv",
	  mount = "/srv", mountfs = "srvfs",
	  post = { esp = "esp", net = "dhcpd" } },

	-- names to addresses, for anything above it. Early, because a
	-- service is a capability to whatever comes after it and the
	-- panel's programs name this one.
	{ path = "/task/dns.lua", caps = { "ip", "dhcpd" }, ns = false },

	-- No wifisrv: these machines have a NIC rather than a radio, and
	-- task/wifisrv.lua is not on this image. It is in the board's
	-- list, which is the whole reason there are two.

	-- the disk, in three steps. blk is the kernel's driver where the
	-- platform has one; partsrv slices the gefs partition off it, and
	-- gefssrv serves that as a filesystem at /n/gefs, which every
	-- entry below inherits. A machine with no disk names no blk, so
	-- all three are skipped and it comes up without /n/gefs.
	{ path = "/task/partsrv.lua", name = "part", caps = { "blk" },
	  args = { partition = "gefs" } },

	-- `blk = "part"` because gefssrv sits on a block device and does
	-- not care that this one is a slice of another.
	{ path = "/task/gefssrv.lua", name = "gefs",
	  caps = { blk = "part" }, args = { label = "main" },
	  mount = "/n/gefs" },

	-- the panel, the keyboard and the pointer, as the machine's own
	-- interface: a tray of apps, one of them a terminal, which starts
	-- at boot so the board still comes up at a prompt.
	--
	-- ptr is the pointer: dio holds the receive right and hands each
	-- app its own, as it already did for the keyboard.

	-- Naming it also decides the machine: a service naming a
	-- capability the machine has not got is skipped.
	--
	-- tcp is optional rather than required: a panel is still a panel
	-- on a board with no stack. Where there is one it reaches the
	-- shell in the window, which is how fetch finds a network.
	--
	-- power is optional on the same terms, and is what bin/reboot.lua
	-- spends. A panel you have to be holding the board to touch is
	-- allowed to restart it; a session that arrives over the network
	-- is not, which is why the grant is here and not in dos.
	-- kbd is named, so this starts only on a machine whose keys are a
	-- device: the panel is that machine's whole interface. Where they
	-- arrive over a console instead, the machine boots to a prompt and
	-- bin/win.lua hands the screen over on request.
	{ path = "/task/dio.lua", caps = { "fb", "kbd", "ptr", "cons" },
	  optcaps = { "tcp", "ip", "dns", "power" } },

	-- the browser shell. off by default: it hands anonymous visitors a
	-- shell, which is a decision to make deliberately rather than
	-- inherit from a default config.
	-- note port 80 rather than 7777: the 9P export below holds 7777,
	-- and two listeners on one port is EFI_INVALID_PARAMETER.
	-- { path = "/task/webterm.lua", caps = { "tcp" },
	--   args = { port = 80 } },

	-- the wall clock. "time" is the right to sys.settime, and this is
	-- the only entry naming it: everything else reads the clock and
	-- cannot move it. The lease names the server, read as /net/ntp through
	-- the namespace; dns is the pool fallback where it carried none.
	{ path = "/task/timed.lua", caps = { "ip", "time" },
	  optcaps = { "dns" } },

	-- an ssh server, putting a visitor at the same lua console the
	-- serial port gives. Off by default, on the same terms as webterm
	-- -- an anonymous visitor gets a shell -- and more so, since it
	-- accepts any public key. It also costs about 284KB of a board
	-- whose ceiling is memory, idle or not.
	--
	-- args.trace = true logs every packet's message number to the
	-- console, which is what to turn on when working on the protocol.
	-- { path = "/task/sshd.lua", caps = { "tcp" },
	--   args = { port = 2222 } },

	-- the whole namespace over tcp/7777: /net, /srv, /n, /proc and
	-- whatever is mounted, which is what 9P is for. Last, so the
	-- mounts it exports are already made.
	{ path = "/task/9pexport.lua", name = "9pexport-all",
	  caps = { net = "tcp" }, args = { root = "/", port = 7777 } },

	-- the gefs subtree alone, on the styx port, so `9fs host` reaches
	-- the volume from off the machine. Exactly `exportfs -r /n/gefs`.
	-- It names gefs so a machine with no disk skips the export too,
	-- rather than serving an empty mount point.
	{ path = "/task/9pexport.lua", name = "9pexport-gefs",
	  caps = { net = "tcp" }, needs = { "gefs" },
	  args = { root = "/n/gefs", port = 564 } },
}
