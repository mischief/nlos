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
-- What is counted is what a proc HOLDS -- its receive rights -- not
-- what it made. That is unix's rule for RLIMIT_NOFILE, it needs no
-- record of who created which port, and it is the honest measure: a
-- port nobody holds a right to is freed, so holding is what keeps the
-- table full. A right handed to another proc becomes that proc's cost,
-- which the last case here shows.
--
-- Handle 0 counts, exactly as fds 0-2 count against RLIMIT_NOFILE, so a
-- cap of N leaves N-1 for sys.newport.
--
-- Inherited and clamped like opts.mem, and unlimited by default, so
-- nothing gets a budget it was not given one.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(15)

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
		local ok, h = pcall(sys.newport, "portlimit")

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
	local reuse = pcall(sys.newport, "portlimit")

	sys.send(out, { made = #held, err = err, reuse = reuse,
	    ports = st.ports, limit = st.portlimit, peak = st.portspeak })
]], { name = "greedy", ports = CAP, arg = { reply = { __right = back } } })

local m = thread.recv(sys.SELF)

tap.is(m.made, CAP - 1,
    "a proc makes its budget of ports, less handle 0")
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

tap.is(t.timers, 2, "timers come out of the same budget")
sys.close(h3)

-- ---- the holder pays, not the maker ----
--
-- the distinguishing case. this proc makes a port and sends a right to
-- it away; under creator-based accounting the cost would stay here,
-- and under hold-based it moves.

local _, h4 = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local a = ...
	local out = a.reply.__right
	local before = sys.pidstat().ports
	local m

	repeat
		m = thread.recv(sys.SELF)
	until type(m) == "table" and m.gift

	sys.send(out, { before = before, after = sys.pidstat().ports })
]], { name = "receiver", arg = { reply = { __right = back } } })

local gift = sys.newport("test_portlimit.")
local mine_before = sys.pidstat().ports

sys.send(h4, { gift = { __right = gift } })

local g = thread.recv(sys.SELF)

tap.is(g.after, g.before + 1, "a receive right costs the proc that gets it")
sys.close(gift)
tap.ok(sys.pidstat().ports < mine_before,
    "and closing ours gives it back here")
sys.close(h4)

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
-- 3, not 4: the server's own handle 0 is the fourth
tap.is(got, 3, "after handing out what it had")

sys.close(sh)

-- ---- and the default is unlimited ----

tap.is(sys.pidstat().portlimit, 0, "an uncapped proc reports no limit")
tap.ok(sys.pidstat().ports >= 0, "but its ports are still counted")

sys.close(back)
tap.done()
