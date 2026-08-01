-- boot payload for `ninja qemu-microvm`. real filesystem still doesn't
-- exist (see fs.c), but the embed half of it does: lib/thread.lua,
-- lib/cons.lua and lib/stdout.lua are all embedded, so this boot
-- payload (proc 0, PRIV_BOOT) talks to the console the same way any
-- ordinary lua-os code does -- sys.granted().cons + print() -- rather
-- than the raw los.platform.cons only the cons task itself may reach.
--
-- proves the two things this milestone is actually about: the LAPIC
-- timer really preempts between procs (two children interleave their
-- output rather than one running to completion first), and the
-- existing kernel.c scheduler needed no changes to do it.

local sys = require("los.sys")
local stdout = require("stdout")

stdout.set(sys.granted().cons)

print("microvm: hello from the boot payload")

local myright = sys.sendright(0)

local childcode = [[
	local sys = require("los.sys")
	local parent = (...).__right
	for i = 1, 6 do
		sys.send(parent, string.format("child %d tick %d", sys.self(), i))
		sys.yield()
	end
]]

sys.spawn(childcode, { arg = { __right = myright } })
sys.spawn(childcode, { arg = { __right = myright } })

local got = 0
while got < 12 do
	local ok, msg = sys.tryrecv(0)
	if ok then
		print(msg)
		got = got + 1
	else
		sys.yield()
	end
end

print("microvm: both children finished")

-- cons/wire/power are real daemons now (embedded lib/cons.lua etc,
-- see fs.c) that block forever waiting for messages, so kernel_run()
-- has no reason to return on its own; ask power to end the guest
-- explicitly instead of relying on every proc dying.
sys.send(sys.granted().power, { op = "reset" })
