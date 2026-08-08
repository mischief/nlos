-- the interrupt character, from the keyboard to whoever claimed it.
--
-- A program that has stopped reading is exactly the program you want to
-- stop, so the console watches the keyboard even when nothing is asking
-- it for input. What it does with the character is the whole mechanism:
-- a shell claims the interrupt while a program it started runs
-- ({op="intr"} carrying a right), the console tells that right when the
-- character arrives, and the shell kills what it spawned.
--
-- Both halves matter and they pull opposite ways. Claimed, the
-- character must reach the claimant and must NOT also reach the input,
-- or the program being stopped reads the byte that stopped it.
-- Released, it must do the reverse: no interrupt to a claimant that no
-- longer exists, and the byte is ordinary input.
--
-- Driven through the real lib/console.lua with a port standing in for a
-- keyboard, which is all a backend owes it.

local sys = require("los.sys")
local thread = require("los.thread")
local console = require("console")
local tap = require("tap")

tap.plan(6)

local kbd = sys.newport("test_intr.kbd")
local kbdh = sys.sendright(kbd)
local claim = sys.newport("test_intr.claim")
local claimh = sys.sendright(claim)
local reply = sys.newport("test_intr.reply")
local replyh = sys.sendright(reply)

-- the console serves on this proc's own port, as it does everywhere.
local consh = thread.selfright()

tap.ok(kbd and claim and reply, "ports for a keyboard and two replies")

local con = console.new({
	write = function() end,		-- the glass is not the subject here
	keyport = kbd,
})

thread.spawn(function()
	con:serve()
end)

-- a getch that gives up, so "nothing arrived" is an answer rather than
-- a hang. "" is what the console returns on a timeout; nil would be
-- indistinguishable from a dropped reply.
local function getch(ms)
	sys.send(consh, { op = "getch", timeout = ms,
	    reply = { __right = replyh } })
	return thread.recvtimeout(reply, ms + 500)
end

thread.spawn(function()
	-- ---- claimed, as a shell does while a program runs ----
	sys.send(consh, { op = "intr", reply = { __right = claimh } })
	thread.sleep(20)

	sys.send(kbdh, "\3")

	local m = thread.recvtimeout(claim, 1000)

	tap.ok(type(m) == "table" and m.op == "interrupt",
	    "a claimed interrupt reaches the claimant")
	tap.is(getch(100), "",
	    "and does not also arrive as input")

	-- ---- released, as a shell does when nothing is running ----
	sys.send(consh, { op = "intr" })	-- no reply: nobody is listening
	thread.sleep(20)

	sys.send(kbdh, "\3")
	tap.ok(thread.recvtimeout(claim, 200) == nil,
	    "an unclaimed interrupt goes to nobody")
	tap.is(getch(500), "\3",
	    "and is ordinary input instead")

	-- ---- claimed while the console is already serving a read ----
	--
	-- The order a shell actually produces: it starts the program, the
	-- program asks for input, and the claim lands while the console is
	-- inside that read. Deferring the claim until the read finishes
	-- leaves the interrupt unclaimed for exactly as long as the program
	-- runs, which for a pager is forever -- and the character meant to
	-- stop it is delivered to it as input instead.
	sys.send(consh, { op = "read", reply = { __right = replyh } })
	thread.sleep(20)			-- the console is in readline now
	sys.send(consh, { op = "intr", reply = { __right = claimh } })
	thread.sleep(20)

	sys.send(kbdh, "\3")
	tap.ok(type(thread.recvtimeout(claim, 1000)) == "table",
	    "a claim made mid-read takes effect at once")

	tap.done()
	os.exit(0)
end)

thread.run()
