-- lib/p9fs.lua over a STREAM transport: one channel, replies routed by
-- tag rather than by position.
--
-- The routed shape (los.platform.p9, and the loopback in
-- test_ninep_selfmount.lua) hands back the reply to the request it was
-- given, so p9fs never has to match anything and its tag is only an
-- assertion. A byte stream cannot do that: several requests are out on
-- one connection and the server answers in whatever order it likes. So
-- p9fs keeps tag -> waiter itself, and this is the test of that.
--
-- The transport here answers OUT OF ORDER on purpose -- it holds
-- replies back and releases them reversed. In-order delivery would pass
-- with no mux at all, which is exactly the bug this has to be able to
-- fail on.
--
-- Everything runs inside one thread.run(). p9fs.new spawns a reader
-- thread that lives as long as the connection, so thread.run() does not
-- return until the transport says the connection is over -- which is
-- what close() below is for, and what a real transport gets for free
-- when the socket does.

local ninep = require("ninep")
local p9fs = require("p9fs")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(6)

local tree = ninep.synth({
	["hello.txt"] = "hello from a stream\n",
	["a.bin"] = string.rep("A", 3000),
	["b.bin"] = string.rep("B", 3000),
	["c.bin"] = string.rep("C", 3000),
})
local respond = ninep.responder(tree)

-- ---- the transport ----
--
-- send() computes the answer immediately into a holding queue; recv()
-- drains it, reversing whatever accumulated since the last drain. With
-- several requests in flight that guarantees the first reply out is the
-- last request in.

local held, ready = {}, {}
local reversals, closed = 0, false

local stream = {
	send = function(bytes)
		held[#held + 1] = respond(bytes)
	end,
	recv = function()
		while #ready == 0 do
			if closed then
				return nil
			end
			if #held == 0 then
				-- nothing to answer yet: let the callers run.
				-- A real transport parks on its socket here;
				-- this one has nowhere to park, so it yields.
				-- thread.yield rather than coroutine.yield:
				-- only the first gives the cpu up.
				thread.yield()
			else
				if #held > 1 then
					reversals = reversals + 1
				end
				for i = #held, 1, -1 do
					ready[#ready + 1] = held[i]
				end
				held = {}
			end
		end
		return table.remove(ready, 1)
	end,
}

local res = {}

thread.spawn(function()
	local fs = p9fs.new(stream)

	res.attached = fs ~= nil

	-- one caller at a time still works
	local h = fs.walk(fs.attach(), "hello.txt")
	local f = fs.open(h, "r")

	res.single = fs.read(f, 0, 4096)
	fs.clunk(f)

	-- several at once, answered backwards. Three readers of three
	-- different files: each must get ITS file, which a mux routing by
	-- arrival order would fail.
	local got, done = {}, thread.chancreate(3)

	for _, name in ipairs({ "a.bin", "b.bin", "c.bin" }) do
		thread.spawn(function()
			local wh = fs.walk(fs.attach(), name)
			local oh = fs.open(wh, "r")

			got[name] = fs.read(oh, 0, 4096)
			fs.clunk(oh)
			done:send(true)
		end)
	end
	for _ = 1, 3 do
		done:recv()
	end
	res.got = got
	res.reversals = reversals

	-- tags are released rather than leaked. A leak shows up as "no
	-- free tags" long before 200 exhausts a 65534-tag space, because
	-- the allocator refuses once it has scanned the whole space.
	res.many = true
	for _ = 1, 200 do
		local wh = fs.walk(fs.attach(), "hello.txt")
		local oh = fs.open(wh, "r")

		if fs.read(oh, 0, 4096) ~= "hello from a stream\n" then
			res.many = false
			break
		end
		fs.clunk(oh)
	end

	-- a failed walk must raise rather than hang, and must not strand
	-- its tag
	res.failed = not pcall(fs.walk, fs.attach(), "nope.txt")

	closed = true
end)
thread.run()

tap.ok(res.attached, "attached over a stream transport")
tap.ok(res.single == "hello from a stream\n", "a single read over the stream")
tap.ok((res.reversals or 0) > 0,
    "the transport answered out of order (" .. tostring(res.reversals) ..
    " times)")
tap.ok(res.got and res.got["a.bin"] == string.rep("A", 3000) and
    res.got["b.bin"] == string.rep("B", 3000) and
    res.got["c.bin"] == string.rep("C", 3000),
    "three concurrent readers each got their own file")
tap.ok(res.many, "200 round trips reuse tags without running out")
tap.ok(res.failed, "a failed walk raises rather than hanging")

tap.done()
