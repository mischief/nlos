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
	    rcvbuf = cfg.rcvbuf, sndbuf = cfg.sndbuf, sack = cfg.sack_a })
	local b = tcb.new({ laddr = B_IP, lport = 80, raddr = A_IP,
	    rport = 40000, iss = 500000, mss = cfg.mss or 1460,
	    rcvbuf = cfg.rcvbuf, sndbuf = cfg.sndbuf, sack = cfg.sack_b })

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

	-- This assertion was written the other way round, and changing it
	-- is the point of RFC 5681. Before fast retransmit the only thing
	-- that could recover a loss was the retransmission timer, and RFC
	-- 6298's floor makes that a whole second -- fifty times the round
	-- trip. It measured 1030ms.
	--
	-- Three duplicate acknowledgments now recover it in a couple of
	-- round trips instead. The bound is deliberately well under the RTO
	-- floor: anything at or above a second means the timer did the work
	-- and fast retransmit did not fire at all, which is exactly the
	-- regression worth catching.
	ok(cost < 500, "and it now costs round trips, not an RTO: " .. cost .. "ms")
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


-- ---- the congestion window itself ----
--
-- The tests above say loss recovery got faster. These say the window is
-- actually being managed, which is the half that protects everyone else
-- on the path rather than us.

do
	local a, b = pair()
	local l = link(a, b, { rtt = 20 })

	connect(l)

	-- RFC 5681 3.1's table: an mss between 1096 and 2190 gets three
	-- segments. Not four, and not the peer's whole advertised window,
	-- which is what this sent before.
	is(a:status().cwnd, 3 * 1460, "a connection opens with a three-segment window")
	is(a:status().ssthresh, 0xffffffff,
	    "and a threshold high enough to let the network decide")

	-- the first flight is limited by cwnd, not by the receiver: the
	-- peer advertised 32KB, which is twenty-two segments.
	local payload = string.rep("x", 1460 * 20)

	a:write(payload, l.now)
	l:collect()

	local first = #l.flight

	is(first, 3, "so the first burst is three segments, not twenty")

	-- and slow start opens it: each acknowledgment of new data adds a
	-- segment, so a round trip roughly doubles the window.
	l:run(l.now + 2000, function()
		return b:status().readable >= #payload
	end)
	ok(a:status().cwnd > 3 * 1460,
	    "slow start opens the window: " .. a:status().cwnd .. " bytes")
end

-- ---- what a loss costs the window ----

