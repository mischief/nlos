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

local A_IP, B_IP = "\10\0\0\1", "\10\0\0\2"
local ISS_A, ISS_B = 0x10000, 0x900000

local function newA(cfg)
	cfg = cfg or {}
	return tcb.new({ laddr = A_IP, lport = 40000,
	    raddr = B_IP, rport = 80,
	    iss = cfg.iss or ISS_A, mss = cfg.mss or 1460,
	    rcvbuf = cfg.rcvbuf, sndbuf = cfg.sndbuf })
end

local function newB(cfg)
	cfg = cfg or {}
	return tcb.new({ laddr = B_IP, lport = 80,
	    raddr = A_IP, rport = 40000,
	    iss = cfg.iss or ISS_B, mss = cfg.mss or 1460,
	    rcvbuf = cfg.rcvbuf, sndbuf = cfg.sndbuf })
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

-- the receiver must acknowledge data it took responsibility for, or the
-- sender will send it again forever.
local acks = b:take()

is(#acks, 1, "taking data produces an acknowledgment")
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

-- a segment from the future: reassembly is not implemented yet, so it
-- is dropped and the peer is told what we actually want. Asserted
-- rather than left implicit, because when reassembly lands this test is
-- the one that must change.
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

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
