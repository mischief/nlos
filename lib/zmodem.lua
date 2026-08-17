-- ZMODEM (Forsberg's zmodem.h framing), sender and receiver.
--
-- Sans-io: nothing here reads, writes, sleeps or knows what a port is.
-- A machine takes bytes with :feed(), hands bytes back with :pull(),
-- and is stepped with :run(now_ms). The caller supplies the line --
-- a serial wire in the guest, a socket on the host, a string buffer in
-- a test -- so the same protocol code is what every one of those
-- exercises. M.drive() is sugar over the loop for callers that do have
-- a blocking read/write pair, and is not part of the state machine.
--
-- The straight-line protocol logic lives inside a coroutine, so "read a
-- header, then its subpackets" is written as it reads rather than as a
-- table of states: the reader primitives yield when the input buffer
-- runs dry and resume where they left off. run() is what decides
-- whether there is anything to resume for -- new input, an expired
-- deadline, or a drained output buffer.
--
-- ZMODEM is streaming: the sender does not wait for an ack per block,
-- only at the end of a frame, so a clean line stays full. Recovery is
-- position-based -- the receiver answers ZRPOS with the offset it
-- actually has and the sender restarts the frame there -- which is why
-- a corrupt subpacket costs one frame and not the transfer.

local M = {}

-- ---- framing constants (zmodem.h) ----

local ZPAD, ZDLE, ZBIN, ZHEX, ZBIN32 = 0x2a, 0x18, 0x41, 0x42, 0x43

local ZRQINIT, ZRINIT, ZSINIT, ZACK, ZFILE, ZSKIP, ZNAK, ZABORT, ZFIN,
    ZRPOS, ZDATA, ZEOF, ZFERR, ZCRC, ZCHALLENGE, ZCOMPL, ZCAN =
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16

-- subpacket terminators, all reached as ZDLE + this byte
local ZCRCE, ZCRCG, ZCRCQ, ZCRCW = 0x68, 0x69, 0x6a, 0x6b
local ZRUB0, ZRUB1 = 0x6c, 0x6d

-- ZRINIT ZF0: what the receiver can do
local CANFDX, CANOVIO, CANFC32, ESCCTL = 0x01, 0x02, 0x20, 0x40
-- ZFILE ZF0
local ZCBIN = 0x01

local ZERO = "\0\0\0\0"

-- how long a receiver listens before it prompts. Short, because what it
-- is looking for is already queued if it is coming at all: the cost is
-- paid only when the sender has said nothing yet, and then the sender is
-- still starting and is in no hurry.
local LISTEN = 300

M.ZRQINIT, M.ZRINIT, M.ZFILE, M.ZDATA, M.ZEOF, M.ZFIN = ZRQINIT, ZRINIT,
    ZFILE, ZDATA, ZEOF, ZFIN

local names = {
	[ZRQINIT] = "ZRQINIT", [ZRINIT] = "ZRINIT", [ZSINIT] = "ZSINIT",
	[ZACK] = "ZACK", [ZFILE] = "ZFILE", [ZSKIP] = "ZSKIP",
	[ZNAK] = "ZNAK", [ZABORT] = "ZABORT", [ZFIN] = "ZFIN",
	[ZRPOS] = "ZRPOS", [ZDATA] = "ZDATA", [ZEOF] = "ZEOF",
	[ZFERR] = "ZFERR", [ZCRC] = "ZCRC", [ZCHALLENGE] = "ZCHALLENGE",
	[ZCOMPL] = "ZCOMPL", [ZCAN] = "ZCAN",
}

function M.hdrname(t)
	return names[t] or ("type " .. tostring(t))
end

-- ---- checksums ----
--
-- CRC16 is CCITT unreflected seeded 0 -- CRC-16/XMODEM, 0x31c3 over
-- "123456789". lrzsz spells it as the augmented shift register (data
-- xored in at the low end, two zero bytes fed through before the value
-- is transmitted); the table-driven form here xors into the table index
-- instead and needs no augmentation. Same value on the wire, and the
-- two forms are not interchangeable half-and-half: pairing one's
-- transmit with the other's check yields a CRC that never verifies.
--
-- CRC32 is the ordinary reflected one, complemented before sending, so
-- its residue is 0xDEBB20E3 where CRC16's is zero. That asymmetry is
-- Forsberg's, not ours.

-- The C module first, because the tables below are only the fallback:
-- 512 entries built at load time in every proc that requires this, and
-- dead weight where crc.c answers. Probing first is worth several KB on
-- a board that counts them.
local haveC, ccrc = pcall(require, "los.crc")

haveC = haveC and type(ccrc) == "table" and type(ccrc.crc32) == "function"

local crc16tab, crc32tab = {}, {}

for i = 0, (haveC and -1 or 255) do
	local c = i << 8

	for _ = 1, 8 do
		if c & 0x8000 ~= 0 then
			c = ((c << 1) ~ 0x1021) & 0xffff
		else
			c = (c << 1) & 0xffff
		end
	end
	crc16tab[i] = c
end

for i = 0, (haveC and -1 or 255) do
	local c = i

	for _ = 1, 8 do
		if c & 1 ~= 0 then
			c = (c >> 1) ~ 0xedb88320
		else
			c = c >> 1
		end
	end
	crc32tab[i] = c
end

local sbyte = string.byte

local function crc16up(s, crc)
	local t = crc16tab

	for i = 1, #s do
		crc = ((crc << 8) ~ t[((crc >> 8) ~ sbyte(s, i)) & 0xff]) & 0xffff
	end
	return crc
end

local function crc32up(s, crc)
	local t = crc32tab

	for i = 1, #s do
		crc = (crc >> 8) ~ t[(crc ~ sbyte(s, i)) & 0xff]
	end
	return crc
end

-- src/crc.c when this is a lua-os proc, the loops above on the host.
--
-- Chosen once here rather than branched per call, and worth the C at
-- all because it is the only cost that scales with the payload: in the
-- guest the Lua loops run at ~10MB/s against the C's ~500, and the data
-- goes through one at each end, which was 37% of a 256KiB transfer.
if haveC then
	crc16up, crc32up = ccrc.crc16, ccrc.crc32
end

-- the other loop that scales with the payload. Absent where los.crc is
-- (the host tests), so subpacket() keeps a lua path that does the same.
local unzdle = haveC and ccrc.unzdle

local function crc16of(s)
	return crc16up(s, 0)
end

local function crc32of(s)
	return (~crc32up(s, 0xffffffff)) & 0xffffffff
end

-- exposed for the test's check vectors: crc16("123456789") is 0x31c3
-- and crc32("123456789") is 0xcbf43926, so a table built wrong is
-- caught where it happens rather than as "the transfer hangs".
function M.crc16(s)
	return crc16up(s, 0)
end

function M.crc32(s)
	return crc32of(s)
end

-- ---- escaping ----
--
-- ZDLE has to be escaped or framing is ambiguous, and so do the bytes a
-- line in the middle eats: XON/XOFF and their high halves. That is the
-- minimum, and it is what goes out by default.
--
-- ESCCTL is the other setting: every control character escaped, which
-- is 64 of the 256 byte values and so about 25% more wire on binary
-- data. It is not merely defensive, and this is the part that is easy
-- to get wrong -- **a peer in ESCCTL mode DISCARDS unescaped control
-- characters on the way in**. So the mode is a promise about what we
-- send, not a preference about what we accept: advertising ESCCTL in
-- ZRINIT and then sending a header with a raw NUL in it means the peer
-- reads a header two bytes short and never answers. `sz -e` sets it
-- from its own command line and drops our bytes whatever we advertised,
-- which is exactly how this was found.
--
-- Decoding is unconditional either way: an escaped byte is unambiguous,
-- so a peer that escapes more than we asked for costs nothing.
--
-- Not done: lrzsz also escapes CR after '@', which guards a telnet
-- peculiarity none of our transports have.

local escmaps = { [false] = {}, [true] = {} }

for _, b in ipairs({ 0x18, 0x10, 0x11, 0x13, 0x90, 0x91, 0x93 }) do
	escmaps[false][string.char(b)] = string.char(ZDLE, b ~ 0x40)
end
for b = 0, 255 do
	if b & 0x60 == 0 then
		escmaps[true][string.char(b)] = string.char(ZDLE, b ~ 0x40)
	end
end

local escpats = {
	[false] = "[\24\16\17\19\144\145\147]",
	[true] = "[\0-\31\128-\159]",
}

local function esc(s, all)
	return (s:gsub(escpats[all], escmaps[all]))
end

local function pos4(n)
	return string.char(n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff,
	    (n >> 24) & 0xff)
end

local function unpos(f)
	local a, b, c, d = sbyte(f, 1, 4)

	return a | (b << 8) | (c << 16) | (d << 24)
end

-- ---- frame encoding ----

local function hexhdr(typ, f)
	local body = string.char(typ) .. f
	local crc = crc16of(body)
	local out = { "\42\42\24\66" }	-- ZPAD ZPAD ZDLE ZHEX

	for i = 1, 5 do
		out[i + 1] = string.format("%02x", sbyte(body, i))
	end
	out[7] = string.format("%02x%02x", crc >> 8, crc & 0xff)
	-- CR, LF|0200, and XON on everything but the two frames a peer
	-- may answer with flow control of its own.
	out[8] = "\r\138"
	if typ ~= ZFIN and typ ~= ZACK then
		out[9] = "\17"
	end
	return table.concat(out)
end

local function binhdr(typ, f, use32, all)
	local body = string.char(typ) .. f

	if use32 then
		local c = crc32of(body)

		return "\42\24\67" .. esc(body .. pos4(c), all)
	end

	local c = crc16of(body)

	return "\42\24\65" .. esc(body .. string.char(c >> 8, c & 0xff), all)
end

local function subpkt(data, term, use32, all)
	local body = data .. string.char(term)
	local tail

	if use32 then
		tail = pos4(crc32of(body))
	else
		local c = crc16of(body)

		tail = string.char(c >> 8, c & 0xff)
	end
	return esc(data, all) .. string.char(ZDLE, term) .. esc(tail, all)
end

-- eight CANs and eight backspaces: the abort every zmodem implementation
-- recognises, the backspaces to rub out what a shell would have echoed.
function M.abort()
	return string.rep("\24", 8) .. string.rep("\8", 8)
end

-- ---- the machine ----

local Mach = {}

Mach.__index = Mach

function Mach:feed(s)
	if s == nil or #s == 0 then
		return
	end
	-- compact before appending, never per byte read
	if self.pos > 1 then
		self.inbuf = self.inbuf:sub(self.pos)
		self.pos = 1
	end
	self.inbuf = self.inbuf .. s
	self.needmore = false
end

function Mach:pull()
	local n = #self.out

	if n == 0 then
		return nil
	end

	local s = n == 1 and self.out[1] or table.concat(self.out)

	self.out, self.outn = {}, 0
	return s
end

function Mach:pending()
	return self.outn
end

function Mach:emit(s)
	local n = #self.out + 1

	self.out[n] = s
	self.outn = self.outn + #s
end

-- Give the driver a chance to write before the sender builds another
-- megabyte of frames in memory. Costs one coroutine round trip per
-- outmax bytes, which at 32KB is nothing next to the copying it avoids.
function Mach:maybeflush()
	if self.outn >= self.outmax then
		coroutine.yield("flush")
	end
end

function Mach:timeleft(now)
	if not self.deadline then
		return self.timeout
	end

	local ms = self.deadline - now

	return ms > 0 and ms or 0
end

-- run as far as the buffered input and the clock allow. Returns
-- "running", "done" or "error"; m.wantinput says whether the machine is
-- parked on a read, which is the only case where the driver should
-- block.
function Mach:run(now)
	self.now = now

	while self.state == "running" do
		if self.waiting == "input" and
		    (self.pos > #self.inbuf or self.needmore) then
			if self.deadline and now >= self.deadline then
				self.expired = true
			else
				self.wantinput = true
				return "running"
			end
		end

		local ok, what = coroutine.resume(self.co)

		if not ok then
			self.state, self.err = "error", tostring(what)
			break
		end
		if coroutine.status(self.co) == "dead" then
			-- `what` is the body's return: a value on success,
			-- nil + reason on failure.
			if what == nil then
				self.state = "error"
				self.err = self.err or "aborted"
			else
				self.state, self.result = "done", what
			end
			break
		end
		self.waiting = what
		if what == "flush" or what == "file" or what == "sink" then
			self.wantinput = false
			return "running"
		end
	end

	self.wantinput = false
	return self.state
end

-- ---- reader primitives (they yield; only the coroutine may call them) ----

-- ask the driver for body bytes, the way wait() asks it for wire bytes.
--
-- A reader cannot simply be called from in here. lua_yield unwinds to
-- whoever resumed the state it fired in, so a reader that parks -- on a
-- port, a file, anything -- lands in Mach:run rather than in its own
-- scheduler, and run resumes the coroutine again believing the yield
-- was a preemption. On lua-os that leaves the kernel holding a proc
-- marked blocked while it carries on executing. So the request goes
-- out the same door the transport's does, and the driver, which is
-- outside the coroutine, is free to park.
function Mach:want(off, n)
	-- Only where the caller asked for it. A reader that cannot block --
	-- a generator, a string slice -- is served inline, which is what
	-- every run/pull/feed caller expects; opting in is for a reader
	-- that parks, and means the driver must answer filereq.
	if not self.yieldread then
		return self.filereader(off, n)
	end

	self.filereq = { off = off, n = n }
	coroutine.yield("file")
	self.filereq = nil

	local d = self.filedata

	self.filedata = nil
	return d
end

-- the sink's half of the same rule: a sink that opens, writes and
-- closes a file parks on a file server. See Mach:want for why a park
-- inside the coroutine is not a park at all.
-- one entry point for the three things a sink is asked, so the driver
-- has a single call to make on the outside.
function Mach:sinkdo(op, a, b)
	if op == "open" then
		self.sinkobj = self.sink(a)
		return self.sinkobj
	end
	if op == "write" then
		return self.sinkobj.write(a, b)
	end
	self.sinkobj.close(a)
	self.sinkobj = nil
end

function Mach:sinkcall(op, a, b)
	if not self.yieldwrite then
		return self:sinkdo(op, a, b)
	end

	self.sinkreq = { op = op, a = a, b = b }
	coroutine.yield("sink")
	self.sinkreq = nil

	local r = self.sinkres

	self.sinkres = nil
	return r
end

-- wait for input that has not arrived yet, with bytes still unread.
-- An escape split across two reads is the case: the second byte decides
-- what the first one means, so having the ZDLE is having nothing.
function Mach:waitmore()
	self.needmore = true
	return self:wait()
end

function Mach:wait()
	self.deadline = self.now + self.timeout
	coroutine.yield("input")
	if self.expired then
		self.expired = false
		self.deadline = nil
		return false
	end
	return true
end

function Mach:byte()
	while self.pos > #self.inbuf do
		if not self:wait() then
			return nil
		end
	end

	local b = sbyte(self.inbuf, self.pos)

	self.pos = self.pos + 1
	return b
end

-- everything up to the next ZDLE, which is left unconsumed. May return
-- "" (the next byte is already ZDLE) or stop at the end of the buffer
-- without having found one, so callers loop.
function Mach:plain()
	while self.pos > #self.inbuf do
		if not self:wait() then
			return nil
		end
	end

	local i = self.inbuf:find("\24", self.pos, true)
	local s

	if i then
		s = self.inbuf:sub(self.pos, i - 1)
		self.pos = i
	else
		s = self.inbuf:sub(self.pos)
		self.pos = #self.inbuf + 1
	end
	return s
end

-- one ZDLE-decoded byte. Returns nil, code when what followed ZDLE was
-- a terminator or garbage rather than data.
function Mach:ebyte()
	local b = self:byte()

	if b == nil then
		return nil, nil
	end
	if b ~= ZDLE then
		return b
	end

	local c = self:byte()

	if c == nil then
		return nil, nil
	end
	if c == ZRUB0 then
		return 0x7f
	end
	if c == ZRUB1 then
		return 0xff
	end
	if c & 0x60 == 0x40 then
		return c ~ 0x40
	end
	return nil, c
end

function Mach:ebytes(n)
	local t = {}

	for i = 1, n do
		local b = self:ebyte()

		if b == nil then
			return nil
		end
		t[i] = string.char(b)
	end
	return table.concat(t)
end

-- a data subpacket: escaped bytes up to a ZDLE terminator, then its
-- crc. Returns data, terminator -- or nil, reason.
function Mach:subpacket()
	local parts, n = {}, 0
	local c

	if unzdle then
		-- the whole run in C. It stops at a terminator or at the end
		-- of what is buffered, so the loop here is one turn per read
		-- rather than one per escaped byte.
		while true do
			while self.pos > #self.inbuf do
				if not self:wait() then
					return nil, "timeout"
				end
			end

			local s, term, nxt = unzdle(self.inbuf, self.pos)

			if s == nil then
				return nil, "bad escape"
			end
			if #s > 0 then
				n = n + 1
				parts[n] = s
			end
			self.pos = nxt
			if term then
				c = term
				break
			end
			if not self:waitmore() then
				return nil, "timeout"
			end
		end
	else
		while true do
			local s = self:plain()

			if s == nil then
				return nil, "timeout"
			end
			if #s > 0 then
				n = n + 1
				parts[n] = s
			end
			if self.pos <= #self.inbuf and
			    sbyte(self.inbuf, self.pos) == ZDLE then
				break
			end
		end

		self.pos = self.pos + 1		-- the ZDLE
		c = self:byte()
		if c == nil then
			return nil, "timeout"
		end

		while c == ZRUB0 or c == ZRUB1 or c & 0x60 == 0x40 do
			-- an escaped byte, not a terminator: take it and
			-- go round
			n = n + 1
			parts[n] = string.char(c == ZRUB0 and 0x7f or
			    c == ZRUB1 and 0xff or (c ~ 0x40))

			local more = self:subpacket_more(parts)

			if more == nil then
				return nil, "timeout"
			end
			n = #parts
			c = more
		end
	end

	if c ~= ZCRCE and c ~= ZCRCG and c ~= ZCRCQ and c ~= ZCRCW then
		return nil, "bad escape"
	end

	local data = table.concat(parts)
	local tail = self:ebytes(self.crc32 and 4 or 2)

	if tail == nil then
		return nil, "timeout"
	end

	local body = data .. string.char(c)

	if self.crc32 then
		if crc32up(body .. tail, 0xffffffff) ~= 0xdebb20e3 then
			return nil, "crc"
		end
	elseif crc16up(body .. tail, 0) ~= 0 then
		return nil, "crc"
	end
	return data, c
end

-- the tail of subpacket()'s loop: plain runs until the next ZDLE, then
-- the byte after it. Split out only so subpacket() stays readable.
function Mach:subpacket_more(parts)
	while true do
		local s = self:plain()

		if s == nil then
			return nil
		end
		if #s > 0 then
			parts[#parts + 1] = s
		end
		if self.pos <= #self.inbuf and
		    sbyte(self.inbuf, self.pos) == ZDLE then
			break
		end
	end
	self.pos = self.pos + 1
	return self:byte()
end

local hexval = {}

for i = 0, 9 do
	hexval[string.byte("0") + i] = i
end
for i = 0, 5 do
	hexval[string.byte("a") + i] = 10 + i
	hexval[string.byte("A") + i] = 10 + i
end

function Mach:hexbyte()
	local a = self:byte()

	if a == nil then
		return nil
	end

	local b = self:byte()

	if b == nil then
		return nil
	end
	if hexval[a] == nil or hexval[b] == nil then
		return nil
	end
	return hexval[a] * 16 + hexval[b]
end

-- next header on the wire, skipping whatever garbage precedes it.
-- Returns type, 4 flag/position bytes -- or nil, reason.
function Mach:gethdr()
	local cans = 0

	while true do
		local b = self:byte()

		if b == nil then
			return nil, "timeout"
		end

		if b == ZDLE then
			cans = cans + 1
			if cans >= 5 then
				return nil, "cancelled"
			end
			goto continue
		end
		cans = 0
		if b ~= ZPAD then
			goto continue
		end

		local c = self:byte()

		if c == nil then
			return nil, "timeout"
		end
		if c == ZPAD then
			c = self:byte()
			if c == nil then
				return nil, "timeout"
			end
		end
		if c ~= ZDLE then
			goto continue
		end

		local kind = self:byte()

		if kind == nil then
			return nil, "timeout"
		end

		if kind == ZHEX then
			local t = {}

			for i = 1, 7 do
				local v = self:hexbyte()

				if v == nil then
					goto continue
				end
				t[i] = string.char(v)
			end
			if crc16up(table.concat(t), 0) ~= 0 then
				goto continue
			end
			-- CR LF XON, if they have arrived; if they have
			-- not, the next scan skips them as garbage.
			while self.pos <= #self.inbuf do
				local x = sbyte(self.inbuf, self.pos)

				if x ~= 0x0d and x ~= 0x0a and x ~= 0x8a and
				    x ~= 0x11 and x ~= 0x13 then
					break
				end
				self.pos = self.pos + 1
			end
			return sbyte(t[1]), table.concat(t, "", 2, 5)
		elseif kind == ZBIN or kind == ZBIN32 then
			local n = kind == ZBIN32 and 9 or 7
			local raw = self:ebytes(n)

			if raw == nil then
				goto continue
			end
			if kind == ZBIN32 then
				if crc32up(raw, 0xffffffff) ~= 0xdebb20e3 then
					goto continue
				end
			elseif crc16up(raw, 0) ~= 0 then
				goto continue
			end
			-- the sender picks the check per frame and says so
			-- in the header kind. Its subpackets carry the
			-- same one, so this is where a receiver learns how
			-- wide the trailing crc is.
			self.crc32 = kind == ZBIN32
			return sbyte(raw), raw:sub(2, 5)
		end
		::continue::
	end
end

-- ---- receiver ----

local function parseinfo(s)
	local name, rest = s:match("^([^%z]*)%z(.*)$")

	if not name then
		return { name = s }
	end

	local size = rest:match("^(%d+)")

	return { name = name, size = size and math.tointeger(size) or nil }
end

local function recvfile(m, file, use32)
	local parts, pos, tries = {}, 0, 0
	local sink = m.sink and m:sinkcall("open", file) or nil

	local function put(s)
		if sink then
			m:sinkcall("write", pos, s)
		else
			parts[#parts + 1] = s
		end
		pos = pos + #s
		m.bytes = pos
	end

	local function finish()
		if sink then
			if sink.close then
				m:sinkcall("close", true)
			end
		else
			file.data = table.concat(parts)
		end
		file.received = pos
	end

	m:emit(binhdr(ZRPOS, pos4(0), use32, m.escall))
	while true do
		if tries > m.retries then
			return nil, "too many retries receiving " .. file.name
		end

		local typ, f = m:gethdr()

		if typ == ZDATA then
			if unpos(f) ~= pos then
				-- a frame from before our last ZRPOS; say
				-- again where we actually are
				tries = tries + 1
				m:emit(binhdr(ZRPOS, pos4(pos), use32, m.escall))
				goto continue
			end
			tries = 0
			while true do
				local d, term = m:subpacket()

				if d == nil then
					-- counted by reason: a transfer that
					-- finishes slowly says nothing about
					-- why, and "crc" (bytes lost) and
					-- "timeout" (nothing sent) call for
					-- opposite fixes.
					m.rejects = m.rejects or {}
					m.rejects[term] = (m.rejects[term] or 0) + 1
					m:emit(binhdr(ZRPOS, pos4(pos), use32, m.escall))
					break
				end
				put(d)
				if term == ZCRCQ then
					m:emit(binhdr(ZACK, pos4(pos), use32, m.escall))
				elseif term == ZCRCW then
					m:emit(binhdr(ZACK, pos4(pos), use32, m.escall))
					break
				elseif term ~= ZCRCG then
					break	-- ZCRCE: frame ended
				end
				m:maybeflush()
			end
		elseif typ == ZEOF then
			if unpos(f) == pos then
				finish()
				return true
			end
			tries = tries + 1
			m:emit(binhdr(ZRPOS, pos4(pos), use32, m.escall))
		elseif typ == ZCAN or f == "cancelled" then
			return nil, "cancelled"
		elseif typ == ZFIN then
			return nil, "sender finished mid-file"
		else
			-- timeout, or a frame with nothing to say here
			tries = tries + 1
			m:emit(binhdr(ZRPOS, pos4(pos), use32, m.escall))
		end
		::continue::
	end
end

local function recvbody(m)
	local files = {}
	local tries = 0
	-- opts.window is what the far end may send before waiting for us.
	-- Zero is "stream, do not wait", which is right when the bytes
	-- land in Lua and wrong when they land anywhere that takes time:
	-- a sink writing to a file server cannot read while it writes, and
	-- an unpaced sender overruns whatever is buffering underneath.
	local can = CANFDX | CANOVIO

	if m.crc32 then
		can = can | CANFC32
	end
	if m.escall then
		can = can | ESCCTL
	end

	local win = m.window or 0
	local flags = string.char(win & 0xff, (win >> 8) & 0xff, 0, can)
	-- ZRINIT is a prompt, not a heartbeat: it is said once at the
	-- start, once per file finished, and again whenever the sender
	-- has gone quiet. Repeating it per lap put a second one in flight
	-- behind every frame, and the sender answered the echo.
	local prompt, listened = true, false

	while true do
		if tries > m.retries then
			m.err = "no sender"
			return nil
		end
		-- Listen before speaking, once. A sender starts us by name and
		-- then pipelines its ZRQINIT and ZFILE without waiting, so by
		-- the time this is running those frames are usually already
		-- queued. Prompting on top of them puts our ZRINIT behind the
		-- ZFILE, where lsz reads it as "the receiver restarted" and
		-- spends two of its five second waits before trying again.
		if not listened then
			local save = m.timeout
			listened = true
			m.timeout = LISTEN
			m:wait()
			m.timeout = save
		end
		-- Only with nothing in hand. Anything buffered already answers
		-- what a prompt would ask for, and the sender is further along
		-- than a prompt assumes.
		if prompt and m.pos > #m.inbuf then
			m:emit(hexhdr(ZRINIT, flags))
			prompt = false
		end

		local typ, f = m:gethdr()

		if typ == ZFILE then
			local d, term = m:subpacket()

			if d == nil then
				tries = tries + 1
				m:emit(hexhdr(ZNAK, ZERO))
				goto continue
			end
			if term ~= ZCRCW and term ~= ZCRCE then
				-- lsz sends the file info as one ZCRCW
				-- subpacket; anything else is not one.
				tries = tries + 1
				goto continue
			end

			local file = parseinfo(d)
			local ok, err = recvfile(m, file, m.crc32)

			if not ok then
				m.err = err
				return nil
			end
			files[#files + 1] = file
			m.files = files
			tries = 0
			prompt = true
		elseif typ == ZFIN then
			m:emit(hexhdr(ZFIN, ZERO))
			m:emit("OO")
			m.files = files
			return files
		elseif typ == ZSINIT then
			-- TESCCTL says the sender escapes every control
			-- character, which means its reader discards the
			-- ones we leave raw. Match it or it never sees our
			-- next header.
			if sbyte(f, 4) & ESCCTL ~= 0 then
				m.escall = true
			end

			local d = m:subpacket()

			if d ~= nil then
				m:emit(hexhdr(ZACK, ZERO))
				tries = 0
			else
				tries = tries + 1
			end
		elseif typ == ZRQINIT then
			tries = 0
			prompt = true
		elseif typ == nil and f == "cancelled" then
			m.err = "cancelled"
			return nil
		else
			-- a timeout, or a frame that means nothing here. Say
			-- ZRINIT again either way: the sender may never have
			-- heard the first one.
			tries = tries + 1
			prompt = true
		end
		::continue::
	end
end

-- ---- sender ----

local function sendfile(m, file, use32, bufsize)
	-- The body is either a string or a reader. A reader is what makes
	-- a transfer bigger than memory possible: read(off, n) is called
	-- for the bytes about to go on the wire and nothing older is kept,
	-- so the sender's footprint is one block plus whatever the driver
	-- has not written yet. It takes an offset rather than being a
	-- stream because ZRPOS can send it backwards -- recovery is
	-- position-based, so a reader that cannot seek cannot recover.
	local data = file.data
	local read = file.read

	-- published for the driver: Mach:want yields the request out, and
	-- whoever is driving needs the function to answer it with.
	m.filereader = read
	local total = file.size or (data and #data) or 0

	if not data and not read then
		return nil, "file " .. tostring(file.name) ..
		    " has neither data nor read"
	end

	local info = file.name .. "\0" ..
	    string.format("%d %o %o 0 1 %d", total, file.mtime or 0,
	        file.mode or 0x1a4, total) .. "\0"
	local tries = 0
	local pos

	m:emit(binhdr(ZFILE, string.char(0, 0, 0, ZCBIN), use32, m.escall))
	m:emit(subpkt(info, ZCRCW, use32, m.escall))
	while true do
		if tries > m.retries then
			return nil, "no answer to ZFILE"
		end

		local typ, f = m:gethdr()

		if typ == ZRPOS then
			pos = unpos(f)
			break
		elseif typ == ZSKIP then
			return true
		elseif typ == nil and f == "cancelled" then
			return nil, "cancelled"
		elseif typ == nil then
			-- only silence is a reason to say it again. A
			-- ZRINIT here is the receiver's answer to our
			-- ZRQINIT arriving late; resending ZFILE at it put
			-- a duplicate file in flight and the two ends
			-- chased each other one frame apart forever.
			tries = tries + 1
			m:emit(binhdr(ZFILE, string.char(0, 0, 0, ZCBIN),
			    use32, m.escall))
			m:emit(subpkt(info, ZCRCW, use32, m.escall))
		else
			tries = tries + 1
		end
	end

	tries = 0
	-- data frames until the whole file is behind us, then ZEOF; a
	-- ZRPOS answering the ZEOF sends us round again from there.
	while true do

	while pos < total do
		if tries > m.retries then
			return nil, "too many retries sending " .. file.name
		end

		local acked = pos
		local restart = false

		m:emit(binhdr(ZDATA, pos4(pos), use32, m.escall))
		while pos < total do
			local n = m.blocksize

			if total - pos < n then
				n = total - pos
			end

			local chunk

			if data then
				chunk = data:sub(pos + 1, pos + n)
			else
				chunk = m:want(pos, n)
				if chunk == nil or #chunk == 0 then
					return nil, "short read at " .. pos
				end
				n = #chunk
			end
			pos = pos + n

			local term = ZCRCG

			if pos >= total then
				term = ZCRCW
			elseif bufsize > 0 and pos - acked >= bufsize then
				term = ZCRCQ
			end
			m:emit(subpkt(chunk, term, use32, m.escall))
			m.bytes = pos

			if term == ZCRCG then
				-- Streaming: no ack is due. Only look at
				-- the line if the receiver has actually
				-- said something, which on a healthy
				-- transfer it never does.
				if m.pos <= #m.inbuf then
					local t2, f2 = m:gethdr()

					if t2 == ZRPOS then
						pos = unpos(f2)
						restart = true
						break
					elseif t2 == nil and
					    f2 == "cancelled" then
						return nil, "cancelled"
					end
				end
			else
				local t2, f2 = m:gethdr()

				if t2 == ZACK then
					acked = unpos(f2)
				elseif t2 == ZRPOS then
					pos = unpos(f2)
					restart = true
					break
				elseif t2 == nil and f2 == "cancelled" then
					return nil, "cancelled"
				else
					pos = acked
					restart = true
					tries = tries + 1
					break
				end
			end
			m:maybeflush()
		end
		if not restart then
			break
		end
	end

	local again = false

	tries = 0
	m:emit(binhdr(ZEOF, pos4(total), use32, m.escall))
	while not again do
		if tries > m.retries then
			return nil, "no answer to ZEOF"
		end

		local typ, f = m:gethdr()

		if typ == ZRINIT then
			return true
		elseif typ == ZRPOS and unpos(f) < total then
			-- the receiver is behind: go round from there. A
			-- ZRPOS *at* total is the answer to a frame we have
			-- already moved past, not a request.
			pos = unpos(f)
			again = true
		elseif typ == nil and f == "cancelled" then
			return nil, "cancelled"
		elseif typ == nil then
			tries = tries + 1
			m:emit(binhdr(ZEOF, pos4(total), use32, m.escall))
		else
			tries = tries + 1
		end
	end
	tries = 0

	end
end

local function sendbody(m)
	local tries = 0
	local rx

	while true do
		if tries > m.retries then
			m.err = "no receiver"
			return nil
		end
		m:emit(hexhdr(ZRQINIT, ZERO))

		local typ, f = m:gethdr()

		if typ == ZRINIT then
			rx = f
			break
		elseif typ == ZCHALLENGE then
			m:emit(hexhdr(ZACK, f))
		elseif typ == nil and f == "cancelled" then
			m.err = "cancelled"
			return nil
		end
		tries = tries + 1
	end

	local rxflags = sbyte(rx, 4)
	local bufsize = sbyte(rx, 1) | (sbyte(rx, 2) << 8)
	local use32 = m.crc32 and (rxflags & CANFC32) ~= 0

	-- kept because what the far end asked for decides how a transfer
	-- behaves: a window makes the sender stop for an ack, and escall
	-- decides how many bytes a body becomes.
	m.rxbufsize, m.rxflags = bufsize, rxflags
	m.crc32 = use32
	-- What the receiver asked for, now that it has said. The frames
	-- before this went out escaped because nothing was known then;
	-- the body need not be, and on a screenshot -- 91% of whose bytes
	-- are control characters once a dark pixel is widened -- escaping
	-- everything is twice the wire.
	m.escall = m.escforce or (rxflags & ESCCTL) ~= 0

	for _, file in ipairs(m.tosend) do
		local ok, err = sendfile(m, file, use32, bufsize)

		if not ok then
			m.err = err
			return nil
		end
	end

	tries = 0
	while true do
		m:emit(hexhdr(ZFIN, ZERO))

		local typ = m:gethdr()

		if typ == ZFIN then
			m:emit("OO")
			return true
		end
		tries = tries + 1
		if tries > m.retries then
			m.err = "no answer to ZFIN"
			return nil
		end
	end
end

-- ---- construction ----

local function newmach(body, opts)
	opts = opts or {}

	local m = setmetatable({
		inbuf = "", pos = 1, out = {}, outn = 0,
		now = 0, state = "running", bytes = 0,
		timeout = opts.timeout or 10000,
		retries = opts.retries or 10,
		blocksize = opts.blocksize or 8192,
		outmax = opts.outmax or 32768,
		crc32 = opts.crc32 ~= false,
		-- on until the peer has said otherwise: nothing is known
		-- about it before its ZRINIT, and one in ESCCTL mode drops
		-- unescaped control bytes. A sender narrows this to what
		-- was asked for once it has read those flags.
		escall = opts.escctl ~= false,
		-- escctl = true asks for it whatever the peer says
		escforce = opts.escctl == true,
		sink = opts.sink,
		-- a body reader that PARKS. See Mach:want: it makes the read
		-- a request the driver answers from outside the coroutine,
		-- because a yield in here reaches Mach:run and nothing else.
		yieldread = opts.yieldread,
		-- the same, for a sink that writes to a file server.
		yieldwrite = opts.yieldwrite,
		window = opts.window,
	}, Mach)

	m.co = coroutine.create(function()
		return body(m)
	end)
	return m
end

-- receiver: on success m.result (and m.files) is a list of
-- { name =, size =, received = }, each with a `data` field unless
-- opts.sink took the bytes instead.
--
-- opts.sink(info) -> { write = f(offset, s), close = f(ok) } is what
-- keeps a transfer off the heap: the receiver never rewinds, so writes
-- arrive in order and nothing is retained between them.
function M.receiver(opts)
	return newmach(recvbody, opts)
end

-- sender: files is one file or a list. A file is { name =, data = } or
-- { name =, size =, read = f(offset, n) -> s } -- see sendfile for why
-- the reader takes an offset.
function M.sender(files, opts)
	local m = newmach(sendbody, opts)

	m.tosend = (files.data or files.read) and { files } or files
	return m
end

-- ---- driver, for callers that have a blocking line ----
--
-- line = { read = f(ms) -> string|nil, write = f(s), now = f() -> ms }.
--
-- Both kinds of blocking happen HERE, outside the coroutine, and that
-- is the point: a yield inside it unwinds to Mach:run rather than to
-- the caller's own scheduler.
function M.drive(m, line)
	while true do
		local st = m:run(line.now())
		local out = m:pull()

		if out then
			line.write(out)
		end
		if st ~= "running" then
			if st == "done" then
				return m.result
			end
			return nil, m.err
		end
		if m.filereq then
			-- a body served by a reader rather than a string. The
			-- reader may park; it is called from out here so that
			-- parking reaches whoever should hear it.
			m.filedata = m.filereader(m.filereq.off,
			    m.filereq.n)
		end
		if m.sinkreq then
			-- the receiver's counterpart of filereq: a sink that
			-- writes to a file server parks, so the call is made
			-- from out here.
			m.sinkres = m:sinkdo(m.sinkreq.op, m.sinkreq.a,
			    m.sinkreq.b)
		end
		if m.wantinput then
			local d = line.read(m:timeleft(line.now()))

			if d and #d > 0 then
				m:feed(d)
			end
		end
	end
end

return M
