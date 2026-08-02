#!/usr/bin/env lua5.4
-- lib/tcb.lua over a link that loses, reorders, duplicates and delays.
--
-- Everything the stack has been run against so far is perfect. slirp
-- drops nothing, the LAN dropped nothing across 167,000 segments, and
-- vmd dropped nothing either -- so every line of loss recovery in this
-- implementation has, until now, never once executed in a test. That is
-- the worst state for code to be in: written, plausible, and unrun.
--
-- It matters more the moment congestion control lands, because
-- congestion control is ENTIRELY loss recovery. Slow start, fast
-- retransmit and fast recovery are dead code on a perfect link. So the
-- link comes first, and it is deterministic rather than random: "drop
-- the third data segment" is a test you can debug, where "5% loss" is a
-- test that fails once a fortnight.
--
-- The sans-io design is what makes this possible at all. The TCBs take
-- time as an argument and hand back segments, so a link is a table of
-- in-flight segments and a clock -- no sockets, no sleeping, and a
-- ten-second timeout costs nothing to simulate.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local tcp4 = require("tcp4")
local tcb = require("tcb")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
	return cond
end

local function is(got, want, name)
	if got ~= want then
		io.write(("# %s: got %s, want %s\n"):format(name,
		    tostring(got), tostring(want)))
	end
	return ok(got == want, name)
end

local function diag(s)
	io.write("# " .. tostring(s) .. "\n")
end

-- ---- the link ----
--
-- Two endpoints, a one-way delay, and a queue of segments in flight.
-- Time only moves to the next thing that can happen -- a segment
-- arriving or a timer expiring -- so a connection that spends a second
-- waiting for a retransmission costs the test nothing to watch.

local Link = {}

Link.__index = Link

-- opts:
--   rtt      round trip in ms; each direction gets half (default 20)
--   drop     function(side, seg, n) -> true to lose this segment
--   dup      function(side, seg, n) -> true to deliver it twice
--   jitter   function(side, seg, n) -> extra ms of delay, which is how
--            reordering happens: a delayed segment arrives behind one
--            sent after it
local function link(a, b, opts)
	opts = opts or {}
	return setmetatable({
		a = a, b = b,
		now = 0,
		owd = (opts.rtt or 20) // 2,
		dropf = opts.drop,
		dupf = opts.dup,
		jitterf = opts.jitter,
		flight = {},
		sent = { a = 0, b = 0 },
		dropped = { a = 0, b = 0 },
		delivered = { a = 0, b = 0 },
	}, Link)
end

-- take whatever each end wants to send and put it on the wire.
function Link:collect()
	for _, side in ipairs({ "a", "b" }) do
		local from = self[side]

		for _, s in ipairs(from:take()) do
			local n = self.sent[side] + 1

			self.sent[side] = n

			if self.dropf and self.dropf(side, s, n) then
				self.dropped[side] = self.dropped[side] + 1
			else
				local extra = self.jitterf and
				    self.jitterf(side, s, n) or 0

				self.flight[#self.flight + 1] = {
					due = self.now + self.owd + extra,
					to = side == "a" and "b" or "a",
					seg = s,
				}
				if self.dupf and self.dupf(side, s, n) then
					self.flight[#self.flight + 1] = {
						due = self.now + self.owd + extra + 1,
						to = side == "a" and "b" or "a",
						seg = s,
					}
				end
			end
		end
	end
end

-- the next moment anything can happen: a segment landing, or a timer
-- going off. Nothing happens in between, so there is no reason to
-- simulate it.
function Link:next_event()
	local t

	for _, p in ipairs(self.flight) do
		if not t or p.due < t then
			t = p.due
		end
	end
	for _, side in ipairs({ "a", "b" }) do
		local d = self[side]:deadline()

		if d and (not t or d < t) then
			t = d
		end
	end
	return t
end

