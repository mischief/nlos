-- The confinement of a non-boot proc, held at the debug library and the
-- chunk loader. proc 0 is PRIV_BOOT and keeps everything; every child it
-- spawns is PRIV_NONE, and proc_new (src/kernel.c) confines those. This
-- spawns such a child and has it try, with only what the kernel left it,
-- to reach past the boundary. Each attempt must fail.
--
-- What each attempt would reach if it did not:
--
--  * debug.getupvalue / setupvalue on a los.sys function. Every entry is
--    a C closure built by counted(): upvalue 1 is the kernel's own
--    lua_CFunction as a light userdata, upvalue 2 an index into
--    kproc.calls. getupvalue leaks that pointer; setupvalue swaps it to
--    redirect the syscall, or drives the index out of bounds.
--  * debug.setmetatable to forge a los.owned right onto any userdata.
--  * debug.getregistry to reach the registry.
--  * load(bytes, name, "b") to reach luaU_undump, the unverified
--    bytecode loader, with a crafted chunk -- a kernel-heap corruption
--    primitive. string.dump is the usual way to make such a chunk.
--
--  * collectgarbage("restart") to re-arm the collector the kernel stops
--    per proc, so finalizers fire mid-allocation. This one is not
--    removed but replaced, for every proc including boot: the kernel
--    collectgarbage ignores its argument and does a safe full collect,
--    so a caller still collects but cannot restart.
--
-- What must remain: debug.traceback and debug.getinfo, the read-only
-- diagnostics the repl and lib/thread need, and load() of source.

local sys = require("los.sys")
local tap = require("tap")

tap.plan(11)

-- the kernel collectgarbage ignores its verb. Stock collectgarbage("count")
-- returns a memory figure; this one returns 0, which is how a proc can
-- tell it is the replacement, so "restart" is inert here too.
tap.ok(type(collectgarbage) == "function" and collectgarbage("count") == 0,
    "boot collectgarbage is the kernel replacement (verb ignored)")

local myright = sys.sendright(0)

local child = [[
	local sys = require("los.sys")
	local parent = (...).__right

	local function rep(k, v)
		sys.send(parent, k .. "\t" .. tostring(v))
	end

	rep("getupvalue", debug.getupvalue)
	rep("setupvalue", debug.setupvalue)
	rep("setmetatable", debug.setmetatable)
	rep("getregistry", debug.getregistry)
	rep("traceback", type(debug.traceback))
	rep("getinfo", type(debug.getinfo))
	rep("dump", string.dump)

	-- the dangerous verb. The replacement ignores it and returns 0
	-- rather than re-arming the collector, the same as any other verb.
	rep("cg_restart", collectgarbage("restart"))
	rep("cg_count", collectgarbage("count"))

	-- a binary chunk, offered as binary. mode is forced to text, so
	-- the loader refuses it rather than undumping it.
	local f = load("\27Lua rest is nonsense", "=x", "b")
	rep("loadb", f)

	-- source still loads and runs.
	local g = load("return 7", "=y")
	rep("loadt", g and g())
]]

sys.spawn(child, { arg = { __right = myright } })

local got = {}
local want = { "getupvalue", "setmetatable", "traceback", "dump",
    "loadb", "loadt", "cg_restart", "cg_count" }

local function have_all()
	for _, k in ipairs(want) do
		if got[k] == nil then return false end
	end
	return true
end

while not have_all() do
	local rcv, msg = sys.tryrecv(0)
	if rcv then
		local k, v = msg:match("^([^\t]+)\t(.*)$")
		got[k] = v
	else
		sys.yield()
	end
end

tap.ok(got.getupvalue == "nil", "debug.getupvalue is gone (no pointer leak)")
tap.ok(got.setupvalue == "nil", "debug.setupvalue is gone (no syscall hijack)")
tap.ok(got.setmetatable == "nil", "debug.setmetatable is gone (no right forgery)")
tap.ok(got.getregistry == "nil", "debug.getregistry is gone")
tap.ok(got.dump == "nil", "string.dump is gone")
tap.ok(got.loadb == "nil", "load() refuses a binary chunk (mode forced to text)")
tap.ok(got.cg_restart == "0" and got.cg_count == "0",
    "collectgarbage ignores its verb (restart is inert, verb-less collect)")

tap.ok(got.traceback == "function", "debug.traceback stays for diagnostics")
tap.ok(got.getinfo == "function", "debug.getinfo stays for diagnostics")
tap.ok(got.loadt == "7", "load() of source still works")

tap.done()
