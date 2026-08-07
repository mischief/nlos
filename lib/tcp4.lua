-- TCP over IPv4, RFC 9293: the header, its options, and the sequence
-- arithmetic everything above is built out of. No connection state and
-- no I/O -- lib/tcb.lua is one connection, task/tcp4.lua is the proc
-- that owns them all.
--
-- Named tcp4 and not tcp for the same reason as lib/udp4.lua: "tcp" is
-- the name of the message protocol in lib/caps.lua, which is what a
-- client holds a right to and all it can see. This is the layer under
-- that -- the segment itself.
--
-- Splitting the codec out from the state machine is not tidiness. The
-- state machine is the part that cannot be tested against a real peer:
-- no amount of talking to OpenBSD will produce a simultaneous open or a
-- sequence number that laps the space. Keeping the wire format pure and
-- separate means the half we can check against another implementation
-- is checked that way, and the half we cannot is driven by a table.

local ip4 = require("ip4")
local buf = require("los.buf")

local tcp4 = {}

tcp4.HDRLEN = 20	-- without options

-- The default send MSS when the peer sends no MSS option (MUST-15):
-- 576 minus 20 of IP and 20 of TCP. Small, and deliberately so -- it is
-- what we must assume, not what we hope for.
tcp4.MSS_DEFAULT = 536

-- The smallest send MSS we will accept from a peer.
--
-- The RFC sets no floor, and without one a peer advertising an MSS of 1
-- has us send a segment per byte: forty bytes of header each, a message
-- to the ip task each, a segment on the wire each. That is a denial of
-- service written as a configuration, and it costs the peer nothing to
-- ask for. 88 is what Linux uses (TCP_MIN_MSS) and is comfortably above
-- RFC 791's 68-byte minimum MTU less the two headers.
tcp4.MSS_MIN = 88

-- ---- flags ----
--
-- A numeric mask rather than a set of booleans, because seg.ack cannot
-- be both the acknowledgment number and the ACK bit and the RFC uses it
-- for the number. Tested as `seg.flags & tcp4.ACK ~= 0`, which is how
-- the pseudo-code in section 3.10.7 reads too.
tcp4.FIN = 0x01
tcp4.SYN = 0x02
tcp4.RST = 0x04
tcp4.PSH = 0x08
tcp4.ACK = 0x10
tcp4.URG = 0x20
tcp4.ECE = 0x40		-- recognised, never set: no ECN here
tcp4.CWR = 0x80

local FLAGNAMES = {
	{ tcp4.FIN, "FIN" }, { tcp4.SYN, "SYN" }, { tcp4.RST, "RST" },
	{ tcp4.PSH, "PSH" }, { tcp4.ACK, "ACK" }, { tcp4.URG, "URG" },
	{ tcp4.ECE, "ECE" }, { tcp4.CWR, "CWR" },
}

