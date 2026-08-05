-- vi - a visual editor, ported from the host lua/os tree's ed/vi.lua.
--
-- The editor logic is unchanged; what the lua-os port swaps out is the
-- two things that touched the host. The terminal is the console the
-- launcher lent us (prog.tty, via ed.terminfo) rather than posix.termio
-- on fd 0/1, and files go through the program's namespace (ed.buffer over
-- prog.ns) rather than io.open. So the same editor runs over a serial
-- console, an ssh session or any other terminal that answers the tty
-- protocol -- the way vi on unix runs over a pty.
--
-- The screen is drawn by absolute cursor positioning and never a newline:
-- the firmware console cooks \n into \r\n (src/platform/efi/console.c),
-- which would double every line break, and placing the cursor per row
-- sidesteps that and every other newline-translation a terminal might do.
--
-- No thread.run() of its own: getch is a plain request/reply the console
-- answers, so this runs the same whether it was spawned as a proc (the
-- serial console) or is a coroutine in a shell (an ssh/webterm session).

local prog = require("prog")
local buffer = require("ed.buffer")
local term = require("ed.terminfo").new()

-- a full-screen editor needs a terminal. piped, or handed to a shell with
-- no console, there is none -- say so and stop rather than draw nowhere.
if not term:ok() then
	io.stderr:write("vi: not a terminal\n")
	os.exit(1)
end

-- the first non-option argument is the file; -R and the rest are accepted
-- and ignored, so an old invocation still opens its file.
local file = nil
for i = 1, #arg do
	if arg[i]:sub(1, 1) ~= "-" then
		file = arg[i]
		break
	end
end

-- ex_mode for the full command set behind `:`; suppress so the engine's
-- ed-style errors go to the status line (buf.exmsg) rather than a stream.
local buf = buffer.new({ file = file, suppress = true, ex_mode = true })
if file then buf:load(file) end
if #buf.lines == 0 then buf.lines = { "" }; buf.cur = 1 end

-- Editor state
local top = 1 -- first visible line
local cx, cy = 1, 1 -- cursor col, row (1-indexed, relative to buffer line)
local mode = "normal" -- normal, insert, command
local cmd_buf = "" -- for : commands
local status_msg = ""
local insert_col = 1

-- Helpers
local function clamp()
	if buf.cur < 1 then buf.cur = 1 end
	if buf.cur > #buf.lines then buf.cur = #buf.lines end
	-- Keep cursor in view
	if buf.cur < top then top = buf.cur end
	if buf.cur >= top + term.rows - 1 then top = buf.cur - term.rows + 2 end
	cy = buf.cur - top + 1
	-- Clamp cx
	local line = buf.lines[buf.cur] or ""
	if cx > #line then cx = math.max(1, #line) end
	if cx < 1 then cx = 1 end
end

local function set_status(msg)
	status_msg = msg
end

