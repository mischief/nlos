-- top, run from the shell the way you would type it.
--
-- A full-screen program needs a terminal that answers, not a drain:
-- it asks the size before its first frame and reads a key after it.
-- So the console here serves in a thread, the way test_fbprog.lua's
-- does, and the whole exchange is what is under test -- a program that
-- asked and was not answered would hang here rather than fail.
local sys = require("los.sys")
local dos = require("dos")
local ns = require("ns")
local thread = require("los.thread")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(6)

local N = ns.new()

N:mount("/", require("mnt").new(caps_of.esp), "mnt",
    { port = { __right = caps_of.esp } })

-- 80x24, answered rather than left nil: a serial line answers nil and
-- top falls back, which is the other path and is not this one.
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
			elseif m.op == "size" then
				sys.send(m.reply.__right,
				    { cols = 80, rows = 24 })
			elseif m.op == "getch" then
				sys.send(m.reply.__right, "q")
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

local function runline(sh, con, line)
	local status

	thread.spawn(con.serve)
	thread.spawn(function()
		status = sh:run(line)
		con.stop()
	end)
	thread.run()
	return status
end

-- ---- one frame ----

local con = console()
local sh = dos.new({ ns = N, cons = con.right })

tap.is(runline(sh, con, "top -n 1"), 0, "top -n 1 ran and exited 0")

local out = con.drain()

tap.ok(out:find("PID NAME"), "it drew the process table")
tap.ok(out:find("procs="), "and the stats line above it")
tap.ok(out:find("q to quit"), "and the footer")

-- the terminal is given back: the cursor is shown again, and the escape
-- that hides it is not the last word on the screen. A program that
-- exits leaving it hidden has broken the shell that ran it.
tap.ok(out:find("\27%[%?25h"), "it showed the cursor again on the way out")

-- ---- q ends it ----
--
-- the console answers every getch with "q", so a run with no frame
-- limit still stops. Without that it would run until the harness gave
-- up, which is the failure this rules out.
local con2 = console()
local sh2 = dos.new({ ns = N, cons = con2.right })

tap.is(runline(sh2, con2, "top -d 1"), 0, "q quits a top with no -n")

tap.done()
