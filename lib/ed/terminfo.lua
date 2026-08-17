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

-- the letter a CSI sequence ends with, as a name.
local CSIKEY = {
	A = "up", B = "down", C = "right", D = "left",
	H = "home", F = "end", E = "keypad5", Z = "backtab",
}

-- and the SS3 forms, which the keypad and F1-F4 arrive as. P through S
-- are here and not above on purpose: ESC[R is a cursor report, and a
-- program that read it as F3 would answer its own question.
local SS3KEY = {
	A = "up", B = "down", C = "right", D = "left",
	H = "home", F = "end", E = "keypad5",
	P = "f1", Q = "f2", R = "f3", S = "f4",
	M = "enter", j = "*", k = "+", m = "-", n = "delete", o = "/",
}

-- the `ESC [ n ~` forms. The function keys skip 16 and 22 because the
-- numbering was laid out for a keyboard whose rows did not match.
local TILDE = {
	[1] = "home", [2] = "insert", [3] = "delete", [4] = "end",
	[5] = "pageup", [6] = "pagedown", [7] = "home", [8] = "end",
	[11] = "f1", [12] = "f2", [13] = "f3", [14] = "f4", [15] = "f5",
	[17] = "f6", [18] = "f7", [19] = "f8", [20] = "f9", [21] = "f10",
	[23] = "f11", [24] = "f12",
}

-- the modifier a second parameter names, as a prefix. 1 is none, and the
-- rest is a bitmask one greater than itself: 5 is 4, control.
local function modprefix(n)
	if not n or n <= 1 then
		return ""
	end

	local m = n - 1
	local out = ""

	if m & 4 ~= 0 then
		out = out .. "c"
	end
	if m & 1 ~= 0 then
		out = out .. "s"
	end
	if m & 2 ~= 0 then
		out = out .. "a"
	end
	return out == "" and "" or out .. "-"
end

-- one keypress, an escape sequence resolved to a name.
--
-- ms bounds the wait for the first byte only: a deadline that expired
-- mid-sequence would split one keystroke into an Escape and letters.
-- Returns nil plus "timeout" or "eof", and a dead terminal reads as a
-- timeout -- the console answers both with the same empty string.
function M:readkey(ms)
	if not self.tty then
		return nil, "eof"
	end

	local c = ms and self.tty.getch(ms) or self.tty.getch()

	if c == "" or c == nil then
		return nil, ms and "timeout" or "eof"
	end
	if c ~= ESC then
		return c
	end

	local c2 = self.tty.getch(SEQ_MS)

	if c2 == "" then
		return "escape"
	end
	if c2 == "O" then
		local c3 = self.tty.getch(SEQ_MS)

		return SS3KEY[c3] or ("escO" .. (c3 == "" and "" or c3))
	end
	if c2 ~= "[" then
		return "esc" .. c2
	end

	-- CSI: parameters, then the letter that ends it. The parameters
	-- are read here rather than skipped because the second one is the
	-- modifier -- ESC[1;5A is control-up, and reading only the 1 makes
	-- it Home.
	local parm = ""
	local c3 = self.tty.getch(SEQ_MS)

	while c3 ~= "" and c3 ~= nil and
	    ((c3 >= "0" and c3 <= "9") or c3 == ";") do
		parm = parm .. c3
		c3 = self.tty.getch(SEQ_MS)
	end

	if c3 == "" or c3 == nil then
		return "escape"
	end

	local first, second = parm:match("^(%d*);?(%d*)$")
	local mod = modprefix(tonumber(second))

	if c3 == "~" then
		local n = tonumber(first)

		return mod .. (TILDE[n] or ("esc[" .. (first or "") .. "~"))
	end
	return mod .. (CSIKEY[c3] or ("esc[" .. parm .. c3))
end

-- ask the terminal its size: park the cursor at a far corner, query the
-- position, restore. The reply is ESC[rows;colsR, read back through
-- getch. A terminal that does not answer (the firmware console does not)
-- times out and leaves the 24x80 default rather than hanging.
function M:detect_size()
	if not self.tty then
		return
	end

	-- A console that counts its own cells answers directly, and one
	-- that cannot asks the terminal -- both of which detectsize does,
	-- so an editor and an ssh client measure the same way.
	local cols, rows = self.tty.detectsize()

	if cols and rows then
		self.cols, self.rows = cols, rows
	end
end

return M
