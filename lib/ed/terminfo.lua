-- ed/terminfo.lua - terminal control for a full-screen program, over the
-- console the launcher lent it (prog.tty). ANSI/VT100 out, raw keystrokes
-- in.
--
-- This is the lua-os port of the posix ed/terminfo: same method surface,
-- so ed/vi.lua needs no change, but the body speaks to a tty capability
-- (lib/caps.lua) rather than to posix.termio/unistd. The cooking a real
-- terminal does in the kernel is done by the console instead --
-- rawon/rawoff switch line-edited mode off and back, and getch delivers
-- one un-echoed byte -- so the same editor drives a serial console, an
-- ssh session or a browser terminal the way it drives a pty on unix.
--
-- The timeout that tells a lone Escape from an arrow-key sequence lives
-- in the console (it answers "" after the timeout); readkey here just
-- asks for the next byte with a deadline and reads what comes back.

local M = {}

local ESC = "\027"
local CSI = ESC .. "["

-- how long to wait for the rest of an escape sequence after ESC. The
-- bytes of a real sequence arrive together (the firmware and every
-- terminal send them in one burst), so this only ever elapses for a bare
-- Escape keypress.
local SEQ_MS = 50

function M.new()
	local tty = require("prog").tty()
	local self = {
		rows = 24,
		cols = 80,
		tty = tty,
	}

	return setmetatable(self, { __index = M })
end

-- whether there is a terminal at all. vi checks this and refuses to run
-- without one, which is what "not a terminal" means here.
function M:ok()
	return self.tty ~= nil
end

function M:write(s)
	if self.tty then
		self.tty.write(s)
	end
end

-- ---- cursor movement ----

function M:move(row, col)
	self:write(CSI .. row .. ";" .. col .. "H")
end

function M:up(n)
	self:write(CSI .. (n or 1) .. "A")
end

function M:down(n)
	self:write(CSI .. (n or 1) .. "B")
end

function M:right(n)
	self:write(CSI .. (n or 1) .. "C")
end

function M:left(n)
	self:write(CSI .. (n or 1) .. "D")
end

function M:home()
	self:write(CSI .. "H")
end

-- ---- clearing ----

function M:clear()
	self:write(CSI .. "2J" .. CSI .. "H")
end

function M:clear_line()
	self:write(CSI .. "2K")
end

function M:clear_eol()
	self:write(CSI .. "K")
end

function M:clear_eos()
	self:write(CSI .. "J")
end

-- ---- cursor visibility and attributes ----

function M:hide_cursor()
	self:write(CSI .. "?25l")
end

function M:show_cursor()
	self:write(CSI .. "?25h")
end

function M:reset()
	self:write(CSI .. "0m")
end

function M:bold()
	self:write(CSI .. "1m")
end

function M:reverse()
	self:write(CSI .. "7m")
end

-- ---- raw mode ----
--
-- On a posix host these were tcsetattr; here they tell the console to
-- stop line-editing and echoing (rawon) and to start again (rawoff). On
-- the serial console that is a no-op -- there is nothing to cook -- but
-- an ssh or browser session has a real cooked mode to leave, so the calls
-- have to be made either way. Kept named raw()/restore() so vi.lua reads
-- the same as it does on unix.

function M:raw()
	if self.tty then
		self.tty.rawon()
	end
end

function M:restore()
	if self.tty then
		self.tty.rawoff()
	end
end

-- ---- input ----
--
-- one keypress, an escape sequence resolved to a name. The console owns
-- the timeout: getch(SEQ_MS) returns "" if no byte arrives in time, which
-- is how a bare Escape (no sequence follows) is told from Up (ESC [ A,
-- arriving together).
function M:readkey()
	if not self.tty then
		return nil
	end
	local c = self.tty.getch()	-- block for the first byte

	if c == "" then
		return nil		-- the terminal went away: eof
	end
	if c ~= ESC then
		return c
	end

	local c2 = self.tty.getch(SEQ_MS)

	if c2 == "" then
		return "escape"
	end
	if c2 == "[" then
		local c3 = self.tty.getch(SEQ_MS)

		if c3 == "" then
			return "escape"
		end
		if c3 == "A" then
			return "up"
		elseif c3 == "B" then
			return "down"
		elseif c3 == "C" then
			return "right"
		elseif c3 == "D" then
			return "left"
		elseif c3 == "H" then
			return "home"
		elseif c3 == "F" then
			return "end"
		elseif c3 >= "0" and c3 <= "9" then
			-- extended \e[N~ forms
			local num = c3
			local c4 = self.tty.getch(SEQ_MS)

			while c4 ~= "" and c4 >= "0" and c4 <= "9" do
				num = num .. c4
				c4 = self.tty.getch(SEQ_MS)
			end
			local n = tonumber(num)

			if n == 1 then
				return "home"
			elseif n == 3 then
				return "delete"
			elseif n == 4 then
				return "end"
			elseif n == 5 then
				return "pageup"
			elseif n == 6 then
				return "pagedown"
			end
			return "esc[" .. num .. "~"
		end
		return "esc[" .. c3
	elseif c2 == "O" then
		local c3 = self.tty.getch(SEQ_MS)

		if c3 == "H" then
			return "home"
		elseif c3 == "F" then
			return "end"
		end
		return "escO" .. (c3 == "" and "" or c3)
	end

	return "esc" .. c2
end

-- ask the terminal its size: park the cursor at a far corner, query the
-- position, restore. The reply is ESC[rows;colsR, read back through
-- getch. A terminal that does not answer (the firmware console does not)
-- times out and leaves the 24x80 default rather than hanging.
function M:detect_size()
	if not self.tty then
		return
	end
	self:write(CSI .. "s" .. CSI .. "999;999H" .. CSI .. "6n" .. CSI .. "u")

	local buf = {}

	while true do
		local c = self.tty.getch(SEQ_MS)

		if c == "" or c == "R" then
			break
		end
		buf[#buf + 1] = c
	end

	local resp = table.concat(buf)
	local r, c = resp:match("%[(%d+);(%d+)")

	if r and c then
		self.rows = tonumber(r)
		self.cols = tonumber(c)
	end
end

return M