-- for logs and for test failure messages, where "SYN,ACK" beats 18.
function tcp4.flagstr(flags)
	local out = {}

	for _, f in ipairs(FLAGNAMES) do
		if (flags & f[1]) ~= 0 then
			out[#out + 1] = f[2]
		end
	end
	if #out == 0 then
		return "-"
	end
	return table.concat(out, ",")
end

-- ---- sequence arithmetic ----
--
-- Sequence numbers are 32 bits and wrap, so they are compared by the
-- sign of their difference and never by < . Every comparison below
-- assumes the two numbers are less than 2^31 apart, which is the
-- assumption TCP itself makes: beyond that "before" and "after" are not
-- distinguishable, and no correct implementation lets the window grow
-- far enough to find out.
--
-- Lua 5.4 integers are 64-bit, so the masking is what keeps these in
-- the space rather than the arithmetic overflowing into it.

local MASK = 0xffffffff
local HALF = 0x80000000

tcp4.SEQ_MOD = MASK + 1

function tcp4.seq(n)
	return n & MASK
end

function tcp4.add(a, n)
	return (a + n) & MASK
end

-- a - b, as a signed distance. Positive when a is after b.
function tcp4.diff(a, b)
	local d = (a - b) & MASK

	if d >= HALF then
		return d - tcp4.SEQ_MOD
	end
	return d
end

function tcp4.lt(a, b)
	return ((a - b) & MASK) >= HALF
end

function tcp4.gt(a, b)
	return tcp4.lt(b, a)
end

function tcp4.le(a, b)
	return a == b or tcp4.lt(a, b)
end

function tcp4.ge(a, b)
	return a == b or tcp4.lt(b, a)
end

-- lo <= x < hi, on the circle. An empty range contains nothing, which
-- is the case that matters: a zero receive window is lo == hi, and the
-- acceptability test in 3.10.7 has to reject every octet against it.
function tcp4.between(x, lo, hi)
	if lo == hi then
		return false
	end
	return tcp4.le(lo, x) and tcp4.lt(x, hi)
end

-- SEG.LEN: the data, plus a sequence number each for SYN and FIN.
--
-- Both control flags occupy sequence space so that they can be
-- acknowledged and retransmitted like data. Every acceptability test in
-- 3.10.7 is written in terms of this, and forgetting the +1 is the
-- classic way to build a stack that completes a handshake and then
-- rejects the peer's FIN forever.
function tcp4.seglen(seg)
	local n = seg.data and #seg.data or 0

	if (seg.flags & tcp4.SYN) ~= 0 then
		n = n + 1
	end
	if (seg.flags & tcp4.FIN) ~= 0 then
		n = n + 1
	end
	return n
end

-- ---- options ----

tcp4.OPT_EOL = 0
tcp4.OPT_NOP = 1
tcp4.OPT_MSS = 2
tcp4.OPT_WSCALE = 3	-- RFC 7323, parsed and deliberately not offered
tcp4.OPT_SACKOK = 4	-- RFC 2018, likewise
tcp4.OPT_SACK = 5
tcp4.OPT_TS = 8		-- RFC 7323 timestamps, likewise

-- Everything is recognised on the way in even though only MSS is sent
-- on the way out. Parsing from the start costs nothing and means
-- turning window scaling on later is a change to what we advertise
-- rather than a new code path on the receive side -- and until then, we
-- can see in a log what the peer offered and we declined.
--
-- Malformed options stop the parse rather than failing the segment. A
-- peer that appends garbage after a valid MSS still gets its MSS
-- honoured, which is the robustness principle, and a length that would
-- not advance is the one case that must be caught explicitly or the
-- loop never ends. That last part is not hypothetical politeness: it is
-- a two-byte segment that hangs the stack.
function tcp4.decode_options(s)
	local opt = {}
	local i = 1
	local n = #s

	while i <= n do
		local kind = s:byte(i)

		if kind == tcp4.OPT_EOL then
			break
		elseif kind == tcp4.OPT_NOP then
			i = i + 1
		else
			if i + 1 > n then
				break		-- a kind with no length
			end

			local len = s:byte(i + 1)

			-- len counts the kind and length bytes themselves, so
			-- anything under two cannot advance and anything past
			-- the end is not there.
			if len < 2 or i + len - 1 > n then
				break
			end

			local body = s:sub(i + 2, i + len - 1)

			if kind == tcp4.OPT_MSS and len == 4 then
				opt.mss = string.unpack(">I2", body)
			elseif kind == tcp4.OPT_WSCALE and len == 3 then
				opt.wscale = body:byte(1)
			elseif kind == tcp4.OPT_SACKOK and len == 2 then
				opt.sackok = true
			elseif kind == tcp4.OPT_TS and len == 10 then
				local val, ecr = string.unpack(">I4I4", body)

				opt.ts = { val = val, ecr = ecr }
			elseif kind == tcp4.OPT_SACK and (len - 2) % 8 == 0 then
				local blocks = {}

				for b = 1, #body, 8 do
					local l, r = string.unpack(">I4I4", body, b)

					blocks[#blocks + 1] = { left = l, right = r }
				end
				opt.sack = blocks
			end
			i = i + len
		end
	end
	return opt
end

-- Only what we are prepared to honour on the way back. Padded to a
-- 4-byte boundary because the data offset field counts words and has
-- nowhere to say "and three more bytes".
--
-- Window scale and timestamps are still parsed and not offered; see
-- decode_options. SACK is offered, because the receiver state it needs
-- -- a queue of segments held behind a hole -- already exists.
function tcp4.encode_options(opt)
	if not opt then
		return ""
	end

	local out = {}

	if opt.mss then
		out[#out + 1] = string.pack(">I1I1I2", tcp4.OPT_MSS, 4, opt.mss)
	end
	if opt.sackok then
		out[#out + 1] = string.pack(">I1I1", tcp4.OPT_SACKOK, 2)
	end
	if opt.sack and #opt.sack > 0 then
		-- 8 bytes a block plus the kind and length. Four blocks is
		-- the most the 40 bytes of option space can hold, and three
		-- is the most that leaves room for the timestamps this will
		-- eventually also carry -- so callers are expected to have
		-- already chosen which blocks matter.
		local blocks = {}

		for _, b in ipairs(opt.sack) do
			blocks[#blocks + 1] = string.pack(">I4I4", b.left, b.right)
		end
		out[#out + 1] = string.pack(">I1I1", tcp4.OPT_SACK,
		    2 + 8 * #blocks) .. table.concat(blocks)
	end

	local s = table.concat(out)
	local pad = (4 - (#s % 4)) % 4

	-- NOPs rather than EOLs: a receiver must stop at an EOL, so padding
	-- with them would hide any option added after this one.
	return s .. string.rep(string.char(tcp4.OPT_NOP), pad)
end

-- ---- the header ----

-- src, dst, protocol and segment length, summed but never transmitted.
-- Unlike UDP's, TCP's checksum is not optional: a segment that does not
-- add up is discarded, so this is required on both sides.
local function pseudo(src, dst, len)
	return src .. dst .. string.pack(">I1I1I2", 0, ip4.PROTO_TCP, len)
end

-- seg is { sport, dport, seq, ack, flags, wnd, urp, opt, data }; src and
-- dst are the addresses it is about to be wrapped in, needed for the
-- checksum for the same reason udp4.encode needs them.
-- `out` and `at` write the segment into a frame the caller allocated,
-- where the payload is copied once. Without them it is built by
-- concatenation, which copies the data three times: into the body, in
-- front of the pseudo-header to be summed, and again to splice the
-- checksum in.
function tcp4.encode(seg, src, dst, out, at)
	local opts = tcp4.encode_options(seg.opt)
	local hlen = tcp4.HDRLEN + #opts
	local data = seg.data or ""
	local off = (hlen // 4) << 12

	-- `true` asks for a buffer of exactly this segment, for a sender
	-- that has no frame to write into and is going to hand the bytes
	-- to whoever does.
	if out then
		local len = hlen + #data

		local alloced = out == true

		if alloced then
			out, at = buf.new(len), 1
		end

		out:setu16be(at, seg.sport)
		out:setu16be(at + 2, seg.dport)
		out:setu32be(at + 4, seg.seq & MASK)
		out:setu32be(at + 8, (seg.ack or 0) & MASK)
		out:setu16be(at + 12, off | (seg.flags & 0xff))
		out:setu16be(at + 14, seg.wnd or 0)
		out:setu16be(at + 16, 0)
		out:setu16be(at + 18, seg.urp or 0)
		if #opts > 0 then
			out:copy(at + tcp4.HDRLEN, opts)
		end
		if #data > 0 then
			out:copy(at + hlen, data)
		end
		out:setu16be(at + 16, ip4.checksum(out:view(at, at + len - 1),
		    (~ip4.checksum(pseudo(src, dst, len))) & 0xffff))
		return alloced and out or len
	end

	local hdr = string.pack(">I2I2I4I4I2I2I2I2",
	    seg.sport, seg.dport, seg.seq & MASK, (seg.ack or 0) & MASK,
	    off | (seg.flags & 0xff), seg.wnd or 0, 0, seg.urp or 0)
	local body = hdr .. opts .. data
	local ck = ip4.checksum(pseudo(src, dst, #body) .. body)

	-- a computed zero is transmitted as zero here, unlike UDP: TCP has
	-- no "no checksum" encoding to collide with.
	return body:sub(1, 16) .. string.pack(">I2", ck) .. body:sub(19)
end

-- nil for anything that is not a whole, well-formed segment.
--
-- Like ip4.decode this is a filter rather than a parser: what arrives
-- is whatever the wire delivered, and a segment we cannot trust must
-- not reach the state machine at all -- acting on a damaged sequence
-- number is how a connection gets reset by its own stack.
function tcp4.decode(p, src, dst)
	if type(p) ~= "string" or #p < tcp4.HDRLEN then
		return nil
	end

	local sport, dport, seq, ack, offflags, wnd, ck, urp =
	    string.unpack(">I2I2I4I4I2I2I2I2", p)
	local hlen = ((offflags >> 12) & 0x0f) * 4

	if hlen < tcp4.HDRLEN or hlen > #p then
		return nil
	end

	if src and dst and ip4.checksum(pseudo(src, dst, #p) .. p) ~= 0 then
		return nil
	end

	return {
		sport = sport,
		dport = dport,
		seq = seq,
		ack = ack,
		flags = offflags & 0xff,
		wnd = wnd,
		ck = ck,
		urp = urp,
		opt = tcp4.decode_options(p:sub(tcp4.HDRLEN + 1, hlen)),
		data = p:sub(hlen + 1),
	}
end

-- ---- resets ----
--
-- Section 3.5.2, and it lives here rather than in lib/tcb.lua because
-- the segments most needing a reset are the ones with no connection to
-- hold state in: a SYN to a port nobody listens on is answered without
-- a TCB ever existing. It is a pure function of the offending segment,
-- which is exactly what makes it belong with the codec.
--
-- The two cases are the whole rule. If the segment carried an ACK, its
-- acknowledgment number is a sequence number the peer already believes
-- in, so the reset takes it and carries no ACK of its own. Otherwise
-- there is no such number, so the reset sits at zero and acknowledges
-- everything the segment occupied -- which is why seglen is used here
-- and not #data.
--
-- Returns nil for a segment that is itself a reset. Answering a RST
-- with a RST is how two hosts generate traffic forever.
function tcp4.reset_for(seg)
	if (seg.flags & tcp4.RST) ~= 0 then
		return nil
	end

	if (seg.flags & tcp4.ACK) ~= 0 then
		return {
			sport = seg.dport,
			dport = seg.sport,
			seq = seg.ack,
			ack = 0,
			flags = tcp4.RST,
			wnd = 0,
		}
	end

	return {
		sport = seg.dport,
		dport = seg.sport,
		seq = 0,
		ack = tcp4.add(seg.seq, tcp4.seglen(seg)),
		flags = tcp4.RST | tcp4.ACK,
		wnd = 0,
	}
end

return tcp4
