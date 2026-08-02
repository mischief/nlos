-- one TCP connection, as a state machine that touches nothing.
--
-- The Transmission Control Block of RFC 9293 section 3.3.1, and the
-- event processing of 3.10.7, with no wire under it and no message loop
-- around it. Segments arrive by being handed to :segment(); segments
-- leave by being left in a list for :take() to collect. Time arrives as
-- an argument. Nothing here calls sys, opens a port, or knows that
-- lib/ip4.lua exists.
--
-- That is the whole design, and the reason for it is testability rather
-- than taste. The cases most likely to be wrong are the ones no real
-- peer will produce on request: a simultaneous open, a RST arriving in
-- SYN-RECEIVED, an acknowledgment of something never sent, a sequence
-- number that laps the space. Against OpenBSD those are unreachable.
-- Against this they are three lines and a table.
--
-- What is here: the eleven states, active and passive open, data in
-- both directions with out-of-order segments held and reassembled, the
-- retransmission timer of RFC 6298 including Karn's algorithm, and the
-- full four-way close with TIME-WAIT.
--
-- Congestion control is RFC 5681 -- slow start, congestion avoidance,
-- fast retransmit and fast recovery -- with RFC 6582's NewReno rule for
-- the partial acknowledgment, which is what recovers a second loss in
-- the same window without waiting out a timeout.
--
-- What is deliberately not here: Nagle, delayed acknowledgments, the
-- sender's half of silly-window avoidance, and SACK. The first three
-- make an implementation politer rather than more correct; SACK is a
-- real improvement and a separate piece of work.
--
-- Names follow the RFC, in lower case: snd_una is SND.UNA. Keeping them
-- recognisable matters more than keeping them pretty, because every
-- question about this file is answered by reading the RFC next to it.

local tcp4 = require("tcp4")

local tcb = {}

-- The states, as strings rather than numbers. A number in a log or a
-- test failure has to be looked up; "SYN-RECEIVED" does not, and this
-- is not a hot enough path to buy anything back for the difference.
tcb.CLOSED = "CLOSED"
tcb.LISTEN = "LISTEN"
tcb.SYN_SENT = "SYN-SENT"
tcb.SYN_RECEIVED = "SYN-RECEIVED"
tcb.ESTABLISHED = "ESTABLISHED"
tcb.FIN_WAIT_1 = "FIN-WAIT-1"
tcb.FIN_WAIT_2 = "FIN-WAIT-2"
tcb.CLOSE_WAIT = "CLOSE-WAIT"
tcb.CLOSING = "CLOSING"
tcb.LAST_ACK = "LAST-ACK"
tcb.TIME_WAIT = "TIME-WAIT"

-- What we will hold for a reader that has not called read() yet, and
-- what we will accept from a writer before saying "no more". Both are
-- ordinary socket buffer sizes and both are advisory to the caller,
-- which may pass its own.
local RCVBUF_DEFAULT = 32 * 1024
local SNDBUF_DEFAULT = 32 * 1024

-- The receive window goes on the wire as sixteen bits. Until window
-- scaling is offered (RFC 7323, deliberately deferred), a buffer larger
-- than this simply cannot be advertised, so the advertisement is capped
-- rather than silently truncated -- a wrapped window field would invite
-- the peer to overrun us by exactly as much as we failed to say.
local WND_MAX = 0xffff

-- ---- retransmission, RFC 6298 ----
--
-- The constants are the RFC's, including the one that looks wrong: the
-- minimum RTO is a whole second (2.4, SHOULD) even on a link where the
-- round trip is measured in microseconds. It is not a latency budget
-- but a floor on how soon a stack is willing to conclude that a segment
-- is lost, and setting it by the observed round trip is how a stack
-- retransmits into a link that was merely busy.
local RTO_INIT = 1000
local RTO_MIN = 1000
local RTO_MAX = 60000
local RTT_K = 4			-- RTO = SRTT + K * RTTVAR

-- How many times a segment is resent before the connection is declared
-- dead. With binary backoff from a second, eight attempts is a little
-- over four minutes of trying, which comfortably clears RFC 1122's R2
-- of 100 seconds.
local MAX_RETX = 8

-- ---- congestion control, RFC 5681 ----
--
-- The initial window, from 3.1's table. It is expressed in segments
-- rather than the older 4380-byte formula because that is what the RFC
-- now says, and for the 1460-byte mss on an ethernet the two agree at
-- three segments anyway.
local function initial_cwnd(smss)
	if smss > 2190 then
		return 2 * smss
	elseif smss > 1095 then
		return 3 * smss
	end
	return 4 * smss
end

-- ssthresh starts "arbitrarily high" (3.1) so that the network rather
-- than a number in this file decides the sending rate. It comes down
-- the first time congestion is seen and never goes back up on its own.
local SSTHRESH_INIT = 0xffffffff

-- three duplicate acknowledgments mean a segment is gone rather than
-- merely reordered. Two is not enough -- ordinary reordering produces
-- two routinely -- and waiting for more costs a round trip per loss.
local DUPACK_THRESH = 3

-- 2*MSL in TIME-WAIT. The RFC's MSL is two minutes, making the wait
-- four; nothing in practice waits that long, and 30 seconds is what the
-- unixes settled on. Configurable because a test cannot wait either.
local MSL_DEFAULT = 30000

local T = {}

T.__index = T

