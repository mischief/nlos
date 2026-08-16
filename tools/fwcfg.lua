-- how a test payload is handed to a guest, in one place. What differs
-- is whether init.lua runs.
--
--   replace   the payload is proc 0 instead of init: no services, no
--             network. A test of the kernel alone.
--   services  the payload is an injected list's last entry, under init.

-- The second is what a test needing a network must use: ip, tcp and
-- dhcpd are services, and nothing else starts them.
local M = {}

-- the stack, and the payload after it. Deliberately not a machine's own
-- /etc/services.lua: a test wants the network and itself, not a panel
-- and two 9P exports.
--
-- optcaps rather than caps throughout, so one list serves every guest:
-- a capability this machine lacks is absent from the arg instead of a
-- reason to skip the entry.
local LIST = [[
return {
	{ path = "/task/ip.lua", capname = "ip", caps = { "eth" } },
	{ path = "/task/tcp4.lua", capname = "tcp", caps = { "ip" } },
	{ path = "/task/dhcpd.lua", capname = "dhcpd", caps = { "ip" } },
	{ from = "dhcpd", mount = "/net" },
	-- names, so a payload may reach a host by one. ns = false for the
	-- reason machine/*/services.lua gives: it opens no file.
	{ path = "/task/dns.lua", caps = { "ip", "dhcpd" }, ns = false },
	{ path = "/task/boottest.lua", name = "boottest",
	  optcaps = { "cons", "power", "disk", "esp", "flash", "blk",
	      "eth", "ip", "tcp", "dhcpd", "dns", "fb", "kbd", "ptr", "dbg",
	      "wire", "time", "sched" } },
}
]]

-- args(payload, opts) -> a list of qemu arguments.
--
-- opts.services  run under init, as above. false or absent replaces it.
-- opts.dir       a writable directory for the generated list.
-- opts.tools     where boottest-svc.lua lives.
function M.args(payload, opts)
	opts = opts or {}
	if not opts.services then
		return { "-fw_cfg",
		    "name=opt/org.luaos.test,file=" .. payload }
	end

	local path = assert(opts.dir, "fwcfg: services needs a dir") ..
	    "/services.lua"
	local f = assert(io.open(path, "w"))

	f:write(LIST)
	f:close()

	local tools = assert(opts.tools, "fwcfg: services needs tools")

	-- the payload travels under its own key rather than pasted into
	-- the wrapper, so no quoting question arises. Not the .test key:
	-- main.c would take that as a replacement for init before init
	-- ever ran.
	return {
	    "-fw_cfg", "name=opt/org.luaos.services,file=" .. path,
	    "-fw_cfg", "name=opt/org.luaos.svc/boottest.lua,file=" ..
	        tools .. "/boottest-svc.lua",
	    "-fw_cfg", "name=opt/org.luaos.testsrc,file=" .. payload,
	}
end

return M
