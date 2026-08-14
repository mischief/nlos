-- large messages between two procs, and whether what arrives is what
-- was sent.
--
-- This exists because gefs reads back blocks that fail their checksums
-- when its server runs on a different cpu from the block device's, and
-- gefs is a bad place to debug that: a b-tree, a disk and an allocator
-- sit between the corruption and anything that would name it. What is
-- actually under suspicion is the message path itself -- the biggest
-- payloads in the tree go over it, and a proc on each side of it can
-- now run at the same time.
--
-- So: no filesystem, no device, no library. Two procs, one port, and
-- payloads sized around MAXMSG (64K in kernel.c). Nothing here is
-- discarded on arrival -- a receiver that only counted bytes would pass
-- while every one of them was wrong. Each message is compared against
-- the exact string it should be, rebuilt from the index the message
-- carries, so a swapped, truncated, doubled or stale message is a
-- mismatch rather than a right-sized blur.
--
-- Run at -smp 1 as well as 2 and 4 on purpose. On one cpu this is a
-- regression test for the message path; on two it is the actual
-- question.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(7)

-- period 251, coprime with every power of two and with the sizes
-- below, so a payload that slipped by any whole number of machine
-- words does not still match. A single repeated byte would hide
-- exactly the corruption worth finding.
local base = {}

