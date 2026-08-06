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

-- the interrupt character, uniformly, whatever the terminal is: a
-- serial line and an ssh client both send 0x03 for it, and a keyboard
-- without a control key maps some combination to the same byte rather
-- than inventing a second convention for the layers above to know
-- about.
local INTR = "\3"

local M = {}
local Console = {}

Console.__index = Console

function M.new(backend)
	return setmetatable({
		io = backend,
		kbd = backend.keyport,
		-- keystrokes that are not the interrupt character, put
		-- here by the pump. readline and getch take from this
		-- rather than from the keyboard, so every byte has been
		-- looked at by the time either sees one.
		inq = sys.newport(),
		-- messages that landed on sys.SELF while readline was mid-line
		-- and are not its business: serve drains them once the line is
		-- done, so a getch or a second reader that arrived during editing
		-- is not lost.
		deferred = {},
	}, Console)
end

-- one raw keystroke for a full-screen program: no echo, no line editing,
-- just the next byte. an optional timeout in ms is what tells a lone
-- Escape from the first byte of an arrow-key sequence -- with none, block
-- for a key.
function Console:getch(ms)
	if ms then
		return thread.recvtimeout(self.inq, ms)	-- nil on timeout
	end
	return thread.recv(self.inq)
end

-- read one edited line, prompt included. Waits on the keyboard AND the
-- mailbox at once, so a write from another proc (a log line, sshd coming
-- up) is shown as it arrives rather than frozen until Enter -- reprinting
-- the prompt and the half-typed line after it, the way a readline library
-- redisplays. No cursor addressing: a plain serial backend has no assumed
-- escape support, so the redraw is \r\n plus a reprint, the same
-- primitives the backspace erase already uses.
function Console:readline(prompt)
	local io = self.io
	local buf = {}

	local function erase(n)
		io.write(("\8 \8"):rep(n))
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

	while true do
		local which, m = thread.alt({ { port = self.inq },
		    { port = sys.SELF } })

		if which ~= 1 then
			-- a mailbox message mid-line: a write shows now; anything
			-- else waits for serve, so nothing is dropped.
			if type(m) == "table" and
			    (m.op == "write" or m.op == "log") then
				redraw(m.data)
			else
				self.deferred[#self.deferred + 1] = m
			end
		else
			local c = m

			if c == "\r" or c == "\n" then
				io.write("\n")
				return table.concat(buf)
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
function Console:pump()
	while true do
		local c = thread.recv(self.kbd)

		if c == INTR and self.intr and not self.raw then
			-- to whoever asked to hear it, and not into the
			-- input: a program being interrupted should not
			-- also read the character that interrupted it.
			sys.send(self.intr, { op = "interrupt" })
		elseif c ~= nil then
			sys.send(self.inq, c)
		end
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
			-- who to tell when the interrupt character is
			-- typed, or nobody when the reply is absent. A
			-- shell claims this while a program it started is
			-- running and drops it afterwards, so the character
			-- means "stop that" exactly while there is a that.
			--
			-- One listener, not a list: two claimants would each
			-- get half the interrupts, and which half would
			-- depend on the order they registered.
			if self.intr then
				sys.close(self.intr)
			end
			self.intr = reply
			reply = nil		-- kept, so not closed below
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
			-- the batch is the peak. Measured on a Cardputer at
			-- n=2048, cons peaked at 95KB of a 125KB board.
			local want = m.n or MAXRAW

			if want > MAXRAW then
				want = MAXRAW
			end

			local t = {}
			local c = self:getch(m.timeout or 1000)

			while c and c ~= "" do
				t[#t + 1] = c
				if #t >= want then
					break
				end
				c = self:getch(0)
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