-- Redraw. Absolute positioning per row, no newlines -- see the note at the
-- top on why: a printed \n is cooked to \r\n on the firmware console.
local function draw()
	term:hide_cursor()
	for i = 1, term.rows - 1 do
		term:move(i, 1)
		term:clear_eol()
		local ln = top + i - 1
		if ln <= #buf.lines then
			local line = buf.lines[ln]
			if #line > term.cols then line = line:sub(1, term.cols) end
			term:write(line)
		else
			term:write("~")
		end
	end
	-- Status line, on the last row
	term:move(term.rows, 1)
	term:clear_eol()
	if mode == "command" then
		term:write((":" .. cmd_buf):sub(1, term.cols))
	elseif status_msg ~= "" then
		-- an ex message may carry newlines; a status line is one row.
		term:write((status_msg:gsub("[\r\n]", " ")):sub(1, term.cols))
		status_msg = ""
	else
		local fn = buf.file or "[No Name]"
		local mod = buf.dirty and " [+]" or ""
		local pos = string.format("%d/%d", buf.cur, #buf.lines)
		term:write((fn .. mod .. "  " .. pos):sub(1, term.cols))
	end
	term:move(cy, cx)
	term:show_cursor()
end

-- Normal mode key handling
local function normal_key(key)
	local line = buf.lines[buf.cur] or ""

	-- Movement
	if key == "h" or key == "left" then
		if cx > 1 then cx = cx - 1 end
	elseif key == "l" or key == "right" then
		if cx < #line then cx = cx + 1 end
	elseif key == "j" or key == "down" then
		if buf.cur < #buf.lines then buf.cur = buf.cur + 1; clamp() end
	elseif key == "k" or key == "up" then
		if buf.cur > 1 then buf.cur = buf.cur - 1; clamp() end
	elseif key == "0" or key == "home" then
		cx = 1
	elseif key == "$" or key == "end" then
		cx = math.max(1, #line)
	elseif key == "^" then
		cx = (line:find("%S") or 1)
	elseif key == "w" then
		-- Next word
		local pos = line:find("%s", cx)
		if pos then
			pos = line:find("%S", pos)
			if pos then cx = pos else cx = #line end
		else
			cx = #line
		end
	elseif key == "b" then
		-- Previous word
		if cx > 1 then
			local sub = line:sub(1, cx - 1)
			local pos = sub:find("%S[%s]*$")
			if pos then cx = pos else cx = 1 end
		end
	elseif key == "G" then
		buf.cur = #buf.lines; clamp()
	elseif key == "g" then
		-- gg = go to top (simplified: single g goes to top)
		buf.cur = 1; clamp()
	elseif key == "pagedown" or key == "\006" then -- Ctrl-F
		buf.cur = math.min(#buf.lines, buf.cur + term.rows - 2)
		top = math.min(#buf.lines, top + term.rows - 2)
		clamp()
	elseif key == "pageup" or key == "\002" then -- Ctrl-B
		buf.cur = math.max(1, buf.cur - term.rows + 2)
		top = math.max(1, top - term.rows + 2)
		clamp()

	-- Editing
	elseif key == "i" then
		mode = "insert"; insert_col = cx
	elseif key == "a" then
		cx = math.min(#line + 1, cx + 1)
		mode = "insert"; insert_col = cx
	elseif key == "A" then
		cx = #line + 1
		mode = "insert"; insert_col = cx
	elseif key == "I" then
		cx = (line:find("%S") or 1)
		mode = "insert"; insert_col = cx
	elseif key == "o" then
		table.insert(buf.lines, buf.cur + 1, "")
		buf.cur = buf.cur + 1; cx = 1; buf.dirty = true
		clamp(); mode = "insert"; insert_col = 1
	elseif key == "O" then
		table.insert(buf.lines, buf.cur, "")
		cx = 1; buf.dirty = true
		clamp(); mode = "insert"; insert_col = 1
	elseif key == "x" then
		if #line > 0 then
			buf.lines[buf.cur] = line:sub(1, cx - 1) .. line:sub(cx + 1)
			buf.dirty = true
			if cx > #buf.lines[buf.cur] and cx > 1 then cx = cx - 1 end
		end
	elseif key == "dd" or key == "D" then
		-- dd handled via pending, D deletes to end
		if key == "D" then
			buf.lines[buf.cur] = line:sub(1, cx - 1)
			buf.dirty = true
		end
	elseif key == "d" then
		-- Wait for second key (simplified: only dd)
		local k2 = term:readkey()
		if k2 == "d" then
			buf:delete(buf.cur, buf.cur)
			if #buf.lines == 0 then buf.lines = { "" }; buf.cur = 1 end
			clamp()
		end
	elseif key == "J" then
		if buf.cur < #buf.lines then
			buf.lines[buf.cur] = buf.lines[buf.cur] .. " " .. buf.lines[buf.cur + 1]
			table.remove(buf.lines, buf.cur + 1)
			buf.dirty = true
		end
	elseif key == "u" then
		set_status("undo not implemented")
	elseif key == "r" then
		local ch = term:readkey()
		if ch and #ch == 1 then
			buf.lines[buf.cur] = line:sub(1, cx - 1) .. ch .. line:sub(cx + 1)
			buf.dirty = true
		end

	-- Search
	elseif key == "/" then
		mode = "command"; cmd_buf = "/"
	elseif key == "?" then
		mode = "command"; cmd_buf = "?"
	elseif key == "n" then
		set_status("search repeat not implemented")

	-- Command mode
	elseif key == ":" then
		mode = "command"; cmd_buf = ""
	elseif key == "Z" then
		local k2 = term:readkey()
		if k2 == "Z" then
			if buf.file then buf:write() end
			return false
		elseif k2 == "Q" then
			return false
		end
	end
	return true
end

-- Insert mode key handling
local function insert_key(key)
	local line = buf.lines[buf.cur] or ""

	-- Ctrl-C leaves insert mode like Escape. On the efi serial console the
	-- firmware defers a bare Esc while it waits to see whether it begins an
	-- arrow-key sequence, so Esc there is slow; Ctrl-C is a single control
	-- byte delivered at once, and it is what vim falls back to for the same
	-- reason. Esc still works everywhere (instantly over ssh).
	if key == "escape" or key == "\3" then
		mode = "normal"
		if cx > 1 then cx = cx - 1 end
		return true
	elseif key == "\127" or key == "\008" then -- backspace
		if cx > 1 then
			buf.lines[buf.cur] = line:sub(1, cx - 2) .. line:sub(cx)
			cx = cx - 1; buf.dirty = true
		elseif buf.cur > 1 then
			-- Join with previous line
			cx = #buf.lines[buf.cur - 1] + 1
			buf.lines[buf.cur - 1] = buf.lines[buf.cur - 1] .. line
			table.remove(buf.lines, buf.cur)
			buf.cur = buf.cur - 1; buf.dirty = true
			clamp()
		end
	elseif key == "\r" or key == "\n" then
		-- Split line
		local before = line:sub(1, cx - 1)
		local after = line:sub(cx)
		buf.lines[buf.cur] = before
		table.insert(buf.lines, buf.cur + 1, after)
		buf.cur = buf.cur + 1; cx = 1; buf.dirty = true
		clamp()
	elseif key == "left" then
		if cx > 1 then cx = cx - 1 end
	elseif key == "right" then
		if cx <= #line then cx = cx + 1 end
	elseif key == "up" then
		if buf.cur > 1 then buf.cur = buf.cur - 1; clamp() end
	elseif key == "down" then
		if buf.cur < #buf.lines then buf.cur = buf.cur + 1; clamp() end
	elseif #key == 1 and key:byte() >= 32 then
		buf.lines[buf.cur] = line:sub(1, cx - 1) .. key .. line:sub(cx)
		cx = cx + 1; buf.dirty = true
	end
	return true
end

-- run an ex command through the buffer engine, showing whatever it printed
-- (buf.exmsg) on the status line -- see ed.buffer's M:out.
local function run_ex(cmd)
	buf.exmsg = nil
	local result = buf:exec(cmd)
	if buf.exmsg and buf.exmsg ~= "" then
		set_status((buf.exmsg:gsub("%s+$", "")))
	end
	return result
end

-- Command mode key handling
local function command_key(key)
	-- Ctrl-C cancels the line like Escape -- instant where the efi console
	-- defers a bare Esc (see insert_key).
	if key == "escape" or key == "\3" then
		mode = "normal"; cmd_buf = ""
	elseif key == "\r" or key == "\n" then
		mode = "normal"
		local cmd = cmd_buf
		cmd_buf = ""
		-- Handle ex commands
		if cmd == "q" or cmd == "q!" then
			if cmd == "q" and buf.dirty then
				set_status("No write since last change (use :q! to override)")
				return true
			end
			return false
		elseif cmd == "w" then
			local ok, result = buf:write()
			if ok then set_status('"' .. buf.file .. '" written, ' .. result .. " bytes")
			else set_status(result) end
		elseif cmd == "wq" or cmd == "x" then
			-- a write that failed must not quit and lose the buffer:
			-- report it and stay, as vi does.
			local ok, result = buf:write()
			if not ok then set_status(result); return true end
			return false
		elseif cmd:sub(1, 2) == "w " then
			local fn = cmd:sub(3)
			local ok, result = buf:write(fn)
			if ok then set_status('"' .. fn .. '" written, ' .. result .. " bytes")
			else set_status(result) end
		elseif cmd:sub(1, 1) == "/" then
			-- Forward search
			local pat = cmd:sub(2)
			if pat ~= "" then
				for i = buf.cur + 1, #buf.lines do
					if buf.lines[i]:find(pat) then
						buf.cur = i; clamp()
						local pos = buf.lines[i]:find(pat)
						if pos then cx = pos end
						return true
					end
				end
				for i = 1, buf.cur do
					if buf.lines[i]:find(pat) then
						buf.cur = i; clamp()
						local pos = buf.lines[i]:find(pat)
						if pos then cx = pos end
						return true
					end
				end
				set_status("Pattern not found: " .. pat)
			end
		elseif cmd:sub(1, 1) == "?" then
			-- Backward search
			local pat = cmd:sub(2)
			if pat ~= "" then
				for i = buf.cur - 1, 1, -1 do
					if buf.lines[i]:find(pat) then
						buf.cur = i; clamp()
						local pos = buf.lines[i]:find(pat)
						if pos then cx = pos end
						return true
					end
				end
				set_status("Pattern not found: " .. pat)
			end
		elseif tonumber(cmd) then
			buf.cur = tonumber(cmd); clamp()
		else
			-- Try as ex command
			local result = run_ex(cmd)
			if result == nil then return false end
			clamp()
		end
	elseif key == "\127" or key == "\008" then
		cmd_buf = cmd_buf:sub(1, -2)
	elseif #key == 1 and key:byte() >= 32 then
		cmd_buf = cmd_buf .. key
	end
	return true
end

-- Main
term:raw()
term:detect_size()
buf.cur = 1
clamp()

local ok, err = pcall(function()
	while true do
		draw()
		local key = term:readkey()
		if not key then break end

		local cont
		if mode == "normal" then
			cont = normal_key(key)
		elseif mode == "insert" then
			cont = insert_key(key)
		elseif mode == "command" then
			cont = command_key(key)
		end
		if cont == false then break end
	end
end)

term:clear()
term:restore()
if not ok then
	io.stderr:write("vi: " .. tostring(err) .. "\n")
	os.exit(1)
end
