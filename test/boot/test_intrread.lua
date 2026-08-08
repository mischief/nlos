-- an interrupt ends the read the console is sitting in.
--
-- The console reads on behalf of the program the shell started, so when
-- that program is interrupted the console is inside readline. Everything
-- else the mailbox holds is set aside there until the line ends -- and
-- the message that matters is the dying program's exit notice, which the
-- shell needs before it can print anything or take the prompt back.
--
-- A killed program never types the line that would release the console,
-- so nothing arrives until the next keystroke. On a panel that reads as
-- an interrupt that did nothing: the program stops, the screen does not
-- change, and pressing Enter makes the whole exchange appear at once.

local sys = require("los.sys")
local thread = require("los.thread")
local console = require("console")
local tap = require("tap")

tap.plan(4)

local kbd = sys.newport("test_intrread.kbd")
local kbdh = sys.sendright(kbd)
local claim = sys.newport("test_intrread.claim")
local claimh = sys.sendright(claim)
local reply = sys.newport("test_intrread.reply")
local replyh = sys.sendright(reply)
local consh = thread.selfright()

tap.ok(kbd and claim and reply, "ports for a keyboard and two replies")

local seen = {}
local con = console.new({
	write = function() end,
	keyport = kbd,
}, {
	other = function(m)
		seen[#seen + 1] = m
	end,
})

thread.spawn(function()
	con:serve()
end)

thread.spawn(function()
	-- the shell's shape: claim the interrupt, then the program it
	-- started asks the console for a line.
	sys.send(consh, { op = "intr", reply = { __right = claimh } })
	sys.send(consh, { op = "read", reply = { __right = replyh } })
	thread.sleep(50)

	-- the exit notice, arriving while the console is inside that read
	sys.send(consh, { exit = 99, normal = false })
	thread.sleep(50)
	tap.is(#seen, 0, "a mailbox message mid-read waits for serve")

	sys.send(kbdh, "\3")
	tap.ok(type(thread.recvtimeout(claim, 1000)) == "table",
	    "the interrupt reaches the claimant")

	-- no keystroke between the interrupt and this: the read has to
	-- have ended on its own for serve to reach the notice.
	local ok = false

	for _ = 1, 20 do
		if #seen > 0 then
			ok = true
			break
		end
		thread.sleep(50)
	end
	tap.ok(ok and seen[1].exit == 99,
	    "and the read ends, so what was waiting is served")

	tap.done()
	os.exit(0)
end)

thread.run()
