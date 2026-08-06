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

	-- run the loop here rather than sh:repl, so a command's exit
	-- status is reported instead of discarded. A shell that drops it
	-- is the same fault as a console that drops a diagnostic.
	local function line()
		sys.send(cons, { op = "readline", prompt = "> ",
		    reply = { __right = sys.SELF } })
		return thread.recv(sys.SELF)
	end
	local sok, serr = xpcall(function()
		while true do
			local l = line()

			if l == nil then
				return
			end
			if #l > 0 then
				local st, msg = sh:run(l)

				if msg then
					sys.send(cons, { op = "write",
					    data = tostring(msg) .. "\n" })
				end
				if st and st ~= 0 then
					sys.send(cons, { op = "write",
					    data = ("[status %d]\n")
					    :format(st) })
					print("fbsh: " .. l ..
					    " exited " .. tostring(st))
				end
			end
		end
	end, debug.traceback)

	if not sok then
		sys.send(cons, { op = "write",
		    data = "fbsh: " .. tostring(serr) .. "\n" })
		print("fbsh: " .. tostring(serr))
	end
end)

thread.run()
