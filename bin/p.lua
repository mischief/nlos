-- p: print a file a screenful at a time.
--
--   > p /lib/dos.lua
--   > p -10 /lib/dos.lua
--   > ls /bin | p
--
-- After each page: any key for the next one, q to stop.
--
-- Plan 9's p, which is the right pager for this machine: it holds no
-- file in memory, it does not address the screen, and it needs no
-- terminal database. It cannot scroll backwards, and that is the whole
-- reason it fits -- a console that cannot be read back (see
-- lib/fbcons.lua) could not repaint an earlier page anyway.
--
-- The page is the terminal's height rather than plan 9's fixed 22,
-- because this machine has two consoles of different sizes and can now
-- ask which it is talking to. A serial line answers nothing and gets
-- the fixed default.
--
-- Not carried over: `!cmd`, which forks rc in the original. Running a
-- command needs a shell, and the shell is what ran p.
--
-- The text and the reader are deliberately two different places. The
-- text is stdin, which may be a pipe; the answers come from the
-- terminal, which is a capability the shell lent us. Reading both from
-- stdin works only until someone pipes something in, and then the pager
-- eats the file it is meant to be showing.

local prog = require("prog")

local DEF = 22		-- plan 9's default, for a terminal that will not say

local TABSTOP = 8	-- what lib/fbcons.lua advances a tab to

local tty = prog.tty and prog.tty()
local cols, rows

-- not `local cols, rows = tty and tty.size()`: `and` yields one value,
-- so the second return is dropped and the height silently becomes the
-- default -- which reads as a pager that scrolls one line too far.
if tty then
	cols, rows = tty.size()
end

-- one line short of the screen: the prompt sits on the last one, and a
-- full screen of text plus a prompt scrolls the first line away.
local pglen = rows and (rows - 1) or DEF
local files = {}

for _, a in ipairs(arg) do
	if a:sub(1, 1) == "-" then
		pglen = tonumber(a:sub(2)) or pglen
		if pglen <= 0 then
			pglen = DEF
		end
	else
		files[#files + 1] = a
	end
end

-- Whether to stop. No terminal means nothing can answer, so the file is
-- printed whole -- which is what happens when p is in a pipeline rather
-- than in front of someone.
local function more()
	if not tty then
		return true
	end
	tty.write(":")

	-- one keystroke rather than a line: there are two answers and
	-- neither needs editing, and a tty capability has getch and no
	-- readline. The prompt is rubbed out again so the page above it
	-- reads as continuous text.
	local c = tty.getch()

	tty.write("\8 \8")
	return not (c == "q" or c == "Q")
end

-- How many rows a line takes once the console has drawn it.
--
-- A page is a screenful, not a count of newlines. The console wraps at
-- the right margin and expands a tab, so a long or deeply indented line
-- is two or three rows -- and counting file lines instead of screen
-- rows is what makes a pager scroll its own first line away before it
-- stops. Source is exactly the bad case: long lines, and tabs for
-- indentation.
--
-- Without a width there is no wrapping to predict, and every line is
-- one row.
local function height(s)
	if not cols or cols <= 0 then
		return 1
	end

	local w = 0

	for i = 1, #s do
		if s:sub(i, i) == "\t" then
			w = w - w % TABSTOP + TABSTOP
		else
			w = w + 1
		end
	end
	if w == 0 then
		return 1
	end
	-- a line filling the width exactly does not wrap: the console
	-- moves to the next row when it draws the character after the
	-- last column, not when it reaches it.
	return (w + cols - 1) // cols
end

local function page(f)
	-- f:lines() holds one line rather than the file, and reads through
	-- nsio's buffer: the machine this runs on has less memory than the
	-- files it will be asked to page.
	local nextline = f:lines()
	local held = nil		-- read but not yet printed

	while true do
		local n = 0

		while true do
			local l = held or nextline()

			held = nil
			if l == nil then
				return true	-- end of file, keep going
			end

			local h = height(l)

			-- a line taller than the page still has to go out,
			-- or nothing would ever print
			if n > 0 and n + h > pglen then
				held = l
				break
			end
			io.write(l .. "\n")
			n = n + h
			if n >= pglen then
				break
			end
		end
		if not more() then
			return false
		end
	end
end

if #files == 0 then
	page(io.stdin)
else
	for _, path in ipairs(files) do
		local f, err = io.open(path, "r")

		if not f then
			io.stderr:write("p: " .. path .. ": " .. tostring(err) ..
			    "\n")
			os.exit(1)
		end

		local go = page(f)

		f:close()
		if not go then
			break
		end
	end
end