do
	local a, b = pair({ sndbuf = 256 * 1024 })
	local ndata = 0
	local l = link(a, b, {
		rtt = 20,
		drop = function(side, sg, _)
			if side == "a" and sg.data and #sg.data > 0 then
				ndata = ndata + 1
				return ndata == 6
			end
			return false
		end,
	})

	connect(l)

	local payload = string.rep("x", 1460 * 30)

	a:write(payload, l.now)

	-- stop the moment recovery begins, to look at the window then
	-- rather than after it has been deflated again.
	l:run(l.now + 5000, function()
		return a:status().recovery
	end)

	ok(a:status().recovery, "three duplicates put the sender into fast recovery")

	local ss = a:status().ssthresh

	ok(ss < 0xffffffff, "which brings the threshold down: " .. ss)
	is(a:status().cwnd, ss + 3 * 1460,
	    "and inflates the window by the three segments that left the network")

	-- Drained as it goes, because the payload is larger than the
	-- receive buffer: a condition waiting for `readable` to reach the
	-- payload size can never come true, since readable is capped at
	-- rcvbuf. That is what the first version of this did, and it sat
	-- there until the deadline.
	local got = {}
	local total = 0

	local function drain()
		local d = b:read()

		while d ~= nil and d ~= "" do
			got[#got + 1] = d
			total = total + #d
			d = b:read()
		end
	end

	-- stop the instant recovery ends, and look at the window THEN.
	-- Checked after the transfer finished, it reads whatever congestion
	-- avoidance has since grown it to -- which is how the first version
	-- of this assertion managed to want 5840 and find 9514.
	l:run(l.now + 10000, function()
		drain()
		return not a:status().recovery
	end)

	ok(not a:status().recovery, "a full acknowledgment ends recovery")
	is(a:status().cwnd, ss, "deflating the window to the threshold")

	l:run(l.now + 20000, function()
		drain()
		return total >= #payload
	end)
	is(total, #payload, "with the whole transfer delivered")
end

-- ---- two losses in one window ----
--
-- The case NewReno exists for. Reno recovers the first loss by fast
-- retransmit, then has nothing to say about the second and waits out a
-- retransmission timeout -- a whole second here. The partial
-- acknowledgment rule of RFC 6582 resends the second immediately.
do
	local a, b = pair({ sndbuf = 256 * 1024 })
	local ndata = 0
	local l = link(a, b, {
		rtt = 20,
		drop = function(side, sg, _)
			if side == "a" and sg.data and #sg.data > 0 then
				ndata = ndata + 1
				return ndata == 4 or ndata == 6
			end
			return false
		end,
	})

	connect(l)

	local payload = string.rep("q", 1460 * 20)
	local t0 = l.now

	a:write(payload, l.now)

	local complete = l:run(l.now + 30000, function()
		return b:status().readable >= #payload
	end)

	local cost = l.now - t0

	diag("two losses in one window recovered in " .. cost .. "ms")
	ok(complete, "two losses in one window still complete")
	is(#readall(b), #payload, "with every byte delivered")
	is(l.dropped.a, 2, "having lost exactly two")
	ok(cost < 1000,
	    "and without waiting out a timeout for the second: " .. cost .. "ms")
end

-- ---- a timeout collapses the window ----

do
	local a, b = pair()
	local blackout = true
	local l = link(a, b, {
		rtt = 20,
		drop = function(side, sg, _)
			-- lose everything with data for a while, so nothing
			-- can recover except the timer.
			return blackout and side == "a" and sg.data and
			    #sg.data > 0
		end,
	})

	connect(l)
	a:write(string.rep("t", 1460 * 10), l.now)

	l:run(l.now + 5000, function()
		return a:status().retries > 0
	end)

	ok(a:status().retries > 0, "a black hole eventually times out")
	is(a:status().cwnd, 1460,
	    "and the window collapses to one segment, whatever it was")
	ok(a:status().ssthresh < 0xffffffff, "with the threshold brought down too")

	-- and it recovers once the link comes back, by slow start rather
	-- than by resuming where it left off.
	blackout = false

	local payload_len = 1460 * 10

	l:run(l.now + 60000, function()
		return b:status().readable >= payload_len
	end)
	is(b:status().readable, payload_len, "and the transfer completes when it clears")
end

-- ---- what is not a duplicate acknowledgment ----
--
-- RFC 5681 section 2 is precise about this, and the precision matters:
-- counting the wrong thing retransmits data that was never lost. A
-- segment carrying data is not a duplicate acknowledgment even if its
-- ack field repeats, and neither is one that moves the window.
do
	local a, b = pair()
	local l = link(a, b, { rtt = 20 })

	connect(l)
	a:write(string.rep("d", 1460 * 4), l.now)
	l:run(l.now + 2000, function()
		return b:status().readable >= 1460 * 4
	end)
	readall(b)

	local before = a:status().dupacks

	-- three acknowledgments repeating snd_una, but each carrying data:
	-- these are ordinary data segments that happen to acknowledge
	-- nothing new, which is the commonest thing on a duplex connection.
	for i = 1, 3 do
		a:segment({
			sport = 80, dport = 40000,
			seq = tcp4.add(b.snd_nxt, (i - 1) * 3),
			ack = a.snd_una,
			flags = tcp4.ACK,
			wnd = a.snd_wnd,
			data = "abc",
		}, l.now)
	end
	is(a:status().dupacks, before,
	    "an acknowledgment carrying data is not a duplicate")
	ok(not a:status().recovery, "and does not trigger fast retransmit")
end


-- ---- selective acknowledgment, RFC 2018 ----
--
-- The receiving half only. What we send tells a peer exactly which
-- segments arrived behind a hole, so its loss recovery can resend the
-- one that did not rather than guessing from a cumulative number.
-- Acting on the blocks a peer sends us is the other half and is not
-- implemented, so nothing here asserts anything about our own sender.

-- a segment addressed to b, built by hand so the holes are exact.
local function tob(t, base)
	return {
		sport = 40000, dport = 80,
		seq = t.seq, ack = t.ack or 0,
		flags = t.flags or tcp4.ACK,
		wnd = t.wnd or 4096,
		data = t.data or "",
	}
end

do
	local a, b = pair()
	local l = link(a, b, { rtt = 20 })

	connect(l)
	ok(a:status().sack_ok, "sack is agreed when both ends offer it")
	ok(b:status().sack_ok, "on both ends")

	local base = b.rcv_nxt

	b:take()

	-- one segment, ten bytes, twenty past the hole.
	b:segment(tob({ seq = tcp4.add(base, 20), ack = b.snd_nxt,
	    data = string.rep("c", 10) }), l.now)

	local segs = b:take()
	local blocks = segs[1] and segs[1].opt and segs[1].opt.sack

	ok(blocks ~= nil, "an acknowledgment behind a hole carries sack blocks")
	is(blocks and #blocks, 1, "one of them, for the one run held")
	is(blocks and blocks[1].left, tcp4.add(base, 20),
	    "starting where the held data starts")
	is(blocks and blocks[1].right, tcp4.add(base, 30),
	    "and ending just past where it ends")

	-- a second, disjoint run. Two holes now, and both must be reported
	-- or the sender resends data it already has.
	b:segment(tob({ seq = tcp4.add(base, 50), ack = b.snd_nxt,
	    data = string.rep("d", 10) }), l.now)

	segs = b:take()
	blocks = segs[1] and segs[1].opt and segs[1].opt.sack
	is(blocks and #blocks, 2, "a second hole is reported as a second block")

	-- 2018 section 4: the first block must be the one containing the
	-- segment that triggered this acknowledgment. It is the only part
	-- of the option guaranteed to describe what just arrived, and a
	-- sender reading a stale first block resends what it need not.
	is(blocks and blocks[1].left, tcp4.add(base, 50),
	    "and the most recent arrival is reported first")

	-- adjacent segments are one run, not two: reporting them
	-- separately would be true and would waste the option space a
	-- third hole could have used.
	b:segment(tob({ seq = tcp4.add(base, 30), ack = b.snd_nxt,
	    data = string.rep("e", 20) }), l.now)

	segs = b:take()
	blocks = segs[1] and segs[1].opt and segs[1].opt.sack
	is(blocks and #blocks, 1, "abutting runs are merged into one block")
	is(blocks and blocks[1].left, tcp4.add(base, 20), "spanning from the first")
	is(blocks and blocks[1].right, tcp4.add(base, 60), "to the last")

	-- and when the hole fills, the blocks stop: there is nothing left
	-- out of order to report.
	b:segment(tob({ seq = base, ack = b.snd_nxt,
	    data = string.rep("f", 20) }), l.now)
	segs = b:take()
	ok(segs[1] and (segs[1].opt == nil or segs[1].opt.sack == nil),
	    "and once the hole fills there is nothing left to report")
	is(b:status().held, 0, "with nothing still held")
end

-- a peer that did not offer it gets none. 2018 is explicit: a receiver
-- that has not seen SACK-permitted MUST NOT send blocks, and sending
-- them anyway means putting bytes in an option field the peer will
-- parse as something it does not understand.
do
	local a, b = pair({ sack_a = false })
	local l = link(a, b, { rtt = 20 })

	connect(l)
	ok(not b:status().sack_ok,
	    "a peer that did not offer sack does not get blocks")
	ok(not a:status().sack_ok, "and neither end thinks it is agreed")

	local base = b.rcv_nxt

	b:take()
	b:segment(tob({ seq = tcp4.add(base, 20), ack = b.snd_nxt,
	    data = string.rep("c", 10) }), l.now)

	local segs = b:take()

	ok(segs[1] and (segs[1].opt == nil or segs[1].opt.sack == nil),
	    "so a hole produces a bare duplicate acknowledgment")
	is(b:status().held, 1, "though the data is still held for reassembly")
end

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
