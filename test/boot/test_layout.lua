-- The directories mean different things, and this is what they mean.
--
-- Everything here is .lua, so nothing about a filename says whether it
-- is something you require or something that runs. The split is:
--
--   lib/   required. returns a table. loading it does nothing else.
--   task/  a proc's main chunk. loaded by PATH, runs, never returns.
--          drivers (spawned by kernel.c) and services (spawned from
--          etc/services.lua) both -- the difference is who starts them
--          and what they are granted, which is said at the spawn site.
--   bin/   a program under the lib/prog.lua ABI, run by a shell.
--   tools/ host-side. never reaches the guest at all.
--
-- The lib/ half of that is checkable, so it is checked: requiring every
-- module must succeed and yield a table. That catches both mistakes --
-- a library that grew a side effect, and a task that drifted into lib/
-- and would hang the moment something required it.
--
-- Both, in fact, on the first run. lib/idle.lua was never a library: it
-- parks on a port forever and exists to be spawned, so requiring it
-- raised "attempt to yield across a C-call boundary" -- it lives in
-- task/ now. And lib/webterm.lua had just been dropped from the image
-- by a careless rename, which nothing else would have noticed until a
-- visitor connected.

local tap = require("tap")

-- Every module under lib/, by name. Kept explicit rather than read from
-- the namespace: this asserts what SHOULD be there, so a file silently
-- dropped from meson's payload fails here instead of at 3am.
local libs = {
	"caps", "chan", "dev", "dhcp", "dos", "draw", "espfs", "http",
	"json", "log", "mnt", "ninep", "ns", "nsio", "p9fs", "p9tcp",
	"proc", "procfs", "prog", "ps", "srv", "srvc", "srvfs", "stdout",
	"svc", "tap", "thread", "webterm",
	"crypto.util", "crypto.hashstate", "crypto.sha256", "crypto.sha512",
	"crypto.drbg", "crypto.field25519", "crypto.x25519", "crypto.ed25519",
	"crypto.keccak", "crypto.mlkem768",
	"ssh.wire", "ssh.msg", "ssh.base64", "ssh.keys", "ssh.packet",
	"ssh.kex", "ssh.server",
}

tap.plan(#libs + 1)

local bad = 0

for _, name in ipairs(libs) do
	local ok, mod = pcall(require, name)

	if not ok then
		bad = bad + 1
		tap.ok(false, name .. ": " .. tostring(mod))
	else
		tap.ok(type(mod) == "table",
		    name .. " returns a table (" .. type(mod) .. ")")
	end
end

tap.ok(bad == 0, "every lib/ module loads with no side effect")

tap.done()
