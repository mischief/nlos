#!/usr/bin/env lua5.4
-- lib/tcb.lua on the host: two state machines talking to each other,
-- and a series of segments no real peer would send.
--
-- The first half wires two TCBs together and lets them do a handshake,
-- which is the cheapest possible check that our idea of a connection is
-- self-consistent. The second half is the reason this file exists: an
-- acknowledgment of something never sent, a reset that acknowledges
-- nothing, a segment that arrives before the one in front of it, a SYN
-- inside an open connection. None of those can be asked for from
-- OpenBSD, and every one of them is a line here.
--
-- Two TCBs agreeing with each other is not proof they are right -- they
-- share every misreading of the RFC. That is what the boot tests
-- against a real peer are for; this is for the cases those cannot
-- reach.

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

-- lib/tcb.lua gives up after this many retransmissions; the loop below
-- needs one more than that to see it happen.
local MAX_RETX_TRIES = 9

local A_IP, B_IP = "\10\0\0\1", "\10\0\0\2"
local ISS_A, ISS_B = 0x10000, 0x900000

local function newA(cfg)
	cfg = cfg or {}
	return tcb.new({ laddr = A_IP, lport = 40000,
	    raddr = B_IP, rport = 80,
	    iss = cfg.iss or ISS_A, mss = cfg.mss or 1460,
	    rcvbuf = cfg.rcvbuf, sndbuf = cfg.sndbuf, msl = cfg.msl })
end

local function newB(cfg)
	cfg = cfg or {}
	return tcb.new({ laddr = B_IP, lport = 80,
	    raddr = A_IP, rport = 40000,
	    iss = cfg.iss or ISS_B, mss = cfg.mss or 1460,
	    rcvbuf = cfg.rcvbuf, sndbuf = cfg.sndbuf, msl = cfg.msl })
end

-- everything one side wants to send, handed to the other. Returns the
-- segments moved, so a test can assert on them as well as on the state
-- they produced.
local function pipe(from, to)
	local segs = from:take()

	for _, s in ipairs(segs) do
		to:segment(s)
	end
	return segs
end

