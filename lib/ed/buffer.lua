-- ed/buffer.lua - line buffer and command engine for ed/ex/vi.
--
-- The lua-os port of the posix ed buffer. The command engine (parse_addr,
-- parse_range, substitute, exec, the full ex command set) is unchanged --
-- it is pure string and table work. What differs is the two edges that
-- touched the host: files go through the program's namespace (prog.ns)
-- rather than io.open, and the ed-style output an ex command prints goes
-- into self.exmsg for the caller to show, rather than to io.write, since
-- a full-screen editor has no scrolling stdout to print a line to.
local prog = require("prog")

local M = {}

-- resolve a filename against the program's cwd, so `vi foo` in /n/gefs
-- edits /n/gefs/foo, not /foo. The namespace has no notion of a working
-- directory -- a bare name is rooted at / -- so the cwd the launcher put
-- in the ABI message (prog.ctx.cwd) has to be applied here, exactly as
-- the posix sliver in lib/prog.lua does for a ported utility.
local function resolve(path)
	local ctx = prog.ctx

	if not ctx then
		return path
	end
	return prog.abspath(ctx, path)
end

function M.new(opts)
	local self = {
		lines = {},
		cur = 0, -- current line (0 = empty buffer)
		dirty = false,
		file = opts and opts.file or nil,
		suppress = opts and opts.suppress or false,
		prompt = opts and opts.prompt or "",
		last_error = nil,
		exmsg = nil, -- what an ex command last printed; see M:out
		marks = {}, -- mark name -> line number
		-- ex extensions
		ex_mode = opts and opts.ex_mode or false,
	}
	return setmetatable(self, { __index = M })
end

