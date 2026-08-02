-- giving up on a request: timeouts and Tflush, per flush(5).
--
-- A stream transport can be left waiting forever, so lib/p9fs.lua takes
-- an optional deadline. Reaching it is not just "raise and move on" --
-- the request is still outstanding on a connection that carries
-- everybody else's, and the tag cannot be reused until the server says
-- it is done with it.
--
-- Both outcomes flush(5) allows are tested, because the second is the
-- one that leaks fids if it is got wrong:
--
--   Rflush first  -- the transaction is cancelled and treated as never
--                    sent. The caller gets its timeout.
--   reply first   -- the server answered anyway. It must be HONOURED,
--                    not discarded: a completed Twalk allocated a fid,
--                    and dropping the reply strands it on the server
--                    with nothing left holding its number.
--
-- The server half is a real ninep.responder; only the delivery of its
-- replies is under test control. It processes every request the moment
-- it arrives and only the REPLY is held back, which is what makes the
-- late-reply case genuine: that stalled Twalk really did allocate a fid.

local ninep = require("ninep")
local p9fs = require("p9fs")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(7)

local tree = ninep.synth({
	["hello.txt"] = "hello from a stream\n",
	["slow.txt"] = "slow but real\n",
})
local respond = ninep.responder(tree)

-- The queue between send and recv is a Channel, not a table the reader
-- spins on. That matters here: a deadline is a timer PORT, and
-- thread.run only readies port-parked threads after sys.altblock
-- returns, which it only reaches once the run queue empties. A reader
-- that yields in a loop is always runnable, so the run queue never
-- empties and the timer never fires.

local q = thread.chancreate(64)
local stall = {}	-- request type -> hold its reply back
local stalled = {}	-- {req = type, rep = bytes}

local stream = {
	send = function(bytes)
		local m = ninep.decode(bytes)
		local rep = respond(bytes)

		if stall[m.type] then
			stalled[#stalled + 1] = { req = m.type, rep = rep }
			return
		end
		q:send(rep)
	end,
	recv = function()
		local v, alive = q:recv()

		if alive == false then
			return nil
		end
		return v
	end,
}

-- deliver the held replies for one request type, in order
local function release(reqtype)
	local keep = {}

	for _, e in ipairs(stalled) do
		if e.req == reqtype then
			q:send(e.rep)
		else
			keep[#keep + 1] = e
		end
	end
	stalled = keep
end

-- drop them instead, which is what a server that answered a flush does:
-- the request is cancelled and no reply is ever coming.
local function discard(reqtype)
	local keep = {}

	for _, e in ipairs(stalled) do
		if e.req ~= reqtype then
			keep[#keep + 1] = e
		end
	end
	stalled = keep
end

local res = {}

thread.spawn(function()
	local fs = p9fs.new(stream, { timeout = 300 })

	res.attached = fs ~= nil

	-- attach BEFORE anything is stalled: it is a Tclone, which is a
	-- Twalk on the wire, so stalling Twalk would stall it too
	local root = fs.attach()
	local h = fs.walk(root, "hello.txt")
	local f = fs.open(h, "r")

	res.normal = fs.read(f, 0, 4096)
	fs.clunk(f)

	-- ---- Rflush first: the request is cancelled ----
	--
	-- Twalk is held; the Tflush is answered at once, so the Rflush
	-- wins and the caller must see a timeout rather than hang.
	stall[ninep.Twalk] = true

	local ok, err = pcall(fs.walk, root, "hello.txt")

	res.cancelled_ok = ok
	res.cancelled_err = tostring(err)
	stall[ninep.Twalk] = nil
	discard(ninep.Twalk)

	-- ---- reply first: it must be honoured ----
	--
	-- hold the Tflush too, so its Rflush cannot win the race, then
	-- release the Rwalk while the flush is still outstanding. p9fs
	-- must take that reply and hand back the fid the server really did
	-- allocate, rather than raising.
	stall[ninep.Twalk] = true
	stall[ninep.Tflush] = true

	local got
	local done = thread.chancreate(1)

	thread.spawn(function()
		local wok, wres = pcall(fs.walk, root, "slow.txt")

		got = { ok = wok, res = wres }
		done:send(true)
	end)

	thread.sleep(500)		-- let it time out and flush
	release(ninep.Twalk)		-- the answer arrives late
	thread.sleep(200)
	release(ninep.Tflush)		-- and only then the Rflush
	done:recv()

	stall[ninep.Twalk] = nil
	stall[ninep.Tflush] = nil

	res.honoured_ok = got and got.ok
	res.honoured_fid = got and got.ok and type(got.res) == "table"

	-- ---- and the connection still works afterwards ----
	--
	-- the point of retiring tags correctly: neither path above may
	-- leave the tag space or the mux poisoned.
	local h2 = fs.walk(root, "hello.txt")
	local f2 = fs.open(h2, "r")

	res.after = fs.read(f2, 0, 4096)
	fs.clunk(f2)

	for _ = 1, 50 do
		local hh = fs.walk(root, "hello.txt")

		fs.clunk(hh)
	end
	res.many = true

	q:close()
end)
thread.run()

tap.ok(res.attached, "attached with a timeout set")
tap.ok(res.normal == "hello from a stream\n",
    "a normal call is unaffected by the deadline")
tap.ok(res.cancelled_ok == false,
    "a stalled request times out rather than hanging")
tap.diag("timeout error: " .. tostring(res.cancelled_err))
tap.ok(res.cancelled_err and res.cancelled_err:find("timed out") ~= nil,
    "and says so")
tap.ok(res.honoured_ok == true,
    "a reply arriving after the flush is honoured, not discarded")
tap.ok(res.honoured_fid == true, "and yields a usable fid")
tap.ok(res.after == "hello from a stream\n" and res.many,
    "the connection still works, so no tag was stranded")

tap.done()