-- cfg: { laddr, lport, raddr, rport, iss, mss, rcvbuf, sndbuf }
--
-- iss is required and is the caller's problem on purpose. RFC 6528 is
-- clear that it must not be a counter and must not be predictable from
-- another connection's: an off-path attacker who can guess it can inject
-- into the connection. The generator needs a clock and a secret, which
-- is to say it needs the machine, which is exactly what this file does
-- not have. task/tcp4.lua supplies it from the kernel's rng.
function tcb.new(cfg)
	local t = setmetatable({
		state = tcb.CLOSED,

		laddr = cfg.laddr, lport = cfg.lport,
		raddr = cfg.raddr, rport = cfg.rport,

		-- send sequence space (3.3.1, table 2)
		iss = cfg.iss,
		snd_una = cfg.iss,
		snd_nxt = cfg.iss,
		snd_wnd = 0,
		snd_wl1 = 0,
		snd_wl2 = 0,

		-- receive sequence space (table 3)
		irs = 0,
		rcv_nxt = 0,

		-- what we will send in one segment, and what we will accept.
		-- snd_mss is the peer's advertisement or the default the RFC
		-- requires us to assume without one (MUST-15); rcv_mss is what
		-- we advertise.
		snd_mss = tcp4.MSS_DEFAULT,
		rcv_mss = cfg.mss or tcp4.MSS_DEFAULT,

		rcvbuf = cfg.rcvbuf or RCVBUF_DEFAULT,
		sndbuf = cfg.sndbuf or SNDBUF_DEFAULT,

		-- data received in order and not yet read, as a list of
		-- strings: a Lua string is immutable, so appending to one
		-- copies the whole buffer every time and turns a stream into
		-- quadratic work. The list is concatenated only on read.
		rcvq = {},
		rcvbytes = 0,

		-- data the user has written, from snd_una onwards. What has
		-- been sent but not acknowledged is the first
		-- (snd_nxt - snd_una) bytes of it, which is where the
		-- retransmission queue will come from without needing a
		-- second copy of anything.
		sndq = "",

		-- segments that arrived ahead of a gap, held until the gap
		-- fills. Each is {seq=, data=, fin=}. Bounded, because a peer
		-- that sends everything except the one segment we are waiting
		-- for would otherwise cost us memory for as long as it liked.
		ooo = {},
		ooobytes = 0,

		-- the retransmission timer (RFC 6298). retx is when the
		-- earliest unacknowledged segment gives up waiting; nil means
		-- nothing is outstanding and the timer is off.
		rto = RTO_INIT,
		srtt = nil,
		rttvar = nil,
		retx = nil,
		retries = 0,

		-- what is being timed for an RTT sample, and since when. Karn's
		-- algorithm is the reason both are cleared on a retransmission:
		-- once a segment has been sent twice, an acknowledgment does
		-- not say which of them it is for, and a sample taken anyway is
		-- as likely to be wrong by a whole RTO as right.
		rtt_seq = nil,
		rtt_at = nil,

		-- congestion control (RFC 5681) and fast recovery (RFC 6582).
		-- cwnd waits until the peer's mss is known, since every
		-- quantity here is a multiple of it.
		cwnd = nil,
		ssthresh = SSTHRESH_INIT,
		dupacks = 0,
		in_recovery = false,
		-- RFC 6582 step 1: recover starts at the initial send
		-- sequence number, and is what stops one lost window from
		-- being fast-retransmitted over and over.
		recover = cfg.iss,

		msl = cfg.msl or MSL_DEFAULT,
		timewait = nil,

		now = 0,

		passive = false,
		fin_rcvd = false,
		fin_sent = false,
		fin_seq = nil,

		out = {},
		ev = {},
	}, T)

	t.rcv_wnd = t:_window()
	return t
end

-- The amount of data outstanding in the network. Not cwnd, which the
-- RFC warns against confusing it with (3.1): cwnd is what we are
-- allowed to have outstanding, FlightSize is what we actually do.
function T:_flight()
	return tcp4.diff(self.snd_nxt, self.snd_una)
end

-- called once the peer's mss is known, which is the earliest the
-- initial window means anything.
function T:_init_cc()
	self.cwnd = initial_cwnd(self.snd_mss)
end

-- ---- what the caller collects ----

-- segments to put on the wire, and the list is emptied by the taking.
-- One call after every entry point, which is why every entry point can
-- append freely without thinking about who sends.
function T:take()
	local out = self.out

	self.out = {}
	return out
end

-- things that happened to the connection: "established", "closing",
-- "reset", "refused", "closed". Data is not an event -- it is read with
-- read() -- because a reader wants bytes, not notifications about them.
function T:events()
	local ev = self.ev

	self.ev = {}
	return ev
end

