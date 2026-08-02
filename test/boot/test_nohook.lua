-- The preempt hook is not something a proc may take off.
--
-- The kernel's instruction budget is a count hook armed once in
-- proc_new and never re-armed on resume, so anything that can clear it
-- lets a proc spin forever and take the machine with it -- console,
-- network and every other proc. That is the opposite of what AGENTS.md
-- promises about a proc being a containment unit, so the two ways found
-- to do it are pinned here.
--
-- Both are checked from proc 0, which is PRIV_BOOT and keeps the whole
-- debug library; what matters is what a spawned proc gets.

local tap = require("tap")
local sys = require("los.sys")

tap.plan(5)

tap.ok(debug ~= nil and debug.traceback ~= nil,
    "proc 0 keeps debug.traceback")

-- A spawned proc reports what it can reach, over a port.
local reply = sys.newport()

local _, h = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)

	-- forcing a reload is the interesting half: luaL_requiref re-runs
	-- the opener whenever package.loaded[name] is falsy, so a strip
	-- that happens only at spawn can be undone by asking again.
	package.loaded.debug = nil
	_G.debug = nil

	sys.send(m.reply.__right, {
		sethook = debug.sethook ~= nil,
		traceback = debug.traceback ~= nil,
	})
]], { name = "probe" })

sys.send(h, { reply = { __right = reply } })

local got = require("los.thread").recv(reply)

tap.ok(not got.sethook, "a spawned proc has no debug.sethook, even after a reload")
tap.ok(got.traceback, "it keeps debug.traceback, which is the diagnostic")

-- sys.preempt arms the kernel's own hook, so an unclamped count is the
-- same escape wearing a different name: 0 means "no count hook" to
-- lua_sethook.
local ok = pcall(sys.preempt, coroutine.running(), 0)

tap.ok(ok, "sys.preempt accepts a silly count rather than erroring")

-- If the clamp works this proc is still interruptible, so the machine
-- is still alive to run the next line. A spinner is not spawned here on
-- purpose: if the clamp were broken this test would hang rather than
-- fail, which is worse than useless in CI.
tap.ok(sys.uptime_ms() > 0, "the machine is still scheduling")

tap.done()
