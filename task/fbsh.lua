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

-- lib/dos.lua is required further down, after the namespace is in
-- place. It is not in the esp32 image -- it lives on the filesystem
-- this shell runs programs from -- so requiring it up here searches the
-- image alone and the shell dies before its first prompt.
local sys = require("los.sys")
local thread = require("los.thread")
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

-- current, so require resolves through it: the shell and everything it
-- loads come off the same tree the programs do.
ns.setcurrent(N)

local dos = require("dos")

thread.spawn(function()
	local sh = dos.new({ ns = N, cons = cons, fb = fb,
	    net = job.net and job.net.__right,
	    power = job.power and job.power.__right })

	-- run the loop here rather than sh:repl, so a command's exit
	-- status is reported instead of discarded. A shell that drops it
	-- is the same fault as a console that drops a diagnostic.
	-- the terminal, watched. A shell must not outlive the terminal it
	-- prompts on -- it holds a whole lua state and a namespace, and
	-- nothing can ever reach it again -- and it cannot notice on its
	-- own: it is parked waiting for a line, and a reply that will
	-- never come looks exactly like a person who has not typed yet.
	if job.pid then
		sys.monitor(job.pid)
	end

	local function line()
		sys.send(cons, { op = "readline", prompt = "> ",
		    reply = { __right = thread.selfright() } })

		-- the exit notice arrives on this same port, which is the
		-- point of monitoring rather than polling.
		while true do
			local m = thread.recv(sys.SELF)

			if type(m) == "table" then
				if m.exit and m.exit == job.pid then
					return nil
				end
				-- something else's notice; a shell waits
				-- for a line, not for this
			else
				return m
			end
		end
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