local function signal(self, kind, why)
	self.ev[#self.ev + 1] = { kind = kind, why = why }
end

-- ---- windows and segments ----

-- What we can still take. The advertisement shrinks as unread data
-- piles up and opens again when the reader catches up, which is the
-- whole of flow control before silly-window avoidance is added.
function T:_window()
	local free = self.rcvbuf - self.rcvbytes

	if free < 0 then
		free = 0
	end
	if free > WND_MAX then
		free = WND_MAX
	end
	return free
end

-- queue a segment, filling in everything that is the same on all of
-- them. seq defaults to snd_nxt, which is right for everything except a
-- reset answering a bad acknowledgment.
--
-- Anything occupying sequence space starts the retransmission timer if
-- it is not already running (RFC 6298, 5.1) and is a candidate for an
-- RTT sample. A pure acknowledgment does neither: it is never resent,
-- so nothing would ever turn the timer off again.
function T:_send(flags, data, seq)
	self.rcv_wnd = self:_window()

	local s = {
		sport = self.lport, dport = self.rport,
		seq = seq or self.snd_nxt,
		ack = self.rcv_nxt,
		flags = flags,
		wnd = self.rcv_wnd,
		data = data,
	}

	self.out[#self.out + 1] = s

	if tcp4.seglen(s) > 0 then
		if not self.retx then
			self.retx = self.now + self.rto
		end
		-- one sample in flight at a time, which is all RFC 6298 asks
		-- for (3.1: at most one per round trip).
		if not self.rtt_seq then
			self.rtt_seq = tcp4.add(s.seq, tcp4.seglen(s))
			self.rtt_at = self.now
		end
	end
	return s
end

-- RFC 6298 section 2, both cases: the first measurement seeds the
-- estimators, later ones smooth them.
function T:_sample_rtt(r)
	if not self.srtt then
		self.srtt = r
		self.rttvar = r / 2
	else
		-- beta = 1/4, alpha = 1/8. The variance is updated first,
		-- deliberately: it uses the old SRTT, and updating them the
		-- other way round quietly changes the filter.
		self.rttvar = 0.75 * self.rttvar + 0.25 * math.abs(self.srtt - r)
		self.srtt = 0.875 * self.srtt + 0.125 * r
	end

	local rto = self.srtt + RTT_K * self.rttvar

	if rto < RTO_MIN then
		rto = RTO_MIN
	end
	if rto > RTO_MAX then
		rto = RTO_MAX
	end
	self.rto = math.floor(rto)
end

-- <SEQ=SND.NXT><ACK=RCV.NXT><CTL=ACK>, which the RFC asks for in so
-- many places that it is worth a name. It is also the challenge ACK of
-- RFC 5961, which is the same segment sent for a different reason.
function T:_ack()
	self:_send(tcp4.ACK)
end

-- <SEQ=SEG.ACK><CTL=RST>: a reset that the offending peer will accept,
-- because it is sitting at a sequence number that peer already believes
-- in. No ACK bit, since we are acknowledging nothing.
function T:_reset(ack)
	self.out[#self.out + 1] = {
		sport = self.lport, dport = self.rport,
		seq = ack,
		ack = 0,
		flags = tcp4.RST,
		wnd = 0,
	}
end

-- the connection is over and there is nothing to say about it on the
-- wire. Buffers go, because holding data for a connection that cannot
-- deliver it is just a leak with a story attached.
function T:_dead(kind, why)
	self.state = tcb.CLOSED
	self.sndq = ""
	self.rcvq = {}
	self.rcvbytes = 0
	signal(self, kind, why)
end

-- ---- opening ----

-- active open: CLOSED -> SYN-SENT.
function T:connect(now)
	self.now = now or self.now

	if self.state ~= tcb.CLOSED then
		return nil, "not closed"
	end

	self.passive = false
	self.state = tcb.SYN_SENT
	self.snd_una = self.iss
	self.snd_nxt = tcp4.add(self.iss, 1)
	-- rcv_nxt is not known yet, so the ack field of this SYN is zero
	-- and carries no ACK bit. _send fills it from rcv_nxt, which is
	-- still 0 -- correct, and the flags are what make it meaningless.
	self:_send(tcp4.SYN, nil, self.iss)
	self.out[#self.out].opt = { mss = self.rcv_mss }
	return true
end

-- "I have no more data to send", which is all CLOSE means (3.6). The
-- receiving half stays open: the peer may still be sending, and a user
-- that closes must keep reading until told the stream ended. That
-- asymmetry is why this is not called shutdown -- there is only one
-- direction to close here, and it is ours.
function T:close(now)
	self.now = now or self.now

	if self.fin_sent then
		return true		-- already said so
	end

	if self.state == tcb.CLOSED or self.state == tcb.LISTEN then
		self.state = tcb.CLOSED
		return true
	end

	if self.state == tcb.SYN_SENT then
		-- nothing was ever established, so there is nothing to close
		-- politely and nobody who would understand a FIN.
		self:_dead("closed")
		return true
	end

	-- everything still queued goes out first: the RFC is explicit that
	-- a close delivers what was already sent (3.6), which is what lets
	-- a client write a request, close, and still expect it to arrive.
	self:_transmit()
	self:_send_fin()

	if self.state == tcb.CLOSE_WAIT then
		self.state = tcb.LAST_ACK
	else
		self.state = tcb.FIN_WAIT_1
	end
	return true
end

-- The FIN occupies one sequence number, which is what makes it
-- acknowledgeable and retransmittable like data. Recording where it
-- sits is how we later recognise the acknowledgment of it.
function T:_send_fin()
	self.fin_sent = true
	self.fin_seq = self.snd_nxt
	self:_send(tcp4.ACK | tcp4.FIN)
	self.snd_nxt = tcp4.add(self.snd_nxt, 1)
end

-- give up on the connection now and tell the peer why. Unlike close
-- this discards anything queued, which is the difference between ABORT
-- and CLOSE in 3.9.1 and the reason both exist.
function T:abort(now)
	self.now = now or self.now

	if self.state ~= tcb.CLOSED and self.state ~= tcb.LISTEN then
		self:_send(tcp4.RST | tcp4.ACK)
	end
	self:_dead("closed")
	return true
end

-- passive open: CLOSED -> LISTEN.
function T:listen()
	if self.state ~= tcb.CLOSED then
		return nil, "not closed"
	end
	self.passive = true
	self.state = tcb.LISTEN
	return true
end

-- ---- the user's data ----

-- Accepts what fits and reports how much, the way a non-blocking write
-- on a socket does. Short is not an error: the caller writes the rest
-- when the window and the buffer allow, and a caller that treats short
-- as failure would have been broken by a slow peer anyway.
function T:write(data, now)
	self.now = now or self.now

	if self.state ~= tcb.ESTABLISHED and self.state ~= tcb.CLOSE_WAIT then
		return nil, "not connected"
	end

	local room = self.sndbuf - #self.sndq

	if room <= 0 then
		return 0
	end
	if #data > room then
		data = data:sub(1, room)
	end
	self.sndq = self.sndq .. data
	self:_transmit()
	return #data
end

-- Up to max bytes of what arrived in order. Returns nil once the peer
-- has closed and nothing is left, which is how a reader learns the
-- stream ended rather than merely paused -- the same distinction
-- read() returning 0 makes on a unix.
function T:read(max)
	if self.rcvbytes == 0 then
		if self.fin_rcvd then
			return nil
		end
		return ""
	end

	local all = table.concat(self.rcvq)
	local n = max and math.min(max, #all) or #all
	local out = all:sub(1, n)
	local rest = all:sub(n + 1)

	self.rcvq = #rest > 0 and { rest } or {}
	self.rcvbytes = #rest

	-- The window just opened, and whether to say so is a real decision
	-- rather than a courtesy. Announcing every read means an extra
	-- segment per read -- five bytes consumed, a window update sent --
	-- which is receiver silly-window syndrome, the stable pattern of
	-- tiny window movements that 3.8.6.2.2 exists to prevent. Saying
	-- nothing instead risks a sender parked on a window it thinks is
	-- still closed.
	--
	-- The RFC's rule settles it: advertise when the space we have not
	-- yet offered is worth offering, which is half the buffer or one
	-- segment, whichever is smaller. Below that, the update rides out
	-- on the next acknowledgment we were sending anyway.
	--
	-- The rest of silly-window avoidance -- the sender's half, Nagle,
	-- delayed ACKs -- is deliberately later work. This much is here
	-- because without it every read costs a segment, which is not a
	-- politeness problem but a throughput one.
	local unoffered = self.rcvbuf - self.rcvbytes - self.rcv_wnd

	if self.state == tcb.ESTABLISHED and
	    unoffered >= math.min(self.rcvbuf // 2, self.snd_mss) then
		self:_ack()
	end
	return out
end

-- as much of the send buffer as the window and the mss allow.
function T:_transmit()
	if self.state ~= tcb.ESTABLISHED and self.state ~= tcb.CLOSE_WAIT then
		return
	end

	while true do
		-- diff and not subtraction: these are sequence numbers, and
		-- the connection that has been up long enough to wrap is
		-- exactly the one nobody tests.
		local sent = tcp4.diff(self.snd_nxt, self.snd_una)
		local unsent = #self.sndq - sent
		-- "The minimum of cwnd and rwnd governs data transmission"
		-- (5681 3.1). Before this, the receiver's window was the only
		-- limit, so a connection opened by sending the peer's whole
		-- advertised window as fast as segments could be built -- some
		-- forty of them back to back, into a path nothing had measured.
		local win = self.snd_wnd

		if self.cwnd and self.cwnd < win then
			win = self.cwnd
		end

		local room = win - sent

		if unsent <= 0 or room <= 0 then
			return
		end

		local n = math.min(unsent, room, self.snd_mss)
		local chunk = self.sndq:sub(sent + 1, sent + n)
		-- push when this empties the buffer: it tells the peer's
		-- application that there is no more coming for now, which is
		-- what makes a request/reply protocol above us prompt.
		local flags = tcp4.ACK

		if n == unsent then
			flags = flags | tcp4.PSH
		end
		self:_send(flags, chunk)
		self.snd_nxt = tcp4.add(self.snd_nxt, n)
	end
end

-- ---- segment arrival ----

-- 3.10.7.4's first step, table 6, all four cases. The one worth reading
-- twice is a zero-length segment against a zero window: it must still be
-- accepted at exactly rcv_nxt, or a peer probing a closed window can
-- never be answered and the connection stalls forever.
function T:_acceptable(seg)
	local len = tcp4.seglen(seg)
	local wnd = self.rcv_wnd
	local last = tcp4.add(self.rcv_nxt, wnd)

	if len == 0 then
		if wnd == 0 then
			return seg.seq == self.rcv_nxt
		end
		return tcp4.between(seg.seq, self.rcv_nxt, last)
	end

	if wnd == 0 then
		return false
	end
	return tcp4.between(seg.seq, self.rcv_nxt, last) or
	    tcp4.between(tcp4.add(seg.seq, len - 1), self.rcv_nxt, last)
end

-- 3.10.7.2. A listening connection has nothing to reset and nothing to
-- acknowledge, so almost everything is either ignored or refused.
function T:_in_listen(seg)
	if (seg.flags & tcp4.RST) ~= 0 then
		return		-- could not have been provoked by us
	end

	if (seg.flags & tcp4.ACK) ~= 0 then
		-- an acknowledgment on a connection that has sent nothing is
		-- always wrong, whoever sent it.
		self:_reset(seg.ack)
		return
	end

	if (seg.flags & tcp4.SYN) == 0 then
		return		-- unreachable in practice; see the RFC's note
	end

	self.irs = seg.seq
	self.rcv_nxt = tcp4.add(seg.seq, 1)
	self.rport = seg.sport
	self.snd_mss = seg.opt and seg.opt.mss or tcp4.MSS_DEFAULT
	self:_init_cc()
	self.snd_wnd = seg.wnd
	self.snd_wl1 = seg.seq
	self.snd_wl2 = seg.ack

	self.snd_una = self.iss
	self.snd_nxt = tcp4.add(self.iss, 1)
	self.state = tcb.SYN_RECEIVED
	self:_send(tcp4.SYN | tcp4.ACK, nil, self.iss)
	self.out[#self.out].opt = { mss = self.rcv_mss }
end

-- 3.10.7.3, in the RFC's order: ACK, then RST, then SYN. The order is
-- not incidental -- whether a RST is believed depends on whether the
-- acknowledgment that came with it was acceptable, so the ACK has to be
-- judged first.
function T:_in_syn_sent(seg)
	local acked = false

	if (seg.flags & tcp4.ACK) ~= 0 then
		-- our SYN is the only thing outstanding, so an acknowledgment
		-- outside (ISS, SND.NXT] is for a connection that is not this
		-- one.
		if tcp4.le(seg.ack, self.iss) or tcp4.gt(seg.ack, self.snd_nxt) then
			if (seg.flags & tcp4.RST) == 0 then
				self:_reset(seg.ack)
			end
			return
		end
		acked = true
	end

	if (seg.flags & tcp4.RST) ~= 0 then
		-- only a reset that acknowledged our SYN can be believed;
		-- otherwise anyone able to guess the port pair could hang up
		-- on us.
		if acked then
			self:_dead("refused", "connection refused")
		end
		return
	end

	if (seg.flags & tcp4.SYN) == 0 then
		return
	end

	self.irs = seg.seq
	self.rcv_nxt = tcp4.add(seg.seq, 1)
	self.snd_mss = seg.opt and seg.opt.mss or tcp4.MSS_DEFAULT
	self:_init_cc()

	if acked then
		self.snd_una = seg.ack
		self:_acked(seg)
	end

	if tcp4.gt(self.snd_una, self.iss) then
		-- our SYN is acknowledged: the ordinary case.
		self.state = tcb.ESTABLISHED
		self.snd_wnd = seg.wnd
		self.snd_wl1 = seg.seq
		self.snd_wl2 = seg.ack
		self:_ack()
		signal(self, "established")
		self:_transmit()
		return
	end

	-- a SYN with no acknowledgment of ours: both ends called connect
	-- at once. Rare enough to be untested everywhere and cheap enough
	-- to get right here, which is the argument for this file existing.
	self.state = tcb.SYN_RECEIVED
	self.snd_wnd = seg.wnd
	self.snd_wl1 = seg.seq
	self.snd_wl2 = seg.ack
	self:_send(tcp4.SYN | tcp4.ACK, nil, self.iss)
	self.out[#self.out].opt = { mss = self.rcv_mss }
end

-- Retransmit the first unacknowledged segment, and only that.
--
-- Shared by fast retransmit and by NewReno's partial-acknowledgment
-- rule. Unlike the timeout path it does not back the timer off or count
-- against MAX_RETX: this is a segment we have good evidence was lost,
-- not a peer that has gone quiet.
function T:_resend_first()
	local n = math.min(#self.sndq, self.snd_mss)
	local flags = tcp4.ACK
	local data = n > 0 and self.sndq:sub(1, n) or nil

	if self.fin_sent and n == #self.sndq then
		flags = flags | tcp4.FIN
	end
	if not data and (flags & tcp4.FIN) == 0 then
		return false
	end
	self:_send(flags, data, self.snd_una)

	-- Karn again, and for the same reason as in _retransmit: _send has
	-- just started timing a segment that is going out for the second
	-- time, and an acknowledgment of it cannot say which copy it is for.
	self.rtt_seq = nil
	self.rtt_at = nil
	return true
end

-- Is this the duplicate acknowledgment fast retransmit counts?
--
-- RFC 5681 section 2 is precise about it, and the precision is the
-- point: an acknowledgment that carries data, or moves the window, or
-- arrives with nothing outstanding, is not evidence of a lost segment
-- and counting it as one retransmits perfectly good data.
function T:_is_dupack(seg)
	return seg.ack == self.snd_una and
	    tcp4.seglen(seg) == 0 and
	    (seg.flags & (tcp4.SYN | tcp4.FIN)) == 0 and
	    seg.wnd == self.snd_wnd and
	    self:_flight() > 0
end

-- 5681 3.2 steps 2 and 3, with 6582's guard in front of them.
function T:_fast_retransmit()
	-- RFC 6582 step 2: only if the acknowledgment covers more than
	-- recover. Without this check a single lost window is fast
	-- retransmitted once per duplicate burst, halving ssthresh each
	-- time until the connection is crawling for no reason.
	if not tcp4.gt(self.snd_una, self.recover) then
		return
	end

	self.recover = self.snd_nxt
	self.in_recovery = true
	self.ssthresh = math.max(self:_flight() // 2, 2 * self.snd_mss)
	self:_resend_first()
	-- inflated by the three segments that have left the network and
	-- which the receiver is holding: that is what the duplicates were
	-- telling us.
	self.cwnd = self.ssthresh + DUPACK_THRESH * self.snd_mss
end

-- the bookkeeping every acknowledgment of new data owes, wherever it
-- was processed. SYN-SENT does its own ack handling rather than going
-- through _check_ack, and forgetting this there left the timer armed
-- from the SYN for the life of the connection -- so an established
-- connection with nothing outstanding would eventually retransmit into
-- a peer that had said everything it had to say.
function T:_acked(seg, acked)
	acked = acked or 0

	-- ---- congestion window (5681 3.1, 6582 3.2 step 3) ----
	if self.cwnd then
		if self.in_recovery then
			if tcp4.ge(seg.ack, self.recover) then
				-- a full acknowledgment: everything outstanding
				-- when we entered recovery is gone from the
				-- network. Deflate to ssthresh and leave.
				self.cwnd = self.ssthresh
				self.in_recovery = false
			else
				-- a partial acknowledgment. Something else in the
				-- same window was lost, so resend the next one
				-- rather than waiting a whole RTO to discover it
				-- -- which is the entire difference between
				-- NewReno and Reno.
				self:_resend_first()
				self.cwnd = self.cwnd - acked
				if acked >= self.snd_mss then
					self.cwnd = self.cwnd + self.snd_mss
				end
				if self.cwnd < self.snd_mss then
					self.cwnd = self.snd_mss
				end
				-- 6582 step 3: the first partial ack also
				-- restarts the retransmission timer, so a second
				-- loss in the window does not inherit the
				-- deadline set for the first.
				self.retx = self.now + self.rto
			end
		elseif self.cwnd < self.ssthresh then
			-- slow start, by appropriate byte counting (equation
			-- 2) rather than a flat segment per ack: a receiver
			-- that acknowledged one segment in several pieces
			-- could otherwise inflate the window several times
			-- over for data it only received once.
			self.cwnd = self.cwnd + math.min(acked, self.snd_mss)
		else
			-- congestion avoidance, equation 3, rounded up to a
			-- byte so integer arithmetic cannot stall the window
			-- entirely once cwnd exceeds SMSS squared.
			local inc = (self.snd_mss * self.snd_mss) // self.cwnd

			self.cwnd = self.cwnd + (inc > 0 and inc or 1)
		end
	end

	-- an acknowledgment of new data ends any run of duplicates.
	self.dupacks = 0

	-- an RTT sample, unless Karn forbids it. rtt_seq is cleared by
	-- every retransmission precisely so this cannot fire for a segment
	-- that was sent twice.
	if self.rtt_seq and tcp4.ge(seg.ack, self.rtt_seq) then
		self:_sample_rtt(self.now - self.rtt_at)
		self.rtt_seq = nil
		self.rtt_at = nil
	end

	-- RFC 6298 5.3: new data acknowledged restarts the timer, and 5.2:
	-- nothing outstanding turns it off. The backoff is forgotten here
	-- too -- it applies to one lost segment, not to the connection.
	self.retries = 0
	if tcp4.lt(self.snd_una, self.snd_nxt) then
		self.retx = self.now + self.rto
	else
		self.retx = nil
	end
end

-- the fifth step of 3.10.7.4, shared by every synchronized state.
-- Returns false when the segment must be dropped without further
-- processing.
function T:_check_ack(seg)
	if (seg.flags & tcp4.ACK) == 0 then
		return false
	end

	if self.state == tcb.SYN_RECEIVED then
		if tcp4.lt(self.snd_una, seg.ack) and
		    tcp4.le(seg.ack, self.snd_nxt) then
			self.state = tcb.ESTABLISHED
			self.snd_wnd = seg.wnd
			self.snd_wl1 = seg.seq
			self.snd_wl2 = seg.ack
			signal(self, "established")
		else
			self:_reset(seg.ack)
			return false
		end
	end

	if tcp4.gt(seg.ack, self.snd_nxt) then
		-- acknowledging something we never sent. Say what we really
		-- have and drop it; this is also the RFC 5961 shape.
		self:_ack()
		return false
	end

	if self:_is_dupack(seg) then
		self.dupacks = self.dupacks + 1

		if self.dupacks == DUPACK_THRESH then
			self:_fast_retransmit()
		elseif self.dupacks > DUPACK_THRESH and self.in_recovery then
			-- step 4: each further duplicate is another segment
			-- that has left the network, so the window may open
			-- by one more.
			self.cwnd = self.cwnd + self.snd_mss
			self:_transmit()
		end
		return true
	end

	if tcp4.lt(self.snd_una, seg.ack) then
		local n = tcp4.diff(seg.ack, self.snd_una)

		-- The SYN and the FIN each occupy a sequence number but no
		-- byte of the buffer, so what is dropped is the acknowledged
		-- span less whichever of them it covered. Getting this wrong
		-- eats a byte of the caller's data per control flag, which
		-- shows up as a stream that is subtly short rather than as
		-- anything that looks like a bug in TCP.
		local bytes = n

		if tcp4.le(self.snd_una, self.iss) and
		    tcp4.ge(seg.ack, tcp4.add(self.iss, 1)) then
			bytes = bytes - 1		-- our SYN
		end
		if self.fin_seq and tcp4.gt(seg.ack, self.fin_seq) then
			bytes = bytes - 1		-- our FIN
		end
		if bytes > 0 then
			self.sndq = self.sndq:sub(bytes + 1)
		end
		self.snd_una = seg.ack

		self:_acked(seg, n)
	end

	-- the window update, guarded so that a reordered segment cannot
	-- install an older window over a newer one (3.10.7.4, fifth step).
	if tcp4.lt(self.snd_wl1, seg.seq) or
	    (self.snd_wl1 == seg.seq and tcp4.le(self.snd_wl2, seg.ack)) then
		self.snd_wnd = seg.wnd
		self.snd_wl1 = seg.seq
		self.snd_wl2 = seg.ack
	end

	-- our FIN, if this acknowledged it. Strictly greater: the FIN sits
	-- at fin_seq and occupies it, so an acknowledgment of exactly
	-- fin_seq is for the byte before it.
	local finacked = self.fin_seq and tcp4.gt(seg.ack, self.fin_seq)

	if self.state == tcb.FIN_WAIT_1 and finacked then
		self.state = tcb.FIN_WAIT_2
	elseif self.state == tcb.CLOSING and finacked then
		self:_time_wait()
	elseif self.state == tcb.LAST_ACK and finacked then
		-- both sides have closed and both FINs are acknowledged.
		-- There is nothing left to wait for, and no TIME-WAIT: that
		-- belongs to whoever closed first, which was the peer.
		self:_dead("closed")
		return false
	end
	return true
end

-- TIME-WAIT exists so that a delayed duplicate from this connection
-- cannot be taken for part of the next one between the same two ports,
-- and so that a lost final acknowledgment can be resent. Both need the
-- connection to linger after it is otherwise finished.
function T:_time_wait()
	self.state = tcb.TIME_WAIT
	self.timewait = self.now + 2 * self.msl
	self.retx = nil
	self.sndq = ""
end

-- keep a segment that arrived ahead of the gap, for when the gap fills.
--
-- Bounded by the receive buffer, because a peer that sends everything
-- except the one segment we are waiting for would otherwise cost us
-- memory for as long as it cared to. Over the bound the segment is
-- dropped, which is exactly what would have happened without any of
-- this and costs only a retransmission.
function T:_hold(seg)
	local data = seg.data or ""
	local fin = (seg.flags & tcp4.FIN) ~= 0

	if #data == 0 and not fin then
		return
	end
	if self.ooobytes + #data > self.rcvbuf then
		return
	end

	-- a duplicate of something already held is not worth a second copy.
	for _, h in ipairs(self.ooo) do
		if h.seq == seg.seq and #h.data >= #data then
			return
		end
	end

	self.ooo[#self.ooo + 1] = { seq = seg.seq, data = data, fin = fin }
	self.ooobytes = self.ooobytes + #data
end

-- take everything held that is now contiguous with rcv_nxt. Repeated
-- until nothing more fits, since one arriving segment can bridge a gap
-- that releases several.
function T:_drain_held()
	local moved = true

	while moved do
		moved = false

		for i, h in ipairs(self.ooo) do
			local off = tcp4.diff(self.rcv_nxt, h.seq)

			if off >= 0 and off <= #h.data then
				local data = h.data:sub(off + 1)

				if #data > 0 then
					self.rcvq[#self.rcvq + 1] = data
					self.rcvbytes = self.rcvbytes + #data
					self.rcv_nxt = tcp4.add(self.rcv_nxt, #data)
				end
				if h.fin then
					self.rcv_nxt = tcp4.add(self.rcv_nxt, 1)
					self.fin_rcvd = true
				end
				self.ooobytes = self.ooobytes - #h.data
				table.remove(self.ooo, i)
				moved = true
				break
			elseif off > #h.data then
				-- entirely behind us now; it was a duplicate.
				self.ooobytes = self.ooobytes - #h.data
				table.remove(self.ooo, i)
				moved = true
				break
			end
		end
	end
end

-- where a FIN takes us, which depends entirely on what we had already
-- said ourselves. The four-way close is two independent two-way ones,
-- and this is the half the peer drives.
function T:_on_fin()
	signal(self, "closing")

	if self.state == tcb.ESTABLISHED or self.state == tcb.SYN_RECEIVED then
		-- they are done, we are not. The user may keep writing.
		self.state = tcb.CLOSE_WAIT
	elseif self.state == tcb.FIN_WAIT_1 then
		-- we both closed at about the same moment and neither FIN is
		-- acknowledged yet. This is the simultaneous close of figure
		-- 13, and the state it needs exists only for this case.
		self.state = tcb.CLOSING
	elseif self.state == tcb.FIN_WAIT_2 then
		self:_time_wait()
	elseif self.state == tcb.TIME_WAIT then
		-- a retransmitted FIN: our last acknowledgment was lost, so
		-- it is sent again and the wait starts over.
		self.timewait = self.now + 2 * self.msl
	end
end

-- the seventh and eighth steps: the data, and the FIN behind it.
function T:_text(seg)
	local data = seg.data or ""
	local consumed = false

	-- a retransmission may begin before rcv_nxt; only the new part is
	-- processed (3.10.7.4's "if a segment's contents straddle the
	-- boundary between old and new"). A segment beginning after
	-- rcv_nxt is a hole, and until reassembly lands it is dropped and
	-- the peer is told what we actually want.
	local off = tcp4.diff(self.rcv_nxt, seg.seq)

	if off < 0 then
		-- a hole in front of it. Held rather than dropped: the
		-- alternative is making the peer resend everything after a
		-- single loss, which on a link with any reordering at all
		-- turns one lost segment into a stall.
		--
		-- The acknowledgment still says rcv_nxt, because that is what
		-- we actually have -- without SACK there is no way to say
		-- "and also these". It is a duplicate ACK, which is precisely
		-- the signal fast retransmit reads.
		self:_hold(seg)
		self:_ack()
		return
	end
	if off > 0 then
		data = data:sub(off + 1)
	end

	if #data > 0 then
		local room = self.rcvbuf - self.rcvbytes

		if #data > room then
			data = data:sub(1, room)
		end
		if #data > 0 then
			self.rcvq[#self.rcvq + 1] = data
			self.rcvbytes = self.rcvbytes + #data
			self.rcv_nxt = tcp4.add(self.rcv_nxt, #data)
			consumed = true
		end
	end

	-- The FIN sits after the data, so it is only ours to process once
	-- everything before it has been taken. Accepting it early would
	-- acknowledge data we never received.
	if (seg.flags & tcp4.FIN) ~= 0 then
		local finseq = tcp4.add(seg.seq, #(seg.data or ""))

		if finseq == self.rcv_nxt then
			self.rcv_nxt = tcp4.add(self.rcv_nxt, 1)
			self.fin_rcvd = true
			consumed = true
		else
			self:_hold(seg)
		end
	end

	-- this segment may have bridged a gap, releasing everything that
	-- was waiting behind it.
	local before = self.rcv_nxt

	self:_drain_held()
	if self.rcv_nxt ~= before then
		consumed = true
	end

	if self.fin_rcvd and not self.fin_seen then
		self.fin_seen = true
		self:_on_fin()
	end

	if consumed then
		-- acknowledging is not optional: we have taken
		-- responsibility for the octets, and the peer will keep
		-- resending them until we say so.
		self:_ack()
	end
end

-- 3.10.7.4, for every state past SYN-SENT.
function T:_in_synchronized(seg)
	if not self:_acceptable(seg) then
		-- an unacceptable segment is answered with the truth about
		-- where we are, unless it is a reset -- answering a reset
		-- keeps two hosts talking forever.
		if (seg.flags & tcp4.RST) == 0 then
			-- A retransmitted FIN in TIME-WAIT arrives here rather
			-- than below, and the distinction matters. It sits one
			-- before rcv_nxt, because we already took it, so the
			-- acceptability test of 3.10.7.4 calls it an old
			-- duplicate -- while the TIME-WAIT text says to
			-- acknowledge it and restart the wait. Both are right:
			-- it is an old duplicate, and it is also the evidence
			-- that our last acknowledgment never arrived. Not
			-- restarting here is how a connection leaves TIME-WAIT
			-- while the peer is still asking to be let go of.
			if self.state == tcb.TIME_WAIT and
			    (seg.flags & tcp4.FIN) ~= 0 then
				self.timewait = self.now + 2 * self.msl
			end
			self:_ack()
		end
		return
	end

	if (seg.flags & tcp4.RST) ~= 0 then
		if self.state == tcb.SYN_RECEIVED and self.passive then
			-- back to where it came from; the user was never told
			-- there was a connection.
			self.state = tcb.LISTEN
			self.snd_una = self.iss
			self.snd_nxt = self.iss
			return
		end
		self:_dead("reset", "connection reset by peer")
		return
	end

	if (seg.flags & tcp4.SYN) ~= 0 then
		-- a SYN inside a synchronized connection is an error or an
		-- attack. RFC 5961's answer, which 9293 adopts, is to say
		-- where we are and drop it rather than to tear the
		-- connection down on the strength of one segment.
		self:_ack()
		return
	end

	if not self:_check_ack(seg) then
		return
	end

	if self.state == tcb.TIME_WAIT then
		-- the only thing that can arrive here is a retransmission of
		-- the peer's FIN, which means our last acknowledgment was
		-- lost. Send it again and start the wait over -- which is
		-- most of what TIME-WAIT is for.
		if (seg.flags & tcp4.FIN) ~= 0 then
			self.timewait = self.now + 2 * self.msl
		end
		self:_ack()
		return
	end

	if self.state ~= tcb.CLOSED then
		self:_text(seg)
	end

	-- an acknowledgment may have opened the window.
	self:_transmit()
end

-- ---- time ----

-- resend the earliest thing not acknowledged, and only that: RFC 6298
-- 5.4 is explicit that a timeout retransmits one segment, not the whole
-- window. Sending everything again is how a stack turns a single loss
-- into a burst on a link that was already struggling.
function T:_retransmit()
	self:_timeout_cc()
	self.retries = self.retries + 1

	if self.retries > MAX_RETX then
		-- eight attempts with binary backoff is over four minutes,
		-- which clears RFC 1122's R2. A peer that has not answered in
		-- that time is gone, and saying so beats retrying forever.
		self:_dead("reset", "connection timed out")
		return
	end

	if self.state == tcb.SYN_SENT then
		self:_send(tcp4.SYN, nil, self.iss)
		self.out[#self.out].opt = { mss = self.rcv_mss }
	elseif self.state == tcb.SYN_RECEIVED then
		self:_send(tcp4.SYN | tcp4.ACK, nil, self.iss)
		self.out[#self.out].opt = { mss = self.rcv_mss }
	else
		local n = math.min(#self.sndq, self.snd_mss)
		local flags = tcp4.ACK
		local data = n > 0 and self.sndq:sub(1, n) or nil

		-- the FIN rides along only when everything before it is in
		-- this segment; otherwise it would arrive ahead of data it
		-- is supposed to follow.
		if self.fin_sent and n == #self.sndq then
			flags = flags | tcp4.FIN
		end
		if data or (flags & tcp4.FIN) ~= 0 then
			self:_send(flags, data, self.snd_una)
		end
	end

	-- Karn's algorithm, and the order matters: _send would otherwise
	-- have just started timing the segment it resent. An acknowledgment
	-- of a segment sent twice does not say which transmission it is
	-- for, and a sample taken anyway is as likely to be wrong by a
	-- whole RTO as right.
	self.rtt_seq = nil
	self.rtt_at = nil

	-- exponential backoff (6298 5.5), cleared by the next acknowledgment
	-- of new data.
	self.rto = math.min(self.rto * 2, RTO_MAX)
	self.retx = self.now + self.rto
end

-- What a timeout costs the congestion window (5681 3.1). Separate from
-- _retransmit because the ssthresh reduction happens once per loss, not
-- once per attempt: a segment already resent by the timer holds ssthresh
-- constant, or a peer that has gone away would ratchet it to the floor
-- on the way to being declared dead.
function T:_timeout_cc()
	if not self.cwnd then
		return
	end
	if self.retries == 0 then
		self.ssthresh = math.max(self:_flight() // 2, 2 * self.snd_mss)
	end
	-- the loss window: one segment, whatever the initial window was.
	self.cwnd = self.snd_mss
	-- 6582 step 4: record the highest sequence number sent, and leave
	-- fast recovery. What follows is slow start, not recovery.
	self.recover = self.snd_nxt
	self.in_recovery = false
	self.dupacks = 0
end

-- when this connection next wants attention, or nil if it is content to
-- wait forever. The caller arms one timer for the earliest across all of
-- its connections -- see task/tcp4.lua on why there is only one.
function T:deadline()
	if self.timewait and self.retx then
		return math.min(self.timewait, self.retx)
	end
	return self.timewait or self.retx
end

function T:tick(now)
	self.now = now or self.now

	if self.timewait and self.now >= self.timewait then
		self.timewait = nil
		self:_dead("closed")
		return
	end
	if self.retx and self.now >= self.retx then
		self:_retransmit()
	end
end

-- the entry point: one segment, already decoded and checksummed by
-- lib/tcp4.lua, and already matched to this connection by whoever owns
-- the table of them.
function T:segment(seg, now)
	self.now = now or self.now

	if self.state == tcb.CLOSED then
		return
	elseif self.state == tcb.LISTEN then
		return self:_in_listen(seg)
	elseif self.state == tcb.SYN_SENT then
		return self:_in_syn_sent(seg)
	end
	return self:_in_synchronized(seg)
end

-- for logs, tests and a stats op: everything worth knowing in one line.
function T:status()
	return {
		state = self.state,
		snd_una = self.snd_una, snd_nxt = self.snd_nxt,
		snd_wnd = self.snd_wnd, snd_mss = self.snd_mss,
		rcv_nxt = self.rcv_nxt, rcv_wnd = self.rcv_wnd,
		unacked = tcp4.diff(self.snd_nxt, self.snd_una),
		unsent = #self.sndq - tcp4.diff(self.snd_nxt, self.snd_una),
		readable = self.rcvbytes,
		fin_rcvd = self.fin_rcvd,
		fin_sent = self.fin_sent,
		held = #self.ooo,
		rto = self.rto,
		srtt = self.srtt,
		cwnd = self.cwnd,
		ssthresh = self.ssthresh,
		dupacks = self.dupacks,
		recovery = self.in_recovery,
		flight = self:_flight(),
		retries = self.retries,
	}
end

return tcb
