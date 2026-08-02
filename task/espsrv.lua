-- espsrv: the ESP, served on a port. the last piece of ambient
-- authority becoming a capability.
--
-- espfs was always a plain backend, and its own header said this was
-- coming: "making it an exclusive task that owns the esp outright -- so
-- no other proc holds the disk capability at all, and enumeration stops
-- being ambient -- is a refinement worth doing later, and it needs no
-- change here: the same eight methods move behind a port."
--
-- that turned out to be exactly true. this file is the whole of it,
-- because lib/srv.lua already serves any dev backend and lib/mnt.lua
-- already is one.
--
-- ---- what this buys ----
--
-- los.fs stops being preloaded everywhere. it is registered for this
-- task alone (PRIV_ESP in kernel.c), the same way los.platform.cons
-- belongs only to the console task -- absent rather than checked. so
-- there is exactly one proc in the system that can reach the ESP
-- directly, and it is this one.
--
-- everything else gets the ESP as a MOUNT: a right, granted by being
-- sent, appearing in sys.granted() as `esp`. proc 0 mounts it at / and
-- describes it to its children, and the right travels with the
-- description -- so a child inherits access to the ESP the same way it
-- inherits anything else, and a child that is handed a namespace
-- without it simply cannot reach the disk.
--
-- before this, ns.restore rebuilt an "espfs" mount in the child by
-- instantiating the driver there, which meant every proc needed los.fs
-- and the mount was a recipe rather than a capability. see lib/mnt.lua
-- on why that distinction is the whole point.
--
-- ---- the disk capability ----
--
-- the kernel grants this task a right to diskport at handle 1, which is
-- what libc/stdio.c's fopen and los.fs.open test for. so WRITES to the
-- esp are possible in this proc and nowhere else, and a write arriving
-- over the port has already been authorised by the sender holding a
-- right to this server at all.

local espfs = require("espfs")
local srv = require("srv")

srv.main(function()
	return espfs.new("/")
end)
