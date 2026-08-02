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
-- What is here: the eleven states, active and passive open through to
-- ESTABLISHED, in-order data in both directions, and a FIN received.
-- What is deliberately not here yet: the retransmission timer, holding
-- out-of-order segments for reassembly, closing from our side, and
-- congestion control. Each has its own commit; the shape below has
-- somewhere for all of them to go.
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

		passive = false,
		fin_rcvd = false,

		out = {},
		ev = {},
	}, T)

	t.rcv_wnd = t:_window()
	return t
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
function T:_send(flags, data, seq)
	self.rcv_wnd = self:_window()

	self.out[#self.out + 1] = {
		sport = self.lport, dport = self.rport,
		seq = seq or self.snd_nxt,
		ack = self.rcv_nxt,
		flags = flags,
		wnd = self.rcv_wnd,
		data = data,
	}
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
function T:connect()
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
function T:write(data)
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
		local room = self.snd_wnd - sent

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

	if acked then
		self.snd_una = seg.ack
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

	if tcp4.lt(self.snd_una, seg.ack) then
		local n = tcp4.diff(seg.ack, self.snd_una)

		-- drop the acknowledged bytes from the send buffer. What is
		-- left begins at the new snd_una, which keeps the invariant
		-- the retransmission queue will be built on.
		self.sndq = self.sndq:sub(n + 1)
		self.snd_una = seg.ack
	end

	-- the window update, guarded so that a reordered segment cannot
	-- install an older window over a newer one (3.10.7.4, fifth step).
	if tcp4.lt(self.snd_wl1, seg.seq) or
	    (self.snd_wl1 == seg.seq and tcp4.le(self.snd_wl2, seg.ack)) then
		self.snd_wnd = seg.wnd
		self.snd_wl1 = seg.seq
		self.snd_wl2 = seg.ack
	end
	return true
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

			if self.state == tcb.ESTABLISHED or
			    self.state == tcb.SYN_RECEIVED then
				self.state = tcb.CLOSE_WAIT
			end
			signal(self, "closing")
		end
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

	if self.state == tcb.ESTABLISHED or self.state == tcb.SYN_RECEIVED then
		self:_text(seg)
	end

	-- an acknowledgment may have opened the window.
	self:_transmit()
end

-- the entry point: one segment, already decoded and checksummed by
-- lib/tcp4.lua, and already matched to this connection by whoever owns
-- the table of them.
function T:segment(seg)
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
	}
end

return tcb
