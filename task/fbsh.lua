-- fbsh: a dos shell on the framebuffer console.
--
-- Its own proc, not a thread of task/fbterm.lua: a shell waits on its
-- mailbox for the exit notice of each program it starts, and the
-- console serves on the mailbox of whichever proc runs it. One proc for
-- both makes two consumers of one port, and the console silently
-- consumes the notice the shell is waiting for.
--
-- Spawned with a message carrying its rights and the namespace to run
-- programs out of:
--	{ cons = {__right=}, fb = {__right=}, ns = }

local sys = require("los.sys")
local thread = require("los.thread")
local dos = require("dos")
local ns = require("ns")

local job = thread.recv(sys.SELF)
local cons = job.cons.__right
local fb = job.fb.__right

-- where programs come from: an unprivileged proc has no io.open, so a
-- namespace is the only path to a file.
--
-- The description handed down carries every mount the machine built,
-- which is the flash volume over the embedded image -- so /bin is
-- whatever was uploaded. Rebuilding it here by hand instead would find
-- only the image, and the image has no /bin.
local N, err

if job.ns then
	N, err = ns.restore(job.ns)
end
if not N then
	if err then
		sys.send(cons, { op = "write",
		    data = "fbsh: namespace: " .. tostring(err) .. "\n" })
	end
	N = ns.new()

	local ok, merr = N:mount("/", require("romfs").new(), "romfs")

	if not ok then
		sys.send(cons, { op = "write",
		    data = "fbsh: mount failed: " .. tostring(merr) .. "\n" })
	end
end

thread.spawn(function()
	local sh = dos.new({ ns = N, cons = cons, fb = fb,
	    net = job.net and job.net.__right })

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
