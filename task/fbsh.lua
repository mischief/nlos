-- fbsh: a dos shell on the framebuffer console.
--
-- Its own proc, not a thread of task/fbterm.lua: a shell waits on its
-- mailbox for the exit notice of each program it starts, and the
-- console serves on the mailbox of whichever proc runs it. One proc for
-- both makes two consumers of one port, and the console silently
-- consumes the notice the shell is waiting for.
--
-- Spawned with a message carrying its rights:
--	{ cons = {__right=}, fb = {__right=} }

local sys = require("los.sys")
local thread = require("los.thread")
local dos = require("dos")
local ns = require("ns")

local job = thread.recv(sys.SELF)
local cons = job.cons.__right
local fb = job.fb.__right

-- read-only over the embedded image: an unprivileged proc has no
-- io.open, so this is where programs come from. See lib/romfs.lua.
local N = ns.new()
local ok, err = N:mount("/", require("romfs").new(), "romfs")

if not ok then
	sys.send(cons, { op = "write",
	    data = "fbsh: mount failed: " .. tostring(err) .. "\n" })
end

thread.spawn(function()
	local sh = dos.new({ ns = N, cons = cons, fb = fb })
	local sok, serr = xpcall(function()
		sh:repl("")
	end, debug.traceback)

	if not sok then
		sys.send(cons, { op = "write",
		    data = "fbsh: " .. tostring(serr) .. "\n" })
		print("fbsh: " .. tostring(serr))
	end
end)

thread.run()
