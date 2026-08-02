-- cons: the sole task anywhere with los.platform.cons (raw console
-- write). also holds the raw keyboard recv right directly (handle 1
-- in this proc's own table, granted by the kernel at spawn -- not a
-- los.sys-wide constant; no other proc needs to know it). every other
-- proc holds, at most, a send-right to this task's mailbox and talks
-- by message: {op="write", data=s}, {op="log", data=s},
-- {op="readline", reply={__right=rp}} or {op="read", reply={__right=rp}}
-- -- the last being the same thing in the program-ABI spelling, which is
-- what lets the console serve as a program's stdin.

local sys = require("los.sys")
local thread = require("los.thread")
local platform = require("los.platform.cons")

local RAWKBD = 1

local function readone()
	return thread.recv(RAWKBD)
end

-- line editor: echo, backspace, ctrl-u, ctrl-d. runs entirely inside
-- cons, so every requester gets the same editing behavior regardless
-- of who's asking; nil replies mean eof on an empty line. no cursor
-- movement (append/erase from the end only) -- a plain serial console
-- with no assumed terminal escape support, not a full redraw-capable
-- tui (cf. ~/code/c/clm's tui.c, which tracks a cursor position and
-- redraws; not needed here since there's nowhere to move the cursor
-- to without ANSI support we don't assume the far end has).
local function readline()
	local buf = {}

	local function erase(n)
		platform.write(("\8 \8"):rep(n))
	end

	while true do
		local c = readone()

		if c == "\r" or c == "\n" then
			platform.write("\n")
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
			-- ctrl-u: kill the whole line, clm's input_kill(0,
			-- input_len) equivalent, minus the kill-buffer/yank
			-- side (nothing here asked for ctrl-y).
			erase(#buf)
			buf = {}
		elseif #c == 1 and c >= " " then
			buf[#buf + 1] = c
			platform.write(c)
		end
	end
end

while true do
	local m = thread.recv(sys.SELF)

	if m.op == "write" or m.op == "log" then
		-- log lines arrive already stamped and tagged (lib/log.lua);
		-- cons is the console, not the formatter.
		platform.write(m.data)
	elseif m.op == "readline" then
		sys.send(m.reply.__right, readline())
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
		local line = readline()

		sys.send(m.reply.__right, line and (line .. "\n") or nil)
	end
end
