-- per-proc port budgets: a runaway costs its own proc first.
--
-- Ports are one machine-wide table, so a proc looping on sys.newport
-- starves every other -- and it need not be its own loop. lib/srv.lua
-- mints a port per session on demand, so a client calling `session` in
-- a loop spends the SERVER's budget. A per-server quota cannot answer
-- that: a port carries no sender identity, so a server cannot tell
-- whose request it is holding and cannot charge anyone for it. A
-- per-proc cap can, because the proc that asks is the proc that pays.
--
-- Inherited and clamped like opts.mem, and unlimited by default, so
-- nothing gets a budget it was not given one.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(13)

-- ---- the cap itself ----

local CAP = 8
local back = sys.sendright(sys.SELF)

local _, h = sys.spawn([[
	local sys = require("los.sys")
	local a = ...
	local out = a.reply.__right
	local held = {}
	local err

	while true do
		local ok, h = pcall(sys.newport)

		if not ok then
			err = tostring(h)
			break
		end
		held[#held + 1] = h
	end

	local st = sys.pidstat()

	-- give one back and take it again: the budget is what is held,
	-- not what has ever been made
	sys.close(held[#held])
	local reuse = pcall(sys.newport)

	sys.send(out, { made = #held, err = err, reuse = reuse,
	    ports = st.ports, limit = st.portlimit, peak = st.portspeak })
]], { name = "greedy", ports = CAP, arg = { reply = { __right = back } } })

local m = thread.recv(sys.SELF)

tap.is(m.made, CAP, "a proc makes exactly its budget of ports")
tap.ok(m.err:find("port limit"), "then is refused: " .. m.err)
tap.is(m.limit, CAP, "pidstat reports the cap")
tap.is(m.ports, CAP, "and what is held against it")
tap.ok(m.reuse, "a port given back can be taken again")
sys.close(h)

-- ---- inheritance, the same rule as opts.mem ----

local _, h2 = sys.spawn([[
	local sys = require("los.sys")
	local a = ...
	local out = a.reply.__right

	-- ask for far more than we hold, and for nothing at all
	local greedy = sys.spawn("", { ports = 4096 })
	local silent = sys.spawn("")

	sys.send(out, { mine = sys.pidstat().portlimit,
	    greedy = sys.pidstat(greedy).portlimit,
	    silent = sys.pidstat(silent).portlimit })
]], { name = "parent", ports = CAP, arg = { reply = { __right = back } } })

local i = thread.recv(sys.SELF)

tap.is(i.mine, CAP, "a child gets the cap it asked for")
tap.is(i.greedy, CAP, "its own child cannot ask for a larger one")
tap.is(i.silent, CAP, "and inherits it when it asks for nothing")
sys.close(h2)

-- ---- a timer is a port, and is charged like one ----

local _, h3 = sys.spawn([[
	local sys = require("los.sys")
	local a = ...
	local out = a.reply.__right
	local n = 0

	-- sys.timer REPORTS failure by returning nothing rather than
	-- raising, so the handle is the test, not the pcall
	while true do
		local ok, h = pcall(sys.timer, 60000)

		if not ok or not h then
			break
		end
		n = n + 1
	end
	sys.send(out, { timers = n, ports = sys.pidstat().ports })
]], { name = "timers", ports = 3, arg = { reply = { __right = back } } })

local t = thread.recv(sys.SELF)

tap.ok(t.timers <= 3, "timers come out of the same budget (" ..
    tostring(t.timers) .. " of 3)")
sys.close(h3)

-- ---- the case this exists for: a client spending a server's budget ----
--
-- srv's establishment port answers `session` by minting a port and a
-- serve thread, so an unbounded caller is an unbounded cost to the
-- server. Capped, the server refuses -- dispatch's pcall turns the
-- raise into an error reply -- and goes on serving the sessions it
-- already has, rather than taking the machine's port table with it.

local SRV = [[
local dev = require("dev")
local srv = require("srv")

srv.main(function()
	return dev.mem({ a = "alpha\n" })
end)
]]

local spid, sh = sys.spawn(SRV, { name = "capped-srv", ports = 4 })
local rp, rsend = thread.replyport()
local got, refused = 0, nil

for _ = 1, 12 do
	sys.send(sh, { op = "session", reply = { __right = rsend } })

	local r = thread.recv(rp)

	if type(r) == "table" and r.port then
		got = got + 1
	else
		refused = r and tostring(r.err) or "?"
		break
	end
end

tap.ok(refused ~= nil, "the server refuses past its budget: " ..
    tostring(refused))
tap.ok(got > 0 and got <= 4,
    "after handing out what it had (" .. got .. " sessions)")

sys.close(sh)

-- ---- and the default is unlimited ----

tap.is(sys.pidstat().portlimit, 0, "an uncapped proc reports no limit")
tap.ok(sys.pidstat().ports >= 0, "but its ports are still counted")

sys.close(back)
tap.done()
