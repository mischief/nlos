-- fbsh: a dos shell on the console of the proc it runs in.
--
-- A thread of task/fbterm.lua rather than a proc of its own, because a
-- proc of its own loads a second copy of the whole namespace stack --
-- ns, chan, mnt, nsio, romfs, dos, prog -- which is most of what a shell
-- weighs.
--
-- The console owns the proc's mailbox and forwards what is not tty
-- traffic (lib/console.lua's `other`), so the exit notices this shell
-- waits for arrive on a port of its own.
--
-- run() takes:
--	cons		a send right to the console (this proc's port)
--	notices		a receive port carrying the console's leftovers
--	ns		the namespace to run programs out of
--	fb, net, udp, power	lent to every program, where the terminal has them

local sys = require("los.sys")
local thread = require("los.thread")
local dos = require("dos")

local M = {}

function M.run(o)
	local sh = dos.new({
		ns = o.ns, cons = o.cons, fb = o.fb,
		net = o.net, udp = o.udp, power = o.power,
		notices = o.notices,
	})

	-- the line comes back on this thread's own reply port, not on the
	-- proc's: the console reading the mailbox is a thread of this same
	-- proc, and a reply addressed to the mailbox would be taken by the
	-- console rather than by whoever asked.
	-- thread.readline, not thread.rpc: rpc waits with thread.await,
	-- which gives up when sys.hungup finds no other holder of the reply
	-- port -- and the console answering is a thread of this same proc,
	-- so the proc holds both ends and hungup is true before the reply
	-- can arrive. readline waits with a plain recv.
	--
	-- nil is end of input, and ends this loop.
	local function line()
		return thread.readline(o.cons, "> ")
	end

	-- the loop rather than sh:repl, so a command's exit status is
	-- reported instead of discarded. A shell that drops it is the same
	-- fault as a console that drops a diagnostic.
	local sok, serr = xpcall(function()
		while true do
			local l = line()

			if l == nil then
				return
			end
			if #l > 0 then
				local st, msg = sh:run(l)

				if msg then
					sys.send(o.cons, { op = "write",
					    data = tostring(msg) .. "\n" })
				end
				if st and st ~= 0 then
					sys.send(o.cons, { op = "write",
					    data = ("[status %d]\n")
					    :format(st) })
					print("fbsh: " .. l ..
					    " exited " .. tostring(st))
				end
			end
		end
	end, debug.traceback)

	if not sok then
		sys.send(o.cons, { op = "write",
		    data = "fbsh: " .. tostring(serr) .. "\n" })
		print("fbsh: " .. tostring(serr))
	end
end

return M