for i = 0, 250 do
	base[#base + 1] = string.char(32 + (i * 37) % 95)
end
base = table.concat(base)

-- the message for index i at size n, which both ends compute. The
-- index goes in the last 8 bytes so that a message delivered out of
-- order, or delivered twice, names itself.
local function payload(i, n)
	local body = string.rep(base, math.ceil(n / #base)):sub(1, n - 8)

	return body .. string.format("%08d", i)
end

-- send, and treat a full port as backpressure rather than as failure:
-- these payloads are large enough to fill a queue, and blocking here
-- is the honest response to that.
local function push(right, msg)
	for _ = 1, 1000000 do
		if sys.send(right, msg) then
			return true
		end
		sys.yield()
	end
	return false
end

local function pull(port)
	for _ = 1, 1000000 do
		local ok, msg = sys.tryrecv(port)

		if ok then
			return msg
		end
		sys.yield()
	end
	return nil
end

local me = sys.sendright(0)

-- where each child was placed, taken at spawn while it is still alive.
-- Asking sys.procs() at the end instead lists only the survivors -- the
-- boot drivers, every one of them placed before an AP was dispatching
-- -- and reports cpu0 for everything on a machine that is in fact
-- spreading them. That mistake already shipped once on this branch.
local kidhomes = {}

local function spawnkid(code, opts)
	local pid, right = sys.spawn(code, opts)
	local ok, info = pcall(sys.pidstat, pid)

	kidhomes[#kidhomes + 1] = ("%s=cpu%d"):format(opts.name,
	    (ok and info and info.home) or 0)
	return right
end

-- ---- 1. a sink: one direction, as fast as it will go ----
--
-- The receiver checks every message and reports how many were wrong,
-- so the answer is a count rather than a hang.

local SINKN, SINKSZ = 120, 60000

local sinkcode = [[
	local sys = require("los.sys")
	local a = ...
	local parent, n, sz = a.reply.__right, a.n, a.sz
	local base, payload = a.base, nil

	payload = function(i, len)
		local body = string.rep(base, math.ceil(len / #base)):sub(1, len - 8)
		return body .. string.format("%08d", i)
	end

	local bad, firstbad = 0, nil

	for i = 1, n do
		local msg
		repeat
			local ok, m = sys.tryrecv(0)
			if ok then msg = m else sys.yield() end
		until msg
		local want = payload(i, sz)
		if msg ~= want then
			bad = bad + 1
			if not firstbad then
				firstbad = ("msg %d: got %d bytes, wanted %d, tail %q"):
				    format(i, #msg, #want, msg:sub(-8))
			end
		end
	end
	sys.send(parent, { bad = bad, first = firstbad })
]]

local sink = spawnkid(sinkcode, {
	name = "bigsink",
	arg = { reply = { __right = me }, n = SINKN, sz = SINKSZ, base = base },
})

for i = 1, SINKN do
	push(sink, payload(i, SINKSZ))
end

local res = pull(0)

tap.ok(res and res.bad == 0,
    ("%d messages of %d bytes arrived intact"):format(SINKN, SINKSZ))
if res and res.bad ~= 0 then
	tap.diag(("%d of %d were wrong; %s"):format(res.bad, SINKN,
	    tostring(res.first)))
end

-- ---- 2. an echo: both directions, one in flight at a time ----
--
-- The round trip is what a request/reply protocol -- 9p, blkfs, gefs
-- -- actually does, and it puts the two procs in lockstep rather than
-- letting one run ahead.

local echocode = [[
	local sys = require("los.sys")
	local a = ...
	local parent = a.reply.__right

	for _ = 1, a.n do
		local msg
		repeat
			local ok, m = sys.tryrecv(0)
			if ok then msg = m else sys.yield() end
		until msg
		while not sys.send(parent, msg) do sys.yield() end
	end
]]

local ECHON, ECHOSZ = 60, 60000
local echo = spawnkid(echocode, {
	name = "bigecho",
	arg = { reply = { __right = me }, n = ECHON },
})

local echobad, echofirst = 0, nil

for i = 1, ECHON do
	local want = payload(i, ECHOSZ)

	push(echo, want)
	local back = pull(0)

	if back ~= want then
		echobad = echobad + 1
		if not echofirst then
			echofirst = ("round %d: got %s bytes, wanted %d"):format(
			    i, back and #back or "nil", #want)
		end
	end
end

tap.ok(echobad == 0,
    ("%d round trips of %d bytes came back unchanged"):format(ECHON, ECHOSZ))
if echobad ~= 0 then
	tap.diag(("%d of %d were wrong; %s"):format(echobad, ECHON,
	    tostring(echofirst)))
end

-- ---- 3. both directions at once ----
--
-- The echo above is still one message in flight. Here each side has a
-- backlog to send and a backlog to check at the same time, which is
-- the shape that puts two cpus into the same port from both ends.

local duplexcode = [[
	local sys = require("los.sys")
	local a = ...
	local parent, n, sz, base = a.reply.__right, a.n, a.sz, a.base

	local function payload(i, len)
		local body = string.rep(base, math.ceil(len / #base)):sub(1, len - 8)
		return body .. string.format("%08d", i)
	end

	local sent, got, bad = 0, 0, 0

	while sent < n or got < n do
		if sent < n then
			if sys.send(parent, payload(sent + 1, sz)) then
				sent = sent + 1
			end
		end
		local ok, m = sys.tryrecv(0)
		if ok then
			got = got + 1
			if m ~= payload(got, sz) then bad = bad + 1 end
		elseif sent >= n then
			sys.yield()
		end
	end
	-- a distinct port for the verdict, so it cannot be mistaken for
	-- one of the payloads above
	sys.send(a.done.__right, bad)
]]

local DUPN, DUPSZ = 80, 32000
local doneport = sys.newport("microvm_bigmsg.")
local doneright = sys.sendright(doneport)
local dup = spawnkid(duplexcode, {
	name = "bigduplex",
	arg = { reply = { __right = me }, done = { __right = doneright },
	    n = DUPN, sz = DUPSZ, base = base },
})

local dsent, dgot, dbad = 0, 0, 0

while dsent < DUPN or dgot < DUPN do
	if dsent < DUPN then
		if sys.send(dup, payload(dsent + 1, DUPSZ)) then
			dsent = dsent + 1
		end
	end
	local ok, m = sys.tryrecv(0)

	if ok then
		dgot = dgot + 1
		if m ~= payload(dgot, DUPSZ) then dbad = dbad + 1 end
	elseif dsent >= DUPN then
		sys.yield()
	end
end

local theirbad = pull(doneport)

tap.ok(dbad == 0 and theirbad == 0,
    ("%d messages each way at once, %d bytes, both sides intact"):format(
	DUPN, DUPSZ))
if dbad ~= 0 or theirbad ~= 0 then
	tap.diag(("this side %d wrong, far side %s wrong"):format(dbad,
	    tostring(theirbad)))
end

-- ---- 4. a size sweep ----
--
-- One size can pass while the boundary next to it does not: the wbuf
-- doubles and clamps at MAXMSG, so the interesting sizes are the ones
-- straddling a power of two and the ones just under the limit.

local sizes = { 9, 256, 257, 4096, 16384, 16385, 32768, 60000, 65000 }
local sweepcode = [[
	local sys = require("los.sys")
	local a = ...
	local parent = a.reply.__right

	for _ = 1, a.n do
		local msg
		repeat
			local ok, m = sys.tryrecv(0)
			if ok then msg = m else sys.yield() end
		until msg
		while not sys.send(parent, msg) do sys.yield() end
	end
]]

local sweep = spawnkid(sweepcode, {
	name = "bigsweep",
	arg = { reply = { __right = me }, n = #sizes },
})

local sweepbad = {}

for i, sz in ipairs(sizes) do
	local want = payload(i, sz)

	push(sweep, want)
	local back = pull(0)

	if back ~= want then
		sweepbad[#sweepbad + 1] = ("%d bytes -> %s"):format(sz,
		    back and #back or "nil")
	end
end

tap.ok(#sweepbad == 0, "every size from 9 to 65000 bytes survived the trip")
if #sweepbad > 0 then
	tap.diag("failed: " .. table.concat(sweepbad, ", "))
end

-- ---- 5. a right in every message ----
--
-- The four cases above send bytes. Everything that actually uses this
-- path sends a capability with them: mnt puts msg.reply = { __right =
-- ... } on every request, so each round trip mints a right, serializes
-- it into a message, hands it to another proc, and drops both copies.
-- That is refcounted kernel state rather than a payload, and it is the
-- one part of the message the receiver cannot check by comparing it to
-- what it expected.
--
-- Rights are copied, not moved: the sender still owns its own after
-- send and has to close it. Getting that wrong leaks ports until
-- newport fails, which is why the port is closed here too and why the
-- count is high enough for a leak to run the table out.

local rightscode = [[
	local sys = require("los.sys")
	local a = ...

	for _ = 1, a.n do
		local msg
		repeat
			local ok, m = sys.tryrecv(0)
			if ok then msg = m else sys.yield() end
		until msg
		local back = msg.reply.__right
		while not sys.send(back, msg.data) do sys.yield() end
		sys.close(back)
	end
]]

local RN, RSZ = 120, 32000
local rights = spawnkid(rightscode, {
	name = "bigrights",
	arg = { n = RN },
})

local rbad, rfirst = 0, nil

for i = 1, RN do
	local want = payload(i, RSZ)
	local port = sys.newport("microvm_bigmsg")

	if not port then
		rfirst = ("ran out of ports at %d, which is a leak"):format(i)
		rbad = rbad + 1
		break
	end

	local right = sys.sendright(port)

	push(rights, { reply = { __right = right }, data = want })
	sys.close(right)		-- ours; the copy went with the message

	local back = pull(port)

	if back ~= want then
		rbad = rbad + 1
		if not rfirst then
			rfirst = ("round %d: got %s bytes, wanted %d"):format(
			    i, back and #back or "nil", #want)
		end
	end
	sys.close(port)
end

tap.ok(rbad == 0,
    ("%d round trips carrying a fresh right each, %d bytes"):format(RN, RSZ))
if rbad ~= 0 then
	tap.diag(("%d of %d were wrong; %s"):format(rbad, RN, tostring(rfirst)))
end

-- ---- 6. a server parked in alt, with concurrent callers ----
--
-- Everything above uses tryrecv and yield, which never blocks. Nothing
-- real does that. A server built on los.thread parks in sys.alt --
-- thread.run hands every waiting port to it, so one entry blocks and
-- takes on behalf of all of them -- and that is the path gefssrv,
-- blksrv and every mnt client actually wait on.
--
-- It is also the path where a bug does not announce itself. alt
-- has to return both a message and which port it came from; hand back
-- a message paired with the wrong port and a caller waiting on its own
-- reply port is given somebody else's reply. That is indistinguishable
-- from a block device returning the wrong block, which is what gefs
-- reports.
--
-- So every reply here carries the sequence number of the request it
-- answers, and each caller checks it got its own.

local altcode = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local a = ...

	thread.spawn(function()
		for _ = 1, a.n do
			local msg = thread.recv(sys.SELF)

			local back = msg.reply.__right

			while not sys.send(back,
			    { seq = msg.seq, data = msg.data }) do
				thread.yield()
			end
			sys.close(back)
		end
	end)
	thread.run()
]]

local ATHREADS, APER, ASZ = 4, 25, 16000
local alt = spawnkid(altcode, {
	name = "bigalt",
	arg = { n = ATHREADS * APER },
})

local altbad, altfirst = 0, nil

local function altmain()
	local done = thread.chancreate(ATHREADS)

	for t = 1, ATHREADS do
		thread.spawn(function()
			for j = 1, APER do
				local seq = (t - 1) * APER + j
				local want = payload(seq, ASZ)
				local reply = thread.replyport()
				local res, why = thread.call(alt, { seq = seq,
				    data = want, reply = { __right = reply } },
				    reply)

				if not res and not altfirst then
					altfirst = ("caller %d seq %d: %s"):format(
					    t, seq, tostring(why))
				end

				if type(res) ~= "table" or res.seq ~= seq or
				    res.data ~= want then
					altbad = altbad + 1
					if not altfirst then
						altfirst = ("caller %d wanted seq %d, got %s"):
						    format(t, seq, res and tostring(res.seq) or "nil")
					end
				end
			end
			done:send(true)
		end)
	end
	for _ = 1, ATHREADS do done:recv() end
end

thread.spawn(altmain)
thread.run()

tap.ok(altbad == 0,
    ("%d callers x %d calls through a server parked in alt"):format(
	ATHREADS, APER))
if altbad ~= 0 then
	tap.diag(("%d wrong; %s"):format(altbad, tostring(altfirst)))
end

-- ---- and where all that ran ----
--
-- The point of the whole file. Every assertion above passes on one cpu,
-- so unless something actually ran somewhere else, none of them asked
-- the question they exist to ask.
--
-- Asked of the cpus rather than of the procs. A proc reports the cpu it
-- last RAN on, which is not known until it has run -- so sampling a
-- freshly spawned child says "cpu0" for the honest reason that it has
-- not been anywhere yet, and this test failed exactly that way under a
-- loaded host while passing alone. What is wanted here is whether the
-- work spread, and the dispatch counters answer that directly and at
-- any time.
local st = sys.stats()

local desc = {}

for i, c in ipairs(st.cpu or {}) do
	desc[#desc + 1] = ("cpu%d=%d"):format(i - 1, c.dispatched or 0)
end
tap.diag("cpus: " .. tostring(st.cpus) .. "; dispatched " ..
    table.concat(desc, " ") .. "; last ran " ..
    table.concat(kidhomes, " "))

local elsewhere = 0

for i, c in ipairs(st.cpu or {}) do
	if i > 1 and (c.dispatched or 0) > 0 then
		elsewhere = elsewhere + 1
	end
end

if st.cpus > 1 then
	tap.ok(elsewhere > 0,
	    "a cpu other than the boot processor ran procs, so this was smp")
else
	tap.ok(elsewhere == 0,
	    "one cpu, so everything shared it")
end

tap.done()