function Link:deliver()
	local keep = {}

	for _, p in ipairs(self.flight) do
		if p.due <= self.now then
			self.delivered[p.to] = self.delivered[p.to] + 1
			self[p.to]:segment(p.seg, self.now)
		else
			keep[#keep + 1] = p
		end
	end
	self.flight = keep
end

-- run until `deadline`, or until `done()` says to stop.
function Link:run(deadline, done)
	self:collect()

	while self.now < deadline do
		if done and done() then
			return true
		end

		local t = self:next_event()

		if not t then
			return done == nil		-- nothing left to do
		end
		if t > deadline then
			self.now = deadline
			break
		end

		-- a deadline in the past (or now) still has to advance the
		-- clock, or a timer that is already due spins forever.
		self.now = t > self.now and t or self.now + 1

		self:deliver()
		self.a:tick(self.now)
		self.b:tick(self.now)
		self:collect()
	end
	return done == nil or done()
end

local A_IP, B_IP = "\10\0\0\1", "\10\0\0\2"

local function pair(cfg)
	cfg = cfg or {}

	local a = tcb.new({ laddr = A_IP, lport = 40000, raddr = B_IP,
	    rport = 80, iss = 1000, mss = cfg.mss or 1460,
	    rcvbuf = cfg.rcvbuf, sndbuf = cfg.sndbuf })
	local b = tcb.new({ laddr = B_IP, lport = 80, raddr = A_IP,
	    rport = 40000, iss = 500000, mss = cfg.mss or 1460,
	    rcvbuf = cfg.rcvbuf, sndbuf = cfg.sndbuf })

	return a, b
end

-- open a connection over a link and leave it established.
local function connect(l)
	l.a:connect(l.now)
	l.b:listen()
	l.run(l, l.now + 5000, function()
		return l.a.state == tcb.ESTABLISHED and
		    l.b.state == tcb.ESTABLISHED
	end)
	l.a:events()
	l.b:events()
end

local function readall(t)
	local out = {}

	while true do
		local d = t:read()

		if d == nil or d == "" then
			break
		end
		out[#out + 1] = d
	end
	return table.concat(out)
end

-- ---- a link that works ----

do
	local a, b = pair()
	local l = link(a, b, { rtt = 20 })

	connect(l)
	is(a.state, tcb.ESTABLISHED, "a handshake completes over a link")
	is(b.state, tcb.ESTABLISHED, "on both ends")
	ok(l.now <= 40, "in about one round trip: " .. l.now .. "ms")

	local t0 = l.now

	a:write("hello", l.now)
	l:run(l.now + 1000, function()
		return b:status().readable >= 5
	end)
	is(readall(b), "hello", "and data crosses it")
	ok(l.now - t0 <= 20, "in half a round trip")
end

-- ---- one segment lost ----
--
-- The case that decides whether a stack is usable on a real network,
-- because a single loss is the ordinary event rather than the
-- exceptional one.
do
	local a, b = pair()
	-- lose the third segment carrying data. Not the first: a loss at
	-- the very front of a window is a different (easier) case, since
	-- nothing after it can be acknowledged either way.
	local ndata = 0
	local l = link(a, b, {
		rtt = 20,
		drop = function(side, s, _)
			if side == "a" and s.data and #s.data > 0 then
				ndata = ndata + 1
				return ndata == 3
			end
			return false
		end,
	})

	connect(l)

	local payload = string.rep("x", 1460 * 8)
	local t0 = l.now

	a:write(payload, l.now)
	local complete = l:run(l.now + 30000, function()
		return b:status().readable >= #payload
	end)

	ok(complete, "a transfer with one lost segment still completes")
	is(#readall(b), #payload, "with every byte delivered")
	is(l.dropped.a, 1, "having lost exactly one segment")

	local cost = l.now - t0

	diag("recovery took " .. cost .. "ms with an RTO floor of 1000ms")

	-- This is the behaviour being pinned, not endorsed. There is no
	-- fast retransmit yet, so the only thing that can recover the loss
	-- is the retransmission timer, and RFC 6298's floor makes that a
	-- whole second -- fifty times the round trip.
	--
	-- When RFC 5681 lands this assertion is the one that must change:
	-- three duplicate acknowledgments should recover it in about one
	-- round trip instead. Until then, asserting the slow path is what
	-- makes the improvement measurable rather than assumed.
	ok(cost >= 1000, "and today it costs a full RTO: " .. cost .. "ms")
end

-- ---- the signal fast retransmit will use ----
--
-- The receiver already produces duplicate acknowledgments for every
-- segment that arrives behind a hole -- it has to, since without SACK
-- rcv_nxt is the only thing it can say. Nothing acts on them yet.
-- Counting them here says the signal is present and correctly shaped,
-- which is the half of fast retransmit that already exists.
do
	local a, b = pair()
	local ndata = 0
	local l = link(a, b, {
		rtt = 20,
		drop = function(side, s, _)
			if side == "a" and s.data and #s.data > 0 then
				ndata = ndata + 1
				return ndata == 2
			end
			return false
		end,
	})

	connect(l)

	-- watch what b sends while the hole is open
	local dupacks = 0
	local firstack

	local realtake = b.take

	b.take = function(self)
		local segs = realtake(self)

		for _, s in ipairs(segs) do
			if (s.flags & tcp4.ACK) ~= 0 and #(s.data or "") == 0 then
				if not firstack then
					firstack = s.ack
				elseif s.ack == firstack then
					dupacks = dupacks + 1
				else
					firstack = s.ack
					dupacks = 0
				end
			end
		end
		return segs
	end

	local payload = string.rep("y", 1460 * 8)

	a:write(payload, l.now)
	l:run(l.now + 3000, function()
		return dupacks >= 3
	end)

	ok(dupacks >= 3,
	    "a hole produces at least three duplicate acknowledgments: " ..
	    dupacks)
	ok(b:status().held > 0,
	    "and the segments behind it are held, not discarded")
end

-- ---- reordering ----
--
-- Delay one segment past the ones behind it. Nothing is lost, so
-- nothing should be retransmitted: a stack that treats reordering as
-- loss retransmits perfectly good data and halves its own throughput.
do
	local a, b = pair()
	local ndata = 0
	local l = link(a, b, {
		rtt = 20,
		jitter = function(side, s, _)
			if side == "a" and s.data and #s.data > 0 then
				ndata = ndata + 1
				if ndata == 2 then
					return 30	-- arrives after 3, 4, 5
				end
			end
			return 0
		end,
	})

	connect(l)

	local payload = string.rep("z", 1460 * 6)

	a:write(payload, l.now)

	local complete = l:run(l.now + 5000, function()
		return b:status().readable >= #payload
	end)

	ok(complete, "a reordered transfer completes")
	is(#readall(b), #payload, "with every byte in place")
	is(l.dropped.a, 0, "and nothing was actually lost")
	ok(a:status().retries == 0, "so nothing was retransmitted")
end

-- ---- duplicates ----
--
-- The wire delivering a segment twice must be invisible above tcp. It
-- is the one failure mode a length check cannot catch: two copies of a
-- segment accepted twice is a stream that is too long and still looks
-- plausible.
do
	local a, b = pair()
	local l = link(a, b, {
		rtt = 20,
		dup = function(side, s, n)
			return side == "a" and s.data and #s.data > 0 and n % 2 == 0
		end,
	})

	connect(l)

	local payload = string.rep("w", 1460 * 5)

	a:write(payload, l.now)
	l:run(l.now + 5000, function()
		return b:status().readable >= #payload
	end)

	local got = readall(b)

	is(#got, #payload, "duplicated segments do not lengthen the stream")
	ok(got == payload, "and do not corrupt it")
end

-- ---- a lossy link, both ways ----
--
-- Deterministic still: a seeded generator rather than math.random, so a
-- failure here is reproducible from the seed printed in the diagnostic
-- rather than being a thing that happened once.
do
	local seed = tonumber(os.getenv("LOSS_SEED") or "20260802")
	local state = seed

	local function rnd()
		-- a small LCG. Numerical Recipes' constants; good enough to
		-- decide which segments to lose and, unlike math.random,
		-- identical on every lua that will ever run this.
		state = (1664525 * state + 1013904223) % 4294967296
		return state / 4294967296
	end

	local a, b = pair({ sndbuf = 256 * 1024 })
	local l = link(a, b, {
		rtt = 20,
		drop = function(_, s, _)
			-- never lose a bare acknowledgment: without fast
			-- retransmit or congestion control the recovery of a
			-- lost ack is another full RTO, and this would spend
			-- its whole budget there rather than testing data
			-- recovery. That restriction comes off with 5681.
			if tcp4.seglen(s) == 0 then
				return false
			end
			return rnd() < 0.1
		end,
	})

	connect(l)

	-- Bigger than the receive buffer on purpose, which means the
	-- receiver has to be drained as it goes -- so this exercises a
	-- window that closes and reopens, not just retransmission. A
	-- payload that fits in rcvbuf would deadlock instead: readable
	-- cannot exceed the buffer, so a test waiting for it to reach the
	-- payload size would wait forever.
	local payload = string.rep("abcdefghij", 12000)	-- 120000 bytes
	local got = {}
	local total = 0

	a:write(payload, l.now)

	local t0 = l.now
	local complete = l:run(l.now + 300000, function()
		local d = b:read()

		while d ~= nil and d ~= "" do
			got[#got + 1] = d
			total = total + #d
			d = b:read()
		end
		return total >= #payload
	end)

	diag(string.format("seed %d: %d segments, %d lost, %dms",
	    seed, l.sent.a, l.dropped.a, l.now - t0))

	ok(complete, "a transfer over a 10 percent lossy link completes")
	ok(l.dropped.a > 0, "having actually lost something")
	is(total, #payload, "with the right number of bytes")
	ok(table.concat(got) == payload, "and every one of them in order")
end

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