-- where an ex command's output goes. On unix ed this was io.write to a
-- scrolling terminal; a full-screen editor has none, so collect it and
-- let vi show it on the status line. Reset by the caller before each
-- command it runs.
function M:out(...)
	local parts = {}

	for _, v in ipairs({ ... }) do
		parts[#parts + 1] = tostring(v)
	end
	self.exmsg = (self.exmsg or "") .. table.concat(parts)
end

-- split a whole-file string into lines, dropping the single trailing
-- empty a final newline would otherwise add -- so "a\nb\n" is two lines,
-- as every tool means it to be.
local function splitlines(data)
	local lines = {}
	local body = data

	if #body > 0 and body:sub(-1) ~= "\n" then
		body = body .. "\n"
	end
	for line in body:gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end
	return lines
end

-- Load file into buffer
function M:load(filename)
	self.file = filename or self.file
	if not self.file then
		return false, "no filename"
	end
	self.file = resolve(self.file)
	local N = prog.ns()

	if not N then
		return false, "no namespace"
	end
	local data, err = N:readfile(self.file)

	if not data then
		self.lines = {}
		self.cur = 0
		return false, self.file .. ": " .. tostring(err)
	end
	self.lines = splitlines(data)
	self.cur = #self.lines
	self.dirty = false
	return true, #self.lines
end

-- Write buffer to file
function M:write(filename, addr1, addr2)
	local fn = filename or self.file

	if not fn then
		return false, "no filename"
	end
	fn = resolve(fn)
	self.file = fn
	local N = prog.ns()

	if not N then
		return false, "no namespace"
	end
	local start = addr1 or 1
	local stop = addr2 or #self.lines
	local parts = {}

	for i = start, stop do
		parts[#parts + 1] = self.lines[i]
	end
	local data = #parts > 0 and (table.concat(parts, "\n") .. "\n") or ""
	local ok, err = N:writefile(fn, data)

	if not ok then
		return false, fn .. ": " .. tostring(err)
	end
	self.dirty = false
	return true, #data
end

-- Parse an address from string at position pos
-- Returns line number, new position
function M:parse_addr(s, pos)
	pos = pos or 1
	local n = #self.lines
	local addr = nil

	-- Skip whitespace
	while pos <= #s and s:sub(pos, pos) == " " do pos = pos + 1 end
	if pos > #s then return nil, pos end

	local c = s:sub(pos, pos)
	if c == "." then
		addr = self.cur; pos = pos + 1
	elseif c == "$" then
		addr = n; pos = pos + 1
	elseif c:match("%d") then
		local num = s:match("^(%d+)", pos)
		addr = tonumber(num); pos = pos + #num
	elseif c == "'" and pos + 1 <= #s then
		local mark = s:sub(pos + 1, pos + 1)
		addr = self.marks[mark] or self.cur
		pos = pos + 2
	elseif c == "/" then
		local pat = s:match("^/([^/]*)/", pos)
		if pat then
			pos = pos + #pat + 2
		else
			pat = s:match("^/(.*)", pos)
			pos = #s + 1
		end
		if pat and pat ~= "" then
			for i = 1, n do
				local line = ((self.cur + i - 1) % n) + 1
				if self.lines[line]:find(pat) then addr = line; break end
			end
		end
		if not addr then return nil, pos end
	elseif c == "?" then
		local pat = s:match("^%?([^?]*)%?", pos)
		if pat then
			pos = pos + #pat + 2
		else
			pat = s:match("^%?(.*)", pos)
			pos = #s + 1
		end
		if pat and pat ~= "" then
			for i = 1, n do
				local line = ((self.cur - i - 1) % n) + 1
				if self.lines[line]:find(pat) then addr = line; break end
			end
		end
		if not addr then return nil, pos end
	else
		return nil, pos
	end

	-- Handle +/- offsets
	while pos <= #s do
		local ch = s:sub(pos, pos)
		if ch == "+" then
			pos = pos + 1
			local num = s:match("^(%d+)", pos)
			if num then
				addr = (addr or self.cur) + tonumber(num)
				pos = pos + #num
			else
				addr = (addr or self.cur) + 1
			end
		elseif ch == "-" then
			pos = pos + 1
			local num = s:match("^(%d+)", pos)
			if num then
				addr = (addr or self.cur) - tonumber(num)
				pos = pos + #num
			else
				addr = (addr or self.cur) - 1
			end
		else
			break
		end
	end

	return addr, pos
end

-- Parse address range: returns addr1, addr2, rest of command
function M:parse_range(s)
	local pos = 1
	local addr1, addr2

	-- Special: % or , means 1,$
	if s:sub(1, 1) == "%" or s:sub(1, 1) == "," then
		if s:sub(1, 1) == "," and not s:sub(2, 2):match("[;,]") then
			-- Could be ,addr2
			addr1 = 1
			pos = 2
			addr2, pos = self:parse_addr(s, pos)
			if not addr2 then addr2 = #self.lines end
			return addr1, addr2, s:sub(pos)
		end
		return 1, #self.lines, s:sub(2)
	end

	addr1, pos = self:parse_addr(s, pos)

	if pos <= #s and (s:sub(pos, pos) == "," or s:sub(pos, pos) == ";") then
		local sep = s:sub(pos, pos)
		pos = pos + 1
		if sep == ";" then self.cur = addr1 or self.cur end
		addr2, pos = self:parse_addr(s, pos)
		if not addr1 then addr1 = 1 end
		if not addr2 then addr2 = #self.lines end
	elseif addr1 then
		addr2 = addr1
	end

	return addr1, addr2, s:sub(pos)
end

-- Error reporting
function M:error(msg)
	self.last_error = msg
	if not self.suppress then
		self:out("?\n")
	end
	return false
end

-- Read input lines until "." on its own line. A full-screen editor has no
-- line-input channel here, so the a/i/c ex commands insert nothing rather
-- than block; an interactive ex front-end would override this.
function M:read_input()
	return {}
end

-- Insert lines after position
function M:insert_after(pos, new_lines)
	for i = #new_lines, 1, -1 do
		table.insert(self.lines, pos + 1, new_lines[i])
	end
	self.cur = pos + #new_lines
	self.dirty = true
end

-- Delete lines
function M:delete(addr1, addr2)
	if addr1 < 1 or addr2 > #self.lines or addr1 > addr2 then
		return self:error("invalid address")
	end
	for _ = addr1, addr2 do
		table.remove(self.lines, addr1)
	end
	self.cur = math.min(addr1, #self.lines)
	if self.cur == 0 and #self.lines > 0 then self.cur = 1 end
	self.dirty = true
	return true
end

-- Substitute
function M:substitute(addr1, addr2, rest)
	-- Parse s/pat/repl/flags
	local delim = rest:sub(1, 1)
	if not delim or delim == "" then return self:error("invalid substitution") end
	local parts = {}
	local escaped = false
	local current = {}
	for j = 2, #rest do
		local ch = rest:sub(j, j)
		if escaped then
			current[#current + 1] = ch
			escaped = false
		elseif ch == "\\" then
			escaped = true
			current[#current + 1] = ch
		elseif ch == delim then
			parts[#parts + 1] = table.concat(current)
			current = {}
		else
			current[#current + 1] = ch
		end
	end
	parts[#parts + 1] = table.concat(current)

	local pat = parts[1] or ""
	local repl = (parts[2] or ""):gsub("\\(%d)", "%%%1"):gsub("\\n", "\n")
	local flags = parts[3] or ""
	local global = flags:find("g") ~= nil
	local print_line = flags:find("p") ~= nil

	if pat == "" then return self:error("no pattern") end

	local count = nil
	if not global then count = 1 end
	local matched = false
	for line = addr1, addr2 do
		local new = self.lines[line]:gsub(pat, repl, count)
		if new ~= self.lines[line] then
			self.lines[line] = new
			self.cur = line
			matched = true
			self.dirty = true
		end
	end
	if not matched then return self:error("no match") end
	if print_line then self:out(self.lines[self.cur] .. "\n") end
	return true
end

-- Execute a command. Returns true to continue, false on quit.
function M:exec(input)
	if input == "" then
		-- Empty: advance and print
		if self.cur < #self.lines then
			self.cur = self.cur + 1
			self:out(self.lines[self.cur] .. "\n")
		else
			return self:error("invalid address")
		end
		return true
	end

	local addr1, addr2, cmd = self:parse_range(input)
	local c = cmd:sub(1, 1)
	local rest = cmd:sub(2)

	-- Default addresses
	if not addr1 then
		if c == "p" or c == "n" or c == "d" or c == "s" or c == "j"
			or c == "l" or c == "c" then
			addr1 = self.cur; addr2 = self.cur
		elseif c == "w" or c == "g" or c == "v" then
			addr1 = 1; addr2 = #self.lines
		elseif c == "a" or c == "i" or c == "r" or c == "=" then
			addr1 = self.cur; addr2 = self.cur
		end
	end

	-- Validate addresses
	if addr1 and (addr1 < 0 or addr1 > #self.lines) then return self:error("invalid address") end
	if addr2 and (addr2 < 0 or addr2 > #self.lines) then return self:error("invalid address") end
	if addr1 and addr2 and addr1 > addr2 then return self:error("invalid address") end

	if c == "q" or c == "Q" then
		if c == "q" and self.dirty then
			self.dirty = false -- warn once
			return self:error("warning: buffer modified")
		end
		return nil -- signal quit
	elseif c == "p" then
		for i = addr1, addr2 do
			self:out(self.lines[i] .. "\n")
		end
		self.cur = addr2
	elseif c == "n" then
		for i = addr1, addr2 do
			self:out(string.format("%d\t%s\n", i, self.lines[i]))
		end
		self.cur = addr2
	elseif c == "l" then
		for i = addr1, addr2 do
			self:out(self.lines[i]:gsub("\\", "\\\\"):gsub("\t", "\\t") .. "$\n")
		end
		self.cur = addr2
	elseif c == "a" then
		local new = self:read_input()
		self:insert_after(addr2, new)
	elseif c == "i" then
		local new = self:read_input()
		self:insert_after(addr1 - 1, new)
	elseif c == "c" then
		local new = self:read_input()
		self:delete(addr1, addr2)
		self:insert_after(addr1 - 1, new)
	elseif c == "d" then
		self:delete(addr1, addr2)
	elseif c == "j" then
		if addr1 == addr2 then addr2 = addr1 + 1 end
		if addr2 > #self.lines then return self:error("invalid address") end
		local joined = table.concat(self.lines, "", addr1, addr2)
		self:delete(addr1, addr2)
		table.insert(self.lines, addr1, joined)
		self.cur = addr1
		self.dirty = true
	elseif c == "s" then
		self:substitute(addr1, addr2, rest)
	elseif c == "m" then
		-- Move: ex extension
		if not self.ex_mode then return self:error("unknown command") end
		local dest = self:parse_addr(rest, 1)
		if not dest then return self:error("invalid address") end
		local block = {}
		for i = addr1, addr2 do block[#block + 1] = self.lines[i] end
		self:delete(addr1, addr2)
		if dest > addr1 then dest = dest - (addr2 - addr1 + 1) end
		self:insert_after(dest, block)
	elseif c == "t" then
		-- Copy: ex extension
		if not self.ex_mode then return self:error("unknown command") end
		local dest = self:parse_addr(rest, 1)
		if not dest then return self:error("invalid address") end
		local block = {}
		for i = addr1, addr2 do block[#block + 1] = self.lines[i] end
		self:insert_after(dest, block)
	elseif c == "w" then
		local fn = rest:match("^%s*(.+)") or self.file
		local ok, bytes = self:write(fn)
		if ok then
			if not self.suppress then self:out(bytes .. "\n") end
		else
			return self:error(bytes)
		end
		-- wq
		if cmd:sub(2, 2) == "q" then return nil end
	elseif c == "r" then
		local fn = rest:match("^%s*(.+)") or self.file
		if not fn then return self:error("no filename") end
		local N = prog.ns()
		local data = N and N:readfile(resolve(fn))
		if not data then return self:error(fn .. ": No such file or directory") end
		local new = splitlines(data)
		self:insert_after(addr2, new)
		if not self.suppress then
			local bytes = 0
			for _, l in ipairs(new) do bytes = bytes + #l + 1 end
			self:out(bytes .. "\n")
		end
	elseif c == "e" then
		local fn = rest:match("^%s*(.+)") or self.file
		self.lines = {}
		self.cur = 0
		self.dirty = false
		local ok, result = self:load(fn)
		if ok then
			if not self.suppress then self:out(result .. "\n") end
		else
			return self:error(result)
		end
	elseif c == "f" then
		local fn = rest:match("^%s*(.+)")
		if fn then self.file = fn end
		if self.file then self:out(self.file .. "\n") end
	elseif c == "=" then
		self:out(#self.lines .. "\n")
	elseif c == "k" then
		local mark = rest:sub(1, 1)
		if not mark or mark == "" then return self:error("invalid mark") end
		self.marks[mark] = addr2
	elseif c == "g" or c == "v" then
		-- Global: g/pat/cmd or v/pat/cmd
		local delim = rest:sub(1, 1)
		local pat, gcmd = rest:match("^.(.-)" .. delim .. "(.*)")
		if not pat then return self:error("invalid global") end
		if gcmd == "" then gcmd = "p" end
		local invert = (c == "v")
		local targets = {}
		for i = addr1, addr2 do
			local match = self.lines[i]:find(pat) ~= nil
			if (match and not invert) or (not match and invert) then
				targets[#targets + 1] = i
			end
		end
		-- Execute command on each target (simple: only single commands)
		for j = #targets, 1, -1 do
			self.cur = targets[j]
			self:exec(tostring(self.cur) .. gcmd)
		end
	elseif c == "!" then
		-- no shell to run a command through here
		return self:error("! not supported")
	elseif c == "H" then
		if self.last_error then self:out(self.last_error .. "\n") end
	elseif c == "h" then
		if self.last_error then self:out(self.last_error .. "\n") end
	elseif c == "" and addr1 then
		-- Bare address: go to line and print
		if addr1 >= 1 and addr1 <= #self.lines then
			self.cur = addr1
			self:out(self.lines[self.cur] .. "\n")
		else
			return self:error("invalid address")
		end
	else
		return self:error("unknown command")
	end

	return true
end

return M
