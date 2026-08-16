-- console: the tty logic with no notion of which device carries it.
--
-- the line editor, getch, and the tty protocol a program consumes --
-- {op="write"}, {op="log"}, {op="readline"}, {op="read"}, {op="getch"},
-- {op="readraw"}, {op="intr"},
-- {op="rawon"}/{op="rawoff"} -- are all bytes-in, bytes-out and care
-- nothing for the wire underneath. so they live here, and the device is
-- injected:
--
--   backend.write(s)        emit bytes to the far end
--   backend.keyport         the receive right raw keystrokes arrive on
--   backend.claim_input()   optional; where one wire is shared and the
--                           bytes must be claimed before they are keys
--                           (microvm's com1 is keyboard and 9p both)
--
-- task/cons.lua binds the serial device; a framebuffer console binds a
-- glyph renderer over task/fb; a window multiplexer binds virtual ports.
-- all three hand a program the same tty capability (see lib/caps.lua and
-- lib/prog.lua), so vi.lua never learns which is underneath it.
--
-- keyport is a right, not a readkey() function, on purpose: readline
-- waits on the keyboard AND the mailbox at once (thread.alt below), so a
-- write from another proc shows while a line is mid-edit rather than
-- freezing until Enter. hiding the key source behind a call would lose
-- that -- the core has to hold the port to alt on it.
--
-- the dispatch runs under thread.run() so getch can time out
-- (thread.recvtimeout needs the scheduler), which is what tells a bare
-- Escape from the first byte of an arrow-key sequence.

local sys = require("los.sys")
local thread = require("los.thread")

-- the most bytes readraw will gather into one reply. A batch is held as
-- one lua string per byte until the concat, so this is a memory ceiling
-- rather than a throughput knob.
local MAXRAW = 512

-- how long readraw waits for more once it has some. A reader moving a
-- file asks for hundreds of bytes and a line delivers them in pieces,
-- so returning on the first piece costs a round trip per piece:
-- measured at 3984 reads of 7.8 bytes for a 24KB transfer, with 98% of
-- the wall time inside the read.
local GATHER = 2

-- the interrupt character, uniformly, whatever the terminal is: a
-- serial line and an ssh client both send 0x03 for it, and a keyboard
-- without a control key maps some combination to the same byte rather
-- than inventing a second convention for the layers above to know
-- about.
local INTR = "\3"

-- how many lines of history a terminal remembers. Small on purpose:
-- this is per console and lives for the life of the machine, and a
-- serial console's value is in the last few lines, not in a searchable
-- archive.
local HISTMAX = 64

-- how long to wait for the rest of an escape sequence before deciding
-- there is none and the key was a bare Escape. The bytes of a real
-- arrow key arrive together at any line speed; a human cannot follow
-- Escape with [ this fast.
local ESCWAIT = 50

local M = {}
local Console = {}

Console.__index = Console

-- opts.other is called with any message the dispatch does not recognise.
-- opts.kbdother is called with anything on the keyboard port that is not
-- a keystroke: under a window system that port carries window state too,
-- and a table is not something a reader can be handed as input.
--
-- The console serves on the proc's own port, where the kernel also
-- delivers sys.monitor's {exit=pid} notices. A shell sharing the proc
-- waits for those, so what is not tty traffic is handed on rather than
-- dropped.
function M.new(backend, opts)
	local c = setmetatable({
		io = backend,
		kbd = backend.keyport,
		other = opts and opts.other,
		kbdother = opts and opts.kbdother,
		-- keystrokes that are not the interrupt character, put
		-- here by the pump. readline and getch take from this
		-- rather than from the keyboard, so every byte has been
		-- looked at by the time either sees one.
		inq = sys.newport("console.inq"),
		-- messages that landed on sys.SELF while readline was mid-line
		-- and are not its business: serve drains them once the line is
		-- done, so a getch or a second reader that arrived during editing
		-- is not lost.
		deferred = {},
		-- edited lines, oldest first, shared by every readline on this
		-- terminal. It belongs to the console rather than to the shell
		-- because the editor is here: a repl, a dos shell and anything
		-- else that asks for a line all get the same up-arrow, and none
		-- of them has to keep a ring of its own.
		history = {},
	}, Console)

	-- A backend that answers a query needs a way back into the input,
	-- because that is where an answer goes: a program asking the
	-- cursor position reads the reply as keystrokes. Only a backend
	-- that draws has one to give.
	if backend.setreply then
		backend.setreply(function(s) c:queue(s) end)
	end
	return c
end

-- who to tell when the interrupt character is typed, or nobody when the
-- reply is absent. A shell claims this while a program it started runs
-- and drops it afterwards, so the character means "stop that" exactly
-- while there is a that.
--
-- One listener, not a list: two claimants would each get half the
-- interrupts, and which half would depend on the order they registered.
--
-- Served wherever it arrives, including mid-line, which is the whole
-- reason it is a method. A shell claims the interrupt just after it
-- starts the program, and the program's own read is what the console is
-- likely to be busy with at that moment -- so deferring the claim to
-- the end of the read leaves it unclaimed for exactly as long as the
-- program runs, and the character it should stop with lands in the
-- program's input instead.
function Console:setintr(m)
	if self.intr then
		sys.close(self.intr)
	end
	self.intr = m.reply and m.reply.__right
end

-- one raw keystroke for a full-screen program: no echo, no line editing,
-- just the next byte. an optional timeout in ms is what tells a lone
-- Escape from the first byte of an arrow-key sequence -- with none, block
-- for a key.
--
-- Waits on the keyboard AND the mailbox, as readline does, and for the
-- same reason: a full-screen program draws a frame and then asks for a
-- key, so a console watching only the keyboard holds that frame until
-- the next keystroke. What it shows is then always one frame behind,
-- and the last frame never arrives at all -- a message from the network
-- is invisible until you type. Anything that is not a write waits for
-- serve, which is what `deferred` is for.

-- one keystroke, from a chunk that may hold many.
--
-- The pump delivers whatever arrived together, so a reader taking one
-- key at a time keeps the rest here. Bytes, not messages, are what the
-- callers are counting.
function Console:getch(ms)
	local p = self.pend

	if p and p ~= "" then
		self.pend = p:sub(2)
		return p:sub(1, 1)
	end

	local c = self:recvchunk(ms)

	if type(c) ~= "string" or c == "" then
		return c
	end
	self.pend = c:sub(2)
	return c:sub(1, 1)
end

-- everything queued, in one string: what getch left plus one chunk.
function Console:readchunk(ms)
	local p = self.pend

	if p and p ~= "" then
		self.pend = ""
		return p
	end
	return self:recvchunk(ms)
end

-- one key, waiting at most ms for it, from `pend` first as getch does:
-- the queue delivers a chunk and whoever splits one leaves the rest
-- there for the next reader.
--
-- Not the only splitter. readline takes from `pend` itself, because it
-- waits on the mailbox as well and this waits only on the keyboard.
function Console:keytimeout(ms)
	local p = self.pend

	if p and p ~= "" then
		self.pend = p:sub(2)
		return p:sub(1, 1)
	end

	local c = thread.recvtimeout(self.inq, ms)

	if type(c) ~= "string" or c == "" then
		return c
	end
	self.pend = c:sub(2)
	return c:sub(1, 1)
end

function Console:recvchunk(ms)
	local timer = ms and sys.timer(ms) or nil

	-- no timer to be had: keep the deadline, which is what an escape
	-- sequence is told from a bare Escape by, and give up serving
	-- writes for the few milliseconds it takes.
	if ms and not timer then
		return thread.recvtimeout(self.inq, ms)
	end

	local cases = { { port = self.inq }, { port = sys.SELF } }

	if timer then
		cases[3] = { port = timer }
	end

	local function done(c)
		if timer then
			sys.close(timer)
		end
		return c
	end

	while true do
		local which, m = thread.alt(cases)

		if which == 1 then
			return done(m)
		elseif which == 3 then
			return done(nil)	-- nil on timeout
		elseif type(m) == "table" and not m.reply and
		    (m.op == "write" or m.op == "log") then
			self.io.write(m.data)
		elseif type(m) == "table" and m.op == "intr" then
			self:setintr(m)
		elseif type(m) == "table" and m.op == "abort" then
			return done(nil)
		elseif type(m) == "table" and m.op == "poweroff" then
			self:poweroff(m)
		else
			self.deferred[#self.deferred + 1] = m
		end
	end
end

-- read one edited line, prompt included. Waits on the keyboard AND the
-- mailbox at once, so a write from another proc (a log line, sshd coming
-- up) is shown as it arrives rather than frozen until Enter -- reprinting
-- the prompt and the half-typed line after it, the way a readline library
-- redisplays. No cursor addressing: a plain serial backend has no assumed
-- escape support, so the redraw is \r\n plus a reprint, the same
-- primitives the backspace erase already uses.
-- remember a line, unless there is nothing to remember: a blank line,
-- or the line that is already on top. A history full of the same
-- command repeated is a history you have to page through.
function Console:remember(line)
	local h = self.history

	if line == "" or h[#h] == line then
		return
	end
	h[#h + 1] = line
	if #h > HISTMAX then
		table.remove(h, 1)
	end
end

function Console:readline(prompt)
	local io = self.io
	local buf = {}
	-- where in the history the line being edited came from. #history+1
	-- means "the line you are typing", which is not in the history yet
	-- and is kept in `live` while you are looking at older ones.
	local hpos = #self.history + 1
	local live = ""

	local function erase(n)
		io.write(("\8 \8"):rep(n))
	end

	-- swap the line under the cursor for another one. No cursor
	-- addressing: erase what is there with the backspaces the editor
	-- already uses and print the replacement, so this works on a serial
	-- line that answers no escape sequence at all.
	local function replace(s)
		erase(#buf)
		buf = {}
		for i = 1, #s do
			buf[i] = s:sub(i, i)
		end
		io.write(s)
	end

	-- an escape sequence, or a bare Escape. Called with the \27 already
	-- taken; returns "up", "down" or nil, plus any byte it read that
	-- turned out not to belong to a sequence. The caller types that
	-- second value: Escape followed by an ordinary letter is two
	-- keystrokes, and dropping the letter would be the editor eating
	-- input. The wait is what tells the two apart -- see ESCWAIT.
	--
	-- Both cursor-key forms are read: a terminal in application mode
	-- sends ESC O A where the normal mode sends ESC [ A, and which one
	-- arrives is the far end's business, not ours.
	local function arrow(final)
		if final == "A" then
			return "up"
		elseif final == "B" then
			return "down"
		end
		return nil	-- left, right, home, a mouse report: swallowed
	end

	local function escape()
		local c = self:keytimeout(ESCWAIT)

		if c == "O" then
			return arrow(self:keytimeout(ESCWAIT))
		end
		if c ~= "[" then
			-- a bare Escape, and c is whatever was typed next
			return nil, c
		end
		-- a CSI sequence runs to its final byte (0x40-0x7e) and the
		-- parameters before it are any length -- Delete is ESC [ 3 ~.
		-- Reading to the final byte is what keeps the tail of a
		-- sequence we ignore from being typed into the line.
		local f

		repeat
			f = self:keytimeout(ESCWAIT)
		until f == nil or f:match("[@-~]")
		return arrow(f)
	end

	local function redraw(msg)
		io.write("\r\n")
		io.write(msg)
		if prompt then
			io.write(prompt)
		end
		io.write(table.concat(buf))
	end

	if prompt then
		io.write(prompt)
	end

	-- one byte of pushback: what escape() read looking for a sequence
	-- that was not there. It is handled by the loop below rather than
	-- pushed back onto the port, so it keeps its place -- returning it
	-- to the queue would put it BEHIND anything already waiting there,
	-- which reorders a paste that contains an escape.
	local pending

	while true do
		local c = pending

		pending = nil
		if c == nil and self.pend and self.pend ~= "" then
			-- the rest of a chunk this editor already has: taking
			-- it before waiting is what keeps a pasted line from
			-- stopping halfway.
			c = self.pend:sub(1, 1)
			self.pend = self.pend:sub(2)
		end
		if c == nil then
			local which, m = thread.alt({ { port = self.inq },
			    { port = sys.SELF } })

			if which == 1 then
				c = m:sub(1, 1)
				self.pend = m:sub(2)
			-- a mailbox message mid-line: a write shows now;
			-- anything else waits for serve, so nothing is
			-- dropped.
			elseif type(m) == "table" and
			    (m.op == "write" or m.op == "log") then
				redraw(m.data)
			elseif type(m) == "table" and m.op == "intr" then
				self:setintr(m)
			elseif type(m) == "table" and m.op == "abort" then
				io.write("\n")
				return nil
			elseif type(m) == "table" and m.op == "poweroff" then
				self:poweroff(m)
			else
				self.deferred[#self.deferred + 1] = m
			end
		end

		if c ~= nil then
			if c == "\r" or c == "\n" then
				local line = table.concat(buf)

				io.write("\n")
				self:remember(line)
				return line
			elseif c == "\4" then
				if #buf == 0 then
					return nil
				end
			elseif c == "\8" or c == "\127" then
				if #buf > 0 then
					table.remove(buf)
					erase(1)
				end
			elseif c == "\21" then
				-- ctrl-u: kill the whole line
				erase(#buf)
				buf = {}
			elseif c == "\27" then
				local key
				local h = self.history

				key, pending = escape()

				-- the line you were typing is kept at
				-- #history+1 and comes back when you walk
				-- down past the newest entry, so a recall
				-- you did not want costs nothing.
				if key == "up" and hpos > 1 then
					if hpos == #h + 1 then
						live = table.concat(buf)
					end
					hpos = hpos - 1
					replace(h[hpos])
				elseif key == "down" and hpos <= #h then
					hpos = hpos + 1
					replace(hpos == #h + 1 and live
					    or h[hpos])
				end
			elseif #c == 1 and c >= " " then
				buf[#buf + 1] = c
				io.write(c)
			end
		end
	end
end

-- the input pump: everything typed passes through here.
--
-- It exists because nothing else looks at the keyboard while a program
-- is running. readline and getch read when a reader asks, so a proc
-- that has stopped asking -- looping, or blocked on something that will
-- not answer -- leaves its keystrokes sitting in the port with no one
-- to notice what they are. The interrupt character has to be seen when
-- nobody is listening, which is exactly when it is typed.
--
-- Everything else is forwarded unchanged, so a reader cannot tell the
-- pump is there.

-- into the input queue, waiting for room rather than losing what does
-- not fit. A dropped chunk of a file transfer is a checksum failure a
-- long way from its cause. Waiting is also what stops the machine ahead
-- of us: nothing drains the keyboard port meanwhile, so the kernel
-- stops reading the device.
function Console:queue(c)
	while true do
		local ok, why, need = sys.send(self.inq, c)

		if ok ~= nil or why ~= "full" then
			return
		end
		-- parksend, not sys.sendblock: this runs in the pump thread,
		-- and only the coroutine the kernel resumed may park.
		thread.parksend(self.inq, need)
	end
end

function Console:pump()
	while true do
		local c = thread.recv(self.kbd)

		if type(c) == "string" and self.intr and not self.raw and
		    c:find(INTR, 1, true) then
			-- to whoever asked to hear it, and not into the
			-- input: a program being interrupted should not
			-- also read the character that interrupted it.
			-- Every one in the chunk, not the first, since a
			-- read returns a batch of keys and mashing the key
			-- puts several in one.
			sys.send(self.intr, { op = "interrupt" })
			-- the console is usually inside a read for the
			-- program being killed, and a dead program never
			-- types the line that would end it.
			sys.send(thread.selfright(), { op = "abort" })
			c = c:gsub(INTR, "")
			if c ~= "" then
				self:queue(c)
			end
		elseif type(c) == "table" then
			-- not input: a window system shares this port with
			-- the keys. Handed on, never typed.
			if self.kbdother then
				self.kbdother(c)
			end
		elseif c ~= nil then
			self:queue(c)
		end
	end
end

-- shut the machine down, but not before what was written is written. A
-- sender cannot arrange that itself: the console and the power task are
-- different procs, so a reset sent straight to power races the output
-- still queued here. Handled wherever a message is taken, never
-- deferred: a reader waiting on a key would hold the machine up forever.
function Console:poweroff(m)
	if m.power then
		sys.send(m.power.__right,
		    { op = "reset", mode = m.mode or "shutdown" })
	end
end

function Console:serve()
	local io = self.io

	thread.spawn(function()
		self:pump()
	end)

	while true do
		-- messages readline set aside mid-line come first, so their order
		-- relative to the rest of the mailbox is kept.
		local m = table.remove(self.deferred, 1) or thread.recv(sys.SELF)

		-- closed at the end of the loop: a right in a message is a
		-- copy this proc owns, and a reader that polls leaks one per
		-- request. Deferred messages are closed when handled, not
		-- when first seen.
		local reply = m.reply and m.reply.__right

		if m.op == "write" or m.op == "log" then
			-- log lines arrive already stamped and tagged
			-- (lib/log.lua); the console is the console, not the
			-- formatter.
			--
			-- Coalesce a burst of writes into one backend write. A
			-- full-screen program redraws by emitting a cursor move,
			-- an erase and a line per row, each its own message; a
			-- backend that draws a cursor or flushes a panel per
			-- write (lib/fbcons.lua) then pays that per fragment
			-- rather than per frame. Draining what is already queued
			-- and writing it once is most of what makes the fb
			-- console quick. Order is kept; a non-write ends the run
			-- and is put back for the next turn of the loop.
			local parts = { m.data }

			while true do
				local ok, nxt = sys.tryrecv(sys.SELF)

				if not ok then
					break
				end
				if type(nxt) == "table" and not nxt.reply and
				    (nxt.op == "write" or nxt.op == "log") then
					parts[#parts + 1] = nxt.data
				else
					table.insert(self.deferred, 1, nxt)
					break
				end
			end
			io.write(table.concat(parts))
		elseif m.op == "intr" then
			self:setintr(m)
			reply = nil		-- kept, so not closed below
		elseif m.op == "abort" then
			-- nothing was reading: the interrupt arrived between
			-- one read and the next, so there is nothing to end.
		elseif m.op == "poweroff" then
			self:poweroff(m)
		elseif m.op == "size" then
			-- how wide the far end is, for a program that lays
			-- out columns. A backend that knows says so
			-- (lib/fbcons.lua counts cells); a serial line does
			-- not, and answers nil rather than a number -- there
			-- is no escape sequence here to ask a terminal with,
			-- and a guess dressed as a measurement is worse than
			-- no measurement.
			if reply then
				sys.send(reply, { cols = io.cols,
				    rows = io.rows })
			end
		elseif m.op == "claim_input" then
			-- where one wire carries keyboard and data both, the
			-- backend claims it here rather than the core assuming so;
			-- absent on a device with a dedicated key line.
			if io.claim_input then
				io.claim_input()
			end
		elseif m.op == "rawon" or m.op == "rawoff" then
			-- there is no cooked line state here to toggle: getch
			-- already bypasses the readline editor. io.write is
			-- usually the same bytes either way -- but not on a device
			-- that rewrites them, and esp32's turns \n into \r\n,
			-- which corrupts any binary stream carrying 0x0a. So a
			-- device that has something to switch gets told.
			--
			-- and it turns the interrupt character off, which
			-- is a tty's ISIG: raw means every byte reaches the
			-- program unexamined. A binary stream carries 0x03
			-- like any other value -- a zmodem receiver's
			-- headers and acks do -- so a console still watching
			-- for it would kill the transfer with the transfer's
			-- own traffic.
			self.raw = m.op == "rawon"
			if io.raw then
				io.raw(m.op == "rawon")
			end
		elseif m.op == "getch" then
			-- "" rather than nil on a timeout: sys.send carries one
			-- value and a reader wants to tell "nothing yet" from a
			-- dropped reply.
			local c = self:getch(m.timeout)

			if reply then
				sys.send(reply, c or "")
			end
		elseif m.op == "readraw" then
			-- bulk sibling of getch, for a reader moving bytes
			-- rather than keystrokes. Same bytes, one reply.
			--
			-- getch costs a message round trip per byte, and a
			-- file transfer is not a keyboard: measured at about
			-- 1KB/s on a line running at 115200, which is the
			-- round trips and not the link. Waiting once for the
			-- first byte and then taking whatever else is already
			-- queued turns a subpacket into one reply.
			-- bounded hard, not by what the caller asks: every
			-- byte is a lua string object until the concat, so
			-- the batch is the peak.
			local want = m.n or MAXRAW

			if want > MAXRAW then
				want = MAXRAW
			end

			local t, got = {}, 0
			local c = self:readchunk(m.timeout or 1000)

			while type(c) == "string" and c ~= "" do
				if got + #c > want then
					-- the tail belongs to the next read,
					-- not to this one's bound.
					self.pend = c:sub(want - got + 1) ..
					    (self.pend or "")
					c = c:sub(1, want - got)
				end
				t[#t + 1] = c
				got = got + #c
				if got >= want then
					break
				end
				c = self:readchunk(GATHER)
			end
			if reply then
				sys.send(reply, table.concat(t))
			end
		elseif m.op == "readline" then
			sys.send(reply, self:readline(m.prompt))
		elseif m.op == "read" then
			-- the ABI stream protocol (lib/prog.lua's PortStream), so
			-- the console can BE a program's stdin. it is the same
			-- readline underneath -- a terminal is line-buffered and
			-- edited whoever is asking -- with the newline put back,
			-- since a reader of a byte stream expects the line
			-- terminator that a readline caller does not.
			--
			-- nil stays nil: readline reports eof (ctrl-d on an empty
			-- line) that way and PortStream:read turns it into "",
			-- which is the ABI's eof. losing that distinction here
			-- would make ctrl-d unrepresentable to a program.
			local line = self:readline()

			sys.send(reply, line and (line .. "\n") or nil)
		elseif self.other then
			-- not tty traffic: an exit notice, or anything else
			-- addressed to this proc rather than to its console.
			self.other(m)
		end

		if reply then
			sys.close(reply)
		end
	end
end

-- under thread.run() (not a bare top-level loop) so getch can time out:
-- thread.recvtimeout is built on the scheduler's alt, which needs it.
function Console:run()
	thread.spawn(function()
		self:serve()
	end)
	thread.run()
end

return M
