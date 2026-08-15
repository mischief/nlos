-- what a microvm runs, and what each of those may touch.
--
-- Read by lib/svc.lua from init.lua, exactly as the other machines'
-- lists are. This one is short because a microvm has no screen and no
-- pointer: it is a kernel, a serial line and whatever virtio devices
-- the host attached.

return {
	-- the network, from the wire up. eth owns the NIC and stays a
	-- kernel driver; each of these owns no device and holds one send
	-- right to the layer below it. A machine booted with -net none
	-- grants no eth, so all three are skipped.
	{ path = "/task/ip.lua", capname = "ip", caps = { "eth" } },

	-- capname "tcp", not "tcp4": a client asks for the protocol, and
	-- lib/http.lua and lib/ssh cannot tell what implements it.
	{ path = "/task/tcp4.lua", capname = "tcp", caps = { "ip" } },

	-- the address, and keeping it. What it serves is the /net mounted
	-- below.
	{ path = "/task/dhcpd.lua", capname = "dhcpd", caps = { "ip" } },

	-- the lease as a filesystem: addr, mask, gw, dns, ntp, domain, one
	-- per file. `from` mounts a capability that already exists, with no
	-- proc to spawn.
	{ from = "dhcpd", mount = "/net" },

	-- names to addresses, for anything above it.
	{ path = "/task/dns.lua", caps = { "ip", "dhcpd" }, ns = false },

	-- No srvd, no panel, no 9P export. A microvm is a test and
	-- development target reached over its serial line; a host that
	-- wants any of those adds them to this file.
}
