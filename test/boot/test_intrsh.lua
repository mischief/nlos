-- the shell's half of the interrupt: claim it, hear it, kill the job.
--
-- test/boot/test_intr.lua covers the console's half. This is the other
-- end of the same wire: lib/dos.lua sends {op="intr"} carrying a right
-- when it starts a pipeline, waits on that right while the program
-- runs, and kills every stage when the console tells it. Nothing tested
-- any of the three.
--
-- Run twice, because a shell reads its notices from one of two places
-- and only one of them was ever exercised by hand. A shell in a proc of
-- its own takes them off sys.SELF; one sharing a proc with a console --
-- task/fbterm.lua, which is what a T-Deck runs -- is handed a port
-- instead and mints the right it gives the console from that. The two
-- paths meet in Sh:noticeright().
--
-- The job is a proc that parks forever, so "the interrupt worked" is
-- the shell returning at all rather than a timing guess.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local ns = require("ns")
local dos = require("dos")
local tap = require("tap")

tap.plan(3)

local SLEEPER = [[
local sys = require("los.sys")
sys.block(sys.newport("sleeper.wait"))
]]

-- this proc's own namespace with one program added over it, in plan 9's
-- union order: the mem mount is searched first, and what was already
-- there is where a spawned program finds /lib.
--
-- No kind, so it is not inheritable: the shell reads the program here
-- and spawns its source, and the child wants the real /lib rather than
-- a tree holding one file.
local N = ns.current() or ns.new()

tap.ok(N:mount("/", dev.mem({ bin = { ["sleeper.lua"] = SLEEPER } })),
    "a namespace holding one program that never exits")

-- one round, inside the scheduler. Returns the exit status run() came
-- back with, or nil plus how far it got.
local function round(notices)
	local cons = sys.newport("test_intrsh.cons")
	local consh = sys.sendright(cons)
	local donep = sys.newport("test_intrsh.done")
	local doneh = sys.sendright(donep)
	local sh = dos.new({ ns = N, cons = consh, notices = notices })
	local stopfwd = false

	-- sys.monitor delivers to the proc's own port whoever asked, so a
	-- shell reading its notices elsewhere only sees an exit because
	-- something forwards. In task/fbterm.lua that is the console's
	-- `other` hook; here it is this.
	if notices then
		local nsend = sys.sendright(notices)

		thread.spawn(function()
			while not stopfwd do
				local m = thread.recvtimeout(sys.SELF, 100)

				if m ~= nil then
					sys.send(nsend, m)
				end
			end
			sys.close(nsend)
		end)
	end

	thread.spawn(function()
		local st = sh:run("sleeper")

		-- a table, so "returned nil" and "never returned" stay apart
		sys.send(doneh, { status = st or 0 })
	end)

	-- play the console: drain what the shell writes, and keep the
	-- right that arrives with the claim.
	local claim
	local deadline = sys.uptime_ms() + 5000

	while not claim and sys.uptime_ms() < deadline do
		local m = thread.recvtimeout(cons, 200)

		if type(m) == "table" and m.op == "intr" and m.reply then
			claim = m.reply.__right
		end
	end
	if not claim then
		stopfwd = true
		return nil, "never claimed the interrupt"
	end

	-- what the console's pump does when the character arrives
	sys.send(claim, { op = "interrupt" })

	local r = thread.recvtimeout(donep, 5000)

	stopfwd = true
	if type(r) ~= "table" then
		return nil, "claimed it, but never returned"
	end
	return r.status
end

thread.spawn(function()
	-- ---- a shell in a proc of its own: notices on sys.SELF ----
	local a, aerr = round(nil)

	tap.ok(a ~= nil,
	    "sys.SELF: " .. (a and "killed the job and returned" or aerr))

	-- ---- a shell sharing a proc with a console: notices on a port ----
	--
	-- Nothing forwards here, because the claim right IS that port.
	-- What is checked is that the shell listens where it said it would.
	local b, berr = round(sys.newport("test_intrsh.notices"))

	tap.ok(b ~= nil,
	    "a notices port: " .. (b and "killed the job and returned" or berr))
end)

thread.run()

-- a killed proc is held as a corpse until something reaps it, and
-- sys.procs lists corpses, so this counts rather than asserts.
local left = 0

for _, pid in ipairs(sys.procs()) do
	if sys.name(pid):match("sleeper") then
		left = left + 1
	end
end
tap.diag(("sleeper procs left: %d"):format(left))

tap.done()
