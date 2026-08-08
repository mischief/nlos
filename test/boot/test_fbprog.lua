-- a graphical program, run from the shell the way you would type it.
--
-- the point of the test is the HANDOFF, not the drawing: that the screen
-- reaches a program through the ABI message and nowhere else, that a
-- shell given no screen hands out none, and that a program which took
-- the screen has really given it back by the time the prompt returns.
--
-- test/boot/test_fb.lua already proves pixels land where asked. this one
-- proves the capability travels init -> shell -> program.
local sys = require("los.sys")
local capfb = require("caps.fb")
local draw = require("draw")
local dos = require("dos")
local ns = require("ns")
local thread = require("los.thread")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(7)

tap.ok(caps_of.fb ~= nil, "boot payload holds the screen")
if not caps_of.fb then
	tap.done()
	return
end

local N = ns.new()

N:mount("/", require("mnt").new(caps_of.esp), "mnt",
    { port = { __right = caps_of.esp } })

-- a stand-in console: collects what is written to it, and ANSWERS
-- reads, because smiley waits on stdin before it will give the screen
-- back. that wait is the behaviour under test rather than an
-- inconvenience -- a program that took the screen keeps it until it is
-- done.
--
-- it is a thread, not a passive drain like test_prog.lua's, because a
-- terminal has to reply while the program is still running. that makes
-- the shape below necessary: thread.run() returns only when every
-- thread is dead, so a console loop that never ends would hang the
-- whole test rather than fail it. it stops when the line is done.
local function console(feed)
	local port = sys.newport("test_fbprog")
	local out = {}
	local done = false

	local function serve()
		while not done do
			local m = thread.recv(port)

			if m.op == "write" then
				out[#out + 1] = m.data
			elseif m.op == "read" then
				sys.send(m.reply.__right, feed or "\n")
			elseif m.op == "stop" then
				return
			end
		end
	end

	return {
		right = sys.sendright(port),
		serve = serve,
		stop = function()
			done = true
			-- unblock the recv it is parked in
			sys.send(sys.sendright(port), { op = "stop" })
		end,
		drain = function()
			local s = table.concat(out)

			out = {}
			return s
		end,
	}
end

-- dos.once, plus the console server running alongside for the duration
-- of the line. one thread.run() drives both, and the console is stopped
-- when the line finishes so that run() can return.
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

-- ---- with a screen ----

local con = console()
local sh = dos.new({ ns = N, cons = con.right, fb = caps_of.fb })

local status = runline(sh, con, "smiley")

local outtext = con.drain()

tap.is(status, 0, "smiley ran and exited 0")
tap.ok(outtext:find("press enter"),
    "it prompted before giving the screen back")

-- it painted the screen black on the way out, which is the restore step.
-- sampling the middle is deliberate: that is where the face was, so a
-- program that drew and skipped the restore fails here.
local fb = capfb.new(caps_of.fb)
local mode = fb.mode()
local mid = draw.fromBytes(1, 1,
    fb.unload(draw.rect(mode.w // 2, mode.h // 2, 1, 1)))

tap.is(draw.at(mid, 0, 0), 0x000000,
    "the screen was restored when the program exited")

-- ---- without one ----
--
-- the same program, the same shell code, a shell that was simply never
-- given a screen. nothing is checked or probed for: the capability is
-- absent from the message, so prog.screen() returns nil.
local con2 = console()
local blind = dos.new({ ns = N, cons = con2.right })

tap.is(runline(blind, con2, "smiley"), 1,
    "with no screen granted, smiley exits 1")
tap.ok(con2.drain():find("no framebuffer"), "and says why")

-- and the shell that never had one cannot have leaked it
tap.is(blind.fb, nil, "a shell given no screen holds no screen")

tap.done()
