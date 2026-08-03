-- thread.readline: two threads asking for a line at the same time.
--
-- readline is a request/reply against cons, and the reply has to come
-- back somewhere. That somewhere used to be one port per PROC, which is
-- fine while a proc asks for one line at a time and wrong the moment
-- two of its threads ask together: both send the same right, both read
-- from it, and whichever thread the scheduler happens to wake takes
-- whichever line arrived. lib/webterm.lua serves a console per session
-- out of one proc, which is exactly that shape -- a line typed into one
-- browser tab surfacing in another.
--
-- The crossing is forced here rather than waited for. The two requests
-- are made in a known order, and the fake cons answers them in the
-- REVERSE order, so a shared port has the wrong line sitting on it at
-- the moment the first thread looks. With a port per thread the order
-- replies are sent in cannot matter, which is the property being
-- pinned.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(4)

local cons = sys.newport()
local consh = sys.sendright(cons)

tap.ok(cons and consh, "a port to play cons on")

-- the fake cons: collect both requests, then answer the second one
-- first.
thread.spawn(function()
	local req = {}

	while #req < 2 do
		local m = thread.recv(cons)

		if m.op == "readline" then
			req[#req + 1] = m.reply.__right
		end
	end
	sys.send(req[2], "second\n")
	sys.send(req[1], "first\n")
end)

-- first and second are made in that order: the handshake channel is
-- what makes "first" mean something.
local go = thread.chancreate(0)
local gotA, gotB

thread.spawn(function()
	local line = thread.readline(consh)	-- request 1

	gotA = line
end)

thread.spawn(function()
	go:recv()
	gotB = thread.readline(consh)		-- request 2
end)

-- let A get its request out before B sends one. A parks in recv()
-- immediately afterwards, so by the time this runs the order is fixed.
thread.spawn(function()
	go:send(true)
end)

thread.run()

tap.is(gotA, "first\n", "the first asker got the first line")
tap.is(gotB, "second\n", "and the second asker got the second")
tap.ok(gotA ~= gotB, "the two lines did not cross")

tap.done()