local function kinds(t)
	local out = {}

	for _, e in ipairs(t:events()) do
		out[#out + 1] = e.kind
	end
	return table.concat(out, ",")
end

-- a segment built by hand, for the cases a peer will not produce.
local function seg(t)
	t.flags = t.flags or 0
	t.wnd = t.wnd or 4096
	t.seq = t.seq or 0
	t.ack = t.ack or 0
	t.data = t.data or ""
	t.sport = t.sport or 80
	t.dport = t.dport or 40000
	return t
end

-- ---- the handshake ----

local a, b = newA(), newB()

a:connect()

local syn = a:take()

is(#syn, 1, "an active open sends one segment")
is(syn[1] and syn[1].flags, tcp4.SYN, "and it is a bare SYN")
is(syn[1] and syn[1].seq, ISS_A, "sitting at our initial sequence number")
is(syn[1] and syn[1].opt and syn[1].opt.mss, 1460, "advertising our mss")
is(a.state, tcb.SYN_SENT, "and the connection is in SYN-SENT")

b:listen()
is(b.state, tcb.LISTEN, "a passive open listens")

b:segment(syn[1])

local synack = b:take()

is(#synack, 1, "a listener answers a SYN")
is(synack[1] and synack[1].flags, tcp4.SYN | tcp4.ACK, "with a SYN,ACK")
is(synack[1] and synack[1].ack, tcp4.add(ISS_A, 1),
    "acknowledging the octet the SYN occupied")
is(b.state, tcb.SYN_RECEIVED, "and moves to SYN-RECEIVED")

a:segment(synack[1])
is(a.state, tcb.ESTABLISHED, "the opener reaches ESTABLISHED first")
is(kinds(a), "established", "and says so once")
is(a.snd_mss, 1460, "having learned the peer's mss")

pipe(a, b)
is(b.state, tcb.ESTABLISHED, "and the listener follows on the final ACK")
is(kinds(b), "established", "announcing it too")

-- ---- data ----

is(a:write("hello"), 5, "a write takes all five bytes")

local data = pipe(a, b)

is(#data, 1, "which go out as one segment")
is(data[1].data, "hello", "carrying the bytes")
ok((data[1].flags & tcp4.PSH) ~= 0, "pushed, since it emptied the buffer")
is(b:read(), "hello", "and the peer reads them back")
is(b:read(), "", "with nothing left over")

-- The receiver must acknowledge data it took responsibility for, or the
-- sender will send it again forever -- but not necessarily at once.
--
-- Five bytes is far short of the two full-sized segments RFC 5681 4.2
-- waits for, so the acknowledgment is owed rather than sent, and the
-- timer is what eventually pays it. This assertion used to read "taking
-- data produces an acknowledgment", which was true and was costing a
-- segment per segment.
is(#b:take(), 0, "a small segment is not acknowledged on the spot")
ok(b:status().delack ~= nil, "the acknowledgment is owed instead")

b:tick(b:status().delack)

local acks = b:take()

is(#acks, 1, "and the timer pays it")
is(acks[1].ack, tcp4.add(data[1].seq, 5), "covering exactly what arrived")

a:segment(acks[1])
is(a:status().unacked, 0, "and the sender considers it acknowledged")

-- both directions, because a half-duplex bug passes every test above.
b:write("world")
pipe(b, a)
is(a:read(), "world", "data flows the other way too")

-- ---- segmentation ----
--
-- The peer said 1460, so a kilobyte at a time is one segment and three
-- kilobytes is three. Sending more than the peer's mss is how a stack
-- produces fragments that some middlebox eats.
local big = newA({ sndbuf = 100000 })
local bigpeer = newB({ rcvbuf = 100000 })

big:connect()
bigpeer:listen()
pipe(big, bigpeer)
pipe(bigpeer, big)
pipe(big, bigpeer)

is(big.state, tcb.ESTABLISHED, "a second connection opens the same way")

big:write(string.rep("x", 3000))

local chunks = pipe(big, bigpeer)

is(#chunks, 3, "three thousand bytes is three segments at mss 1460")
is(#chunks[1].data, 1460, "the first is a full segment")
is(#chunks[3].data, 80, "and the last is the remainder")
is(bigpeer:read(), string.rep("x", 3000), "which reassemble in order")

-- ---- the send window is obeyed ----
--
-- A sender that ignores the receive window overruns the peer, and the
-- peer's only recourse is to drop and retransmit -- which looks like a
-- slow network rather than like our bug.
local slow = newA({ sndbuf = 100000 })

slow:connect()
slow:take()
slow:segment(seg({ flags = tcp4.SYN | tcp4.ACK, seq = 5000,
    ack = tcp4.add(ISS_A, 1), wnd = 100 }))
slow:take()
is(slow.state, tcb.ESTABLISHED, "connected to a peer with a small window")

slow:write(string.rep("y", 1000))

local held = slow:take()
local total = 0

for _, s in ipairs(held) do
	total = total + #s.data
end
is(total, 100, "only a windowful goes out")
is(slow:status().unsent, 900, "and the rest waits")

-- opening the window releases the rest.
slow:segment(seg({ flags = tcp4.ACK, seq = 5001,
    ack = tcp4.add(ISS_A, 101), wnd = 500 }))

local more = slow:take()

total = 0
for _, s in ipairs(more) do
	total = total + #s.data
end
is(total, 500, "an acknowledgment that opens the window releases more")

-- an old segment must not install an old window over a newer one.
slow:segment(seg({ flags = tcp4.ACK, seq = 4000,
    ack = tcp4.add(ISS_A, 101), wnd = 60000 }))
is(slow.snd_wnd, 500, "a reordered segment cannot revise the window")

-- ---- receiving out of order, and receiving old ----

local r = newA()
local peer = newB()

r:connect()
peer:listen()
pipe(r, peer)
pipe(peer, r)
pipe(r, peer)
r:take()
peer:take()

local base = peer.snd_nxt
local rnext = r.rcv_nxt

-- a segment from the future is held, not delivered: there is a hole in
-- front of it. What goes back is still an acknowledgment of rcv_nxt,
-- because without SACK there is no way to say "and also these" -- which
-- is exactly the duplicate acknowledgment fast retransmit reads.
r:segment(seg({ flags = tcp4.ACK, seq = tcp4.add(rnext, 100),
    ack = r.snd_nxt, data = "future" }))
is(r:read(), "", "a segment beyond the hole is not delivered")

local nak = r:take()

is(#nak, 1, "but it is answered")
is(nak[1].ack, rnext, "with what we are actually waiting for")

-- a retransmission of data we already have, overlapping the new: only
-- the new part is taken.
r:segment(seg({ flags = tcp4.ACK, seq = rnext, ack = r.snd_nxt,
    data = "abc" }))
is(r:read(), "abc", "the first three bytes arrive")
r:take()
r:segment(seg({ flags = tcp4.ACK, seq = rnext, ack = r.snd_nxt,
    data = "abcdef" }))
is(r:read(), "def", "and a straddling retransmission delivers only the new part")
r:take()

-- an entirely old segment is acknowledged and otherwise ignored.
r:segment(seg({ flags = tcp4.ACK, seq = tcp4.add(rnext, 0 - 50),
    ack = r.snd_nxt, data = "old" }))
is(r:read(), "", "an old duplicate delivers nothing")
is(#r:take(), 1, "and is acknowledged so the peer stops sending it")

-- ---- closing, from the other end ----

local c, cpeer = newA(), newB()

c:connect()
cpeer:listen()
pipe(c, cpeer)
pipe(cpeer, c)
pipe(c, cpeer)
c:take()
c:events()
cpeer:take()

cpeer:write("bye")
pipe(cpeer, c)
c:take()

c:segment(seg({ flags = tcp4.ACK | tcp4.FIN, seq = c.rcv_nxt,
    ack = c.snd_nxt }))
is(c.state, tcb.CLOSE_WAIT, "a FIN moves us to CLOSE-WAIT")
is(kinds(c), "closing", "and tells the user the peer is closing")

local finack = c:take()

is(#finack, 1, "the FIN is acknowledged")
is(finack[1].ack, tcp4.add(c.rcv_nxt, 0), "past the octet it occupied")

-- Reading after a FIN still yields what arrived before it. A stack that
-- discards buffered data on FIN loses the last thing the peer said,
-- which for a request/reply protocol is the reply.
is(c:read(), "bye", "data that arrived before the FIN is still readable")
is(c:read(), nil, "and then the stream ends rather than merely pausing")

-- ---- refusals and resets ----

local ref = newA()

ref:connect()
ref:take()
ref:segment(seg({ flags = tcp4.RST | tcp4.ACK, seq = 0,
    ack = tcp4.add(ISS_A, 1) }))
is(ref.state, tcb.CLOSED, "a reset acknowledging our SYN closes us")
is(kinds(ref), "refused", "and is reported as a refusal")

-- but a reset that acknowledges nothing of ours must be ignored:
-- otherwise anyone able to guess a port pair can hang up on a
-- connection they are not part of.
local unref = newA()

unref:connect()
unref:take()
unref:segment(seg({ flags = tcp4.RST, seq = 0, ack = 0 }))
is(unref.state, tcb.SYN_SENT, "an unacknowledged reset in SYN-SENT is ignored")

local bogus = newA()

bogus:connect()
bogus:take()
bogus:segment(seg({ flags = tcp4.ACK | tcp4.SYN, seq = 7000,
    ack = 999999 }))

local rst = bogus:take()

is(#rst, 1, "an acknowledgment of something never sent is refused")
is(rst[1] and rst[1].flags, tcp4.RST, "with a reset")
is(rst[1] and rst[1].seq, 999999, "sitting where the peer already believes")
is(bogus.state, tcb.SYN_SENT, "and the connection is unchanged")

-- ---- simultaneous open ----
--
-- Both ends call connect at once, so each sees a SYN with no
-- acknowledgment of its own. Unreachable against a live peer without
-- arranging both ends, which is why it is here.
local s1, s2 = newA(), newB()

s1:connect()
s2.raddr, s2.rport = A_IP, 40000
s2:connect()

local s1syn, s2syn = s1:take(), s2:take()

s1:segment(s2syn[1])
s2:segment(s1syn[1])
is(s1.state, tcb.SYN_RECEIVED, "a simultaneous open leaves one side in SYN-RECEIVED")
is(s2.state, tcb.SYN_RECEIVED, "and the other as well")

-- It takes an extra exchange, and the reason is worth recording. Each
-- side now sends a SYN,ACK sitting at its own ISS -- but that sequence
-- number has already been consumed by the SYN it duplicates, so the
-- acceptability test in 3.10.7.4 rejects it as an old duplicate before
-- the ACK field is ever looked at. What completes the connection is the
-- plain acknowledgment the RFC requires in reply to an unacceptable
-- segment, not the SYN,ACK itself. The figure in section 3.5 draws the
-- happy path and not this.
pipe(s1, s2)
pipe(s2, s1)
pipe(s1, s2)
is(s1.state, tcb.ESTABLISHED, "and it completes anyway")
is(s2.state, tcb.ESTABLISHED, "on both ends")

-- ---- a SYN inside an open connection ----

local est, estpeer = newA(), newB()

est:connect()
estpeer:listen()
pipe(est, estpeer)
pipe(estpeer, est)
pipe(est, estpeer)
est:take()
estpeer:take()

est:segment(seg({ flags = tcp4.SYN, seq = est.rcv_nxt }))

local challenge = est:take()

is(#challenge, 1, "a SYN in ESTABLISHED is answered")
is(challenge[1].flags, tcp4.ACK, "with a plain acknowledgment")
is(est.state, tcb.ESTABLISHED,
    "and does not tear the connection down, per RFC 5961")

-- ---- flow control ----
--
-- A receive buffer that fills must close the window, or the advertised
-- number is a promise we cannot keep.
local tiny = newA({ rcvbuf = 100 })
local tinypeer = newB()

tiny:connect()
tinypeer:listen()
pipe(tiny, tinypeer)
pipe(tinypeer, tiny)
pipe(tiny, tinypeer)
tiny:take()
tinypeer:take()

tiny:segment(seg({ flags = tcp4.ACK, seq = tiny.rcv_nxt, ack = tiny.snd_nxt,
    data = string.rep("z", 100) }))

local full = tiny:take()

is(#full, 1, "a full buffer still acknowledges")
is(full[1].wnd, 0, "and advertises a closed window")

-- a zero-length segment at exactly rcv_nxt must still be accepted
-- against a zero window, or a peer probing us can never be answered and
-- the connection stalls for good.
tiny:segment(seg({ flags = tcp4.ACK, seq = tiny.rcv_nxt,
    ack = tiny.snd_nxt }))
is(#tiny:take(), 0, "a probe at the window edge is accepted, not refused")

is(#tiny:read(50), 50, "reading makes room")

local reopened = tiny:take()

is(#reopened, 1, "which is announced to the peer")
ok(reopened[1] and reopened[1].wnd >= 50, "with the window reopened")

-- ---- the codec and the state machine compose ----
--
-- Everything above hands segments across as tables, which is the point
-- of a sans-io design but means nothing here has been through a wire
-- format. One handshake on real bytes, so that a disagreement between
-- the two modules cannot hide until it is on a network.
local w1, w2 = newA(), newB()

w1:connect()
w2:listen()

local function wire(from, to, src, dst)
	for _, s in ipairs(from:take()) do
		local bytes = tcp4.encode(s, src, dst)
		local back = tcp4.decode(bytes, src, dst)

		if not back then
			return false
		end
		to:segment(back)
	end
	return true
end

ok(wire(w1, w2, A_IP, B_IP), "a SYN survives the wire")
ok(wire(w2, w1, B_IP, A_IP), "so does the SYN,ACK")
ok(wire(w1, w2, A_IP, B_IP), "and the final ACK")
is(w1.state, tcb.ESTABLISHED, "leaving the opener established")
is(w2.state, tcb.ESTABLISHED, "and the listener too")

w1:write("over the wire")
ok(wire(w1, w2, A_IP, B_IP), "data encodes and decodes")
is(w2:read(), "over the wire", "and arrives intact")


-- ---- reassembly ----
--
-- A hole is the normal consequence of one lost segment, and what a
-- stack does about it decides whether that loss costs one
-- retransmission or the whole window. Holding what arrives behind the
-- hole is the difference.

local function connected(ca, cb)
	local x, y = newA(ca), newB(cb)

	x:connect()
	y:listen()
	pipe(x, y)
	pipe(y, x)
	pipe(x, y)
	x:take()
	y:take()
	x:events()
	y:events()
	return x, y
end

local ra = connected()
local r0 = ra.rcv_nxt

ra:segment(seg({ flags = tcp4.ACK, seq = tcp4.add(r0, 3),
    ack = ra.snd_nxt, data = "def" }))
is(ra:read(), "", "a segment behind a hole is not delivered")
is(ra:status().held, 1, "but it is held rather than dropped")

ra:segment(seg({ flags = tcp4.ACK, seq = r0, ack = ra.snd_nxt,
    data = "abc" }))
is(ra:read(), "abcdef", "and is released in order when the hole fills")
is(ra:status().held, 0, "leaving nothing held")

-- one arrival can release several: the segments queue up behind the
-- hole in whatever order they turned up, and filling it must drain all
-- of them, not just the one immediately behind.
local rb = connected()
local b0 = rb.rcv_nxt

rb:segment(seg({ flags = tcp4.ACK, seq = tcp4.add(b0, 6),
    ack = rb.snd_nxt, data = "ghi" }))
rb:segment(seg({ flags = tcp4.ACK, seq = tcp4.add(b0, 3),
    ack = rb.snd_nxt, data = "def" }))
is(rb:status().held, 2, "two segments wait behind the hole")
rb:segment(seg({ flags = tcp4.ACK, seq = b0, ack = rb.snd_nxt,
    data = "abc" }))
is(rb:read(), "abcdefghi", "and one arrival releases them all")

-- a FIN can arrive out of order too, and must not end the stream early:
-- there is still data in front of it.
local rf = connected()
local f0 = rf.rcv_nxt

rf:segment(seg({ flags = tcp4.ACK | tcp4.FIN, seq = tcp4.add(f0, 3),
    ack = rf.snd_nxt }))
is(rf.state, tcb.ESTABLISHED, "a FIN behind a hole does not close anything")
rf:segment(seg({ flags = tcp4.ACK, seq = f0, ack = rf.snd_nxt,
    data = "abc" }))
is(rf.state, tcb.CLOSE_WAIT, "until the data in front of it arrives")
is(rf:read(), "abc", "and the data is delivered")
is(rf:read(), nil, "with the stream ended behind it")

-- the hold is bounded. A peer that sends everything except the segment
-- we are waiting for must not be able to spend our memory indefinitely;
-- over the bound a segment is dropped, which is what would have
-- happened anyway and costs one retransmission.
local rl = connected({ rcvbuf = 200 })
local l0 = rl.rcv_nxt

for i = 1, 10 do
	rl:segment(seg({ flags = tcp4.ACK, seq = tcp4.add(l0, i * 100),
	    ack = rl.snd_nxt, data = string.rep("q", 100) }))
end
ok(rl:status().held <= 2, "the out-of-order queue is bounded")

-- ---- retransmission ----

local x = connected()
local xseq = x.snd_nxt

x:write("hello", 1000)

local first = x:take()

is(#first, 1, "a write goes out once")
is(x:deadline(), 2000, "and arms the timer one RTO ahead")

x:tick(1500)
is(#x:take(), 0, "nothing is resent before the timer expires")

x:tick(2000)

local again = x:take()

is(#again, 1, "and exactly one segment when it does")
is(again[1].data, "hello", "carrying the same bytes")
is(again[1].seq, xseq, "from the same place in the sequence space")

-- RFC 6298 5.5: the timeout doubles. A stack that retries at a fixed
-- interval makes a congested link worse at exactly the wrong moment.
is(x:status().rto, 2000, "the timeout backs off")
is(x:deadline(), 4000, "and the next attempt is that much later")

x:tick(4000)
x:take()
is(x:status().rto, 4000, "and again")

-- an acknowledgment of everything outstanding turns the timer off
-- entirely (5.2). Leaving it armed is how a quiet connection
-- retransmits into silence.
x:segment(seg({ flags = tcp4.ACK, seq = x.rcv_nxt,
    ack = tcp4.add(xseq, 5) }), 4100)
is(x:deadline(), nil, "an acknowledgment of everything stops the timer")
is(x:status().retries, 0, "and forgets the backoff")

-- ---- the round trip estimate ----

-- The first measurement of a connection is the handshake's: the SYN
-- occupies sequence space, so it is timed like anything else. Done on a
-- raw pair rather than through connected(), which does the handshake at
-- time zero and would make the first sample zero.
local m, mpeer = newA(), newB()

m:connect(1000)
mpeer:listen()
pipe(m, mpeer)
m:segment(mpeer:take()[1], 1100)
is(m:status().srtt, 100, "the handshake is the first round trip measured")

-- and a later sample is smoothed rather than replacing it: RFC 6298's
-- alpha is 1/8, so a 300ms sample against a 100ms estimate moves it to
-- 125 and not to 300. A stack that tracked the last sample instead
-- would set its timeout from whichever segment happened to be slowest.
local mseq = m.snd_nxt

m:write("timed", 2000)
m:take()
m:segment(seg({ flags = tcp4.ACK, seq = m.rcv_nxt,
    ack = tcp4.add(mseq, 5) }), 2300)
is(m:status().srtt, 125, "and later ones are smoothed into it")

-- Karn's algorithm: no sample from a segment that was sent twice. An
-- acknowledgment does not say which transmission it answers, so a
-- sample taken here is as likely to be wrong by a whole RTO as right.
-- The estimate must come back unchanged, not merely unset -- the
-- handshake has already seeded it by this point.
local k = connected()
local before_karn = k:status().srtt
local kseq = k.snd_nxt

k:write("karn", 1000)
k:take()
k:tick(2000)
k:take()
k:segment(seg({ flags = tcp4.ACK, seq = k.rcv_nxt,
    ack = tcp4.add(kseq, 4) }), 2050)
is(k:status().srtt, before_karn,
    "no round trip is measured from a retransmission")

-- a peer that never answers is eventually declared gone rather than
-- retried forever.
local g = connected()

g:write("gone", 1000)

local t = 1000

for _ = 1, MAX_RETX_TRIES do
	t = t + 100000
	g:tick(t)
	g:take()
end
is(g.state, tcb.CLOSED, "a peer that never answers is given up on")
is(kinds(g), "reset", "and the user is told")

-- ---- closing ----

local c1 = connected({ msl = 100 })

c1:close(0)

local fin = c1:take()

is(#fin, 1, "close sends one segment")
ok((fin[1].flags & tcp4.FIN) ~= 0, "and it carries a FIN")
is(c1.state, tcb.FIN_WAIT_1, "leaving us in FIN-WAIT-1")

c1:segment(seg({ flags = tcp4.ACK, seq = c1.rcv_nxt, ack = c1.snd_nxt }), 10)
is(c1.state, tcb.FIN_WAIT_2, "an acknowledgment of our FIN reaches FIN-WAIT-2")

c1:segment(seg({ flags = tcp4.ACK | tcp4.FIN, seq = c1.rcv_nxt,
    ack = c1.snd_nxt }), 20)
is(c1.state, tcb.TIME_WAIT, "and the peer's FIN reaches TIME-WAIT")

-- TIME-WAIT is not idling. A retransmitted FIN means our last
-- acknowledgment was lost, and it has to be sent again -- which is half
-- of why the state exists at all.
c1:take()
c1:segment(seg({ flags = tcp4.ACK | tcp4.FIN,
    seq = tcp4.add(c1.rcv_nxt, 0 - 1), ack = c1.snd_nxt }), 30)
is(#c1:take(), 1, "a retransmitted FIN is acknowledged again")
is(c1:deadline(), 30 + 200, "and the wait starts over")

c1:tick(30 + 200)
is(c1.state, tcb.CLOSED, "and after 2*MSL the connection is gone")

-- the other order: they close first, we keep writing, then we close.
local c2, peer2 = connected()

c2:segment(seg({ flags = tcp4.ACK | tcp4.FIN, seq = c2.rcv_nxt,
    ack = c2.snd_nxt }), 0)
is(c2.state, tcb.CLOSE_WAIT, "their FIN puts us in CLOSE-WAIT")
is(c2:write("still here"), 10, "where we may still write")

c2:close(10)
is(c2.state, tcb.LAST_ACK, "and closing goes to LAST-ACK")

c2:take()
c2:segment(seg({ flags = tcp4.ACK, seq = c2.rcv_nxt, ack = c2.snd_nxt }), 20)
is(c2.state, tcb.CLOSED, "an acknowledgment of our FIN ends it")
ok(peer2 ~= nil, "the peer object survives its connection")

-- both close at once: neither FIN is acknowledged when the other
-- arrives, which is the only way to reach CLOSING.
local s1 = connected({ msl = 100 })

s1:close(0)
s1:take()
s1:segment(seg({ flags = tcp4.ACK | tcp4.FIN, seq = s1.rcv_nxt,
    ack = tcp4.add(s1.snd_nxt, 0 - 1) }), 5)
is(s1.state, tcb.CLOSING, "a simultaneous close reaches CLOSING")
s1:segment(seg({ flags = tcp4.ACK, seq = s1.rcv_nxt, ack = s1.snd_nxt }), 10)
is(s1.state, tcb.TIME_WAIT, "and then TIME-WAIT once our FIN is acknowledged")

-- close means "no more data from me", not "discard what I gave you".
-- A client that writes a request and closes must still have the request
-- arrive, which is what makes close different from abort.
local d1, d2 = connected()

d1:write("request")
d1:close(0)

local closing = pipe(d1, d2)
local carried = 0

for _, sg in ipairs(closing) do
	carried = carried + #(sg.data or "")
end
is(carried, 7, "everything written before a close still goes out")
is(d2:read(), "request", "and arrives")
is(d2.state, tcb.CLOSE_WAIT, "with the FIN behind it")

-- abort is the other one: nothing is delivered and the peer is told at
-- once.
local a1 = connected()

a1:write("never mind")
a1:take()
a1:abort(0)

local rstout = a1:take()

is(#rstout, 1, "an abort sends one segment")
ok((rstout[1].flags & tcp4.RST) ~= 0, "and it is a reset")
is(a1.state, tcb.CLOSED, "with the connection gone immediately")


-- ---- close must deliver what it was given ----
--
-- The one that got away, and the shape of it is worth keeping. close()
-- called _transmit() and then sent the FIN outright, with a comment
-- saying that delivered everything queued. _transmit sends what the
-- WINDOW allows, so anything larger than the window left data in the
-- send queue, the FIN went out ahead of it, and the state moved to
-- FIN-WAIT-1 where _transmit does nothing at all. The tail could never
-- leave, and the peer saw a FIN it had every reason to call a clean end
-- of stream.
--
-- It cost every http response over about 4KB on both platforms, in
-- silence, and no test noticed because none asked for a body bigger
-- than the initial congestion window. Hence the sizes below: 4096
-- passed throughout, so one small case would have gone on passing.
do
	for _, size in ipairs({ 1024, 4096, 8192, 65536 }) do
		local a, b = newA({ sndbuf = 256 * 1024 }),
		    newB({ rcvbuf = 256 * 1024 })

		a:connect()
		b:listen()
		pipe(a, b)
		pipe(b, a)
		pipe(a, b)
		a:events()
		b:events()

		local payload = string.rep("x", size)

		is(a:write(payload), size, size .. " bytes are accepted")
		a:close(0)

		-- deliver until it settles: the window opens as b
		-- acknowledges, and each opening lets more of the queue out.
		local got = {}
		local total = 0

		for _ = 1, 200 do
			pipe(a, b)
			pipe(b, a)

			local d = b:read()

			while d ~= nil and d ~= "" do
				got[#got + 1] = d
				total = total + #d
				d = b:read()
			end
			if b.fin_rcvd then
				break
			end
		end

		is(total, size, "and all " .. size .. " arrive after a close")
		ok(table.concat(got) == payload, "byte for byte at " .. size)
		ok(b.fin_rcvd, "with the FIN behind them, not in front")
	end
end

-- and the FIN is not merely late: nothing may be written after close,
-- or it would land after a FIN already promised to the peer.
do
	local a, b = newA({ sndbuf = 256 * 1024 }), newB()

	a:connect()
	b:listen()
	pipe(a, b)
	pipe(b, a)
	pipe(a, b)
	a:events()
	b:events()

	a:write(string.rep("q", 40000))
	a:close(0)
	ok(a:status().fin_pending, "a close with data queued leaves the FIN pending")
	is(a:write("more"), nil, "and refuses anything written after it")
	ok(not a:status().fin_sent, "the FIN itself has not gone yet")
end

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
