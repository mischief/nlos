-- bin/reboot.lua, run from the shell the way you would type it.
--
-- The point is the HANDOFF, not the reset: that power reaches a program
-- through the ABI message and nowhere else, that a shell given no power
-- hands out none, and that each flag names the mode the platform is
-- asked for.
--
-- The shell is given a port of this proc's own instead of the real
-- power task, so what the program sends arrives here and the machine
-- stays up. That is not a mock in the usual sense: a right is a right,
-- and the program cannot tell -- which is the property being relied on.
local sys = require("los.sys")
local dos = require("dos")
local ns = require("ns")
local thread = require("los.thread")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(9)

local N = ns.new()

N:mount("/", require("mnt").new(caps_of.esp), "mnt",
    { port = { __right = caps_of.esp } })

-- a stand-in console: collects what is written to it and never needs to
-- answer a read, because reboot asks for no input.
--
-- It runs until the stop message REACHES it, rather than until a flag
-- is set. The difference is not cosmetic: the program is a proc of its
-- own, so its writes are already queued on this port when it exits, and
-- a loop that tests a flag at the top returns without draining them.
local function console()
	local port = sys.newport()
	local out = {}

	local function serve()
		while true do
			local m = thread.recv(port)

			if m.op == "stop" then
				return
			elseif m.op == "write" then
				out[#out + 1] = m.data
			end
		end
	end

	return {
		right = sys.sendright(port),
		serve = serve,
		stop = function()
			sys.send(sys.sendright(port), { op = "stop" })
		end,
		drain = function()
			local s = table.concat(out)

			out = {}
			return s
		end,
	}
end

-- the stand-in power task: it collects, and it does not reset. Same
-- drain-to-the-sentinel rule as the console above, and for the same
-- reason -- the reset is the last thing the program sends before it
-- exits, so it is exactly the message a flag test would drop.
local function powersink()
	local port = sys.newport()
	local got = {}

	local function serve()
		while true do
			local m = thread.recv(port)

			if m.op == "stop" then
				return
			end
			got[#got + 1] = m
		end
	end

	return {
		right = sys.sendright(port),
		serve = serve,
		stop = function()
			sys.send(sys.sendright(port), { op = "stop" })
		end,
		msgs = got,
	}
end

-- one thread.run() drives the shell, the console and the power sink for
-- the length of the line, and both servers are stopped when the line is
-- done so that run() can return.
local function runline(sh, con, pwr, line)
	local status

	thread.spawn(con.serve)
	if pwr then
		thread.spawn(pwr.serve)
	end
	thread.spawn(function()
		status = sh:run(line)
		con.stop()
		if pwr then
			pwr.stop()
		end
	end)
	thread.run()
	return status
end

-- ---- with power ----

local con = console()
local pwr = powersink()
local sh = dos.new({ ns = N, cons = con.right, power = pwr.right })

tap.is(runline(sh, con, pwr, "reboot"), 0, "reboot ran and exited 0")
tap.ok(con.drain():find("rebooting"), "and said so")

-- the stall is what gives that line time to leave the uart, and it has
-- to be the first of the two: one mailbox, handled in order.
tap.is(#pwr.msgs, 2, "it sent two messages to the power task")
tap.is(pwr.msgs[1] and pwr.msgs[1].op, "stall", "the stall goes first")
tap.is(pwr.msgs[2] and pwr.msgs[2].op, "reset", "then the reset")
tap.is(pwr.msgs[2] and pwr.msgs[2].mode, "cold", "in cold mode by default")

-- ---- the other two modes ----

local con2 = console()
local pwr2 = powersink()
local sh2 = dos.new({ ns = N, cons = con2.right, power = pwr2.right })

runline(sh2, con2, pwr2, "reboot -p")
tap.is(pwr2.msgs[2] and pwr2.msgs[2].mode, "shutdown", "-p asks to power off")

-- ---- without power ----
--
-- the same program and the same shell code, a shell that was simply
-- never given the capability. Nothing is checked or probed for: it is
-- absent from the ABI message, so prog.power() returns nil.
local con3 = console()
local blind = dos.new({ ns = N, cons = con3.right })

tap.is(runline(blind, con3, nil, "reboot"), 1,
    "with no power granted, reboot exits 1")
tap.is(blind.power, nil, "a shell given no power holds none")

tap.done()
