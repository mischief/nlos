-- nsio: lua's io, over the proc's namespace.
--
-- io.open used to reach the ESP directly and nothing else, which meant a
-- proc handed a restricted namespace could still read the whole disk,
-- and a proc handed a RICHER one -- a mount served by another proc over
-- a port -- could not reach it at all. the namespace was advisory. this
-- makes it the answer.
--
-- ---- what this is not ----
--
-- not a compatibility layer. `io` is lua's own stdlib, so implementing
-- it over our filesystem is an implementation, not a shim -- the
-- difference AGENTS.md's non-goal is drawing.
--
-- ---- stdio is a different thing and stays where it is ----
--
-- io.write, io.read, print, io.stdout and io.stderr are a DEVICE, not
-- files, and nine modules use them. they keep pointing at the C console
-- exactly as before. plan 9's answer is that the console is /dev/cons in
-- the namespace and there is no distinction to make; we have no cons
-- backend yet, so the honest position is that this module replaces the
-- file half and leaves the device half alone. that is a seam, and it is
-- named rather than hidden.
--
-- ---- the file object ----
--
-- a Chan (src/chan.c) already has read/write/seek/close at a position.
-- what it does not have is lua's read FORMATS -- "a", "l", a count --
-- because a Chan is the plan 9 object and formats are a lua convenience.
-- so this wraps rather than extends: the layering stays honest and
-- chan.lua does not grow a second personality.

local ns = require("ns")

local M = {}

-- ---- the file object ----
--
-- Over anything with read(n) and write(s): a Chan for a named file, and
-- a prog stream for stdin/stdout/stderr. Only seek needs the difference,
-- and a source without one answers the error lua answers.
local File = {}

-- what one fill asks for. Reading a line used to take the source a byte
-- at a time, which over a mount is a round trip each -- 1.3ms on the
-- board, so an eighty-column line cost a tenth of a second.
local BUFSZ = 4096

File.__index = File
File.__close = function(f)
	f:close()
end
File.__tostring = function(f)
	if not f.src then
		return "file (closed)"
	end
	return "file (" .. tostring(f.path or "stream") .. ")"
end

-- more bytes into the buffer, or false at end of file. A source may
-- answer short -- a stream returns one message -- which is not eof.
local function fill(f)
	if f.eof then
		return false
	end

	local s, err = f.src:read(BUFSZ)

	if not s then
		f.err = err
		return false
	end
	if s == "" then
		f.eof = true
		return false
	end
	if f.rpos > 1 then
		f.rbuf = f.rbuf:sub(f.rpos)
		f.rpos = 1
	end
	f.rbuf = f.rbuf .. s
	return true
end

local function buffered(f)
	return #f.rbuf - f.rpos + 1
end

-- n bytes, or as many as there are. Short only at end of file.
local function take(f, n)
	while buffered(f) < n do
		if not fill(f) then
			break
		end
	end

	local have = buffered(f)

	if have == 0 then
		return ""
	end
	if n > have then
		n = have
	end

	local s = f.rbuf:sub(f.rpos, f.rpos + n - 1)

	f.rpos = f.rpos + n
	if f.rpos > #f.rbuf then
		f.rbuf, f.rpos = "", 1
	end
	return s
end

-- up to and including the next newline, or everything left at eof.
local function takeline(f)
	while true do
		local at = f.rbuf:find("\n", f.rpos, true)

		if at then
			local s = f.rbuf:sub(f.rpos, at)

			f.rpos = at + 1
			if f.rpos > #f.rbuf then
				f.rbuf, f.rpos = "", 1
			end
			return s
		end
		if not fill(f) then
			local s = f.rbuf:sub(f.rpos)

			f.rbuf, f.rpos = "", 1
			return s
		end
	end
end

-- lua's numeral, which is what tonumber accepts: leading space is
-- skipped and the longest prefix that converts is consumed.
local function takenumber(f)
	while buffered(f) > 0 or fill(f) do
		local c = f.rbuf:sub(f.rpos, f.rpos)

		if not c:match("%s") then
			break
		end
		f.rpos = f.rpos + 1
	end

	local n = 0

	while true do
		if buffered(f) <= n and not fill(f) then
			break
		end
		if buffered(f) <= n then
			break
		end

		local c = f.rbuf:sub(f.rpos + n, f.rpos + n)

		if not c:match("[%w%.%+%-]") then
			break
		end
		n = n + 1
	end

	local s = f.rbuf:sub(f.rpos, f.rpos + n - 1)

	-- the longest prefix that is a number, so "1.5x" reads 1.5 and
	-- leaves x, as lua does
	while #s > 0 and not tonumber(s) do
		s = s:sub(1, #s - 1)
	end
	f.rpos = f.rpos + #s
	return tonumber(s)
end

local function readone(f, fmt)
	if type(fmt) == "number" then
		if fmt == 0 then
			-- lua's eof probe: "" while there is more
			if buffered(f) > 0 or fill(f) then
				return ""
			end
			return nil
		end

		local s = take(f, fmt)

		return s ~= "" and s or nil
	end

	fmt = tostring(fmt):gsub("^%*", "")

	if fmt == "a" then
		local parts = {}

		while true do
			local s = take(f, BUFSZ)

			if s == "" then
				break
			end
			parts[#parts + 1] = s
		end
		return table.concat(parts)	-- "" at eof, as lua does
	end
	if fmt == "l" or fmt == "L" then
		local s = takeline(f)

		if s == "" then
			return nil
		end
		if fmt == "l" and s:sub(-1) == "\n" then
			s = s:sub(1, #s - 1)
		end
		return s
	end
	if fmt == "n" then
		return takenumber(f)
	end
	error("bad argument to 'read' (invalid format)", 3)
end

-- read(...) -- one value per format, stopping at the first that fails.
function File:read(...)
	if not self.src then
		return nil, "file is closed"
	end
	if select("#", ...) == 0 then
		return readone(self, "l")
	end

	local out = {}
	local n = 0

	for i = 1, select("#", ...) do
		local v = readone(self, (select(i, ...)))

		n = i
		out[i] = v
		if v == nil then
			break
		end
	end
	return table.unpack(out, 1, n)
end

function File:write(...)
	if not self.src then
		return nil, "file is closed"
	end
	for i = 1, select("#", ...) do
		local v = select(i, ...)

		if type(v) ~= "string" and type(v) ~= "number" then
			error("bad argument to 'write'", 2)
		end

		local ok, err = self.src:write(tostring(v))

		if not ok then
			return nil, err
		end
	end
	return self
end

function File:lines(...)
	local fmts = table.pack(...)

	return function()
		if fmts.n == 0 then
			return self:read("l")
		end
		return self:read(table.unpack(fmts, 1, fmts.n))
	end
end

-- seek is the one thing a stream cannot do. The read buffer is dropped
-- and its unread bytes are taken off "cur", so a position is the one
-- the caller would have had unbuffered.
function File:seek(whence, off)
	if not self.src then
		return nil, "file is closed"
	end
	if not self.src.seek then
		return nil, "cannot seek this file"
	end
	whence = whence or "cur"
	off = off or 0

	if whence == "cur" then
		off = off - buffered(self)
	end
	self.rbuf, self.rpos, self.eof = "", 1, false
	return self.src:seek(whence, off)
end

-- Writes go straight through, so there is nothing held to push. Kept
-- because callers write it after a write and expect true.
function File:flush()
	if not self.src then
		return nil, "file is closed"
	end
	return self
end

-- the buffering is ours to choose, which is what lua says setvbuf is
-- allowed to answer.
function File:setvbuf(mode, size)
	return true
end

function File:close()
	if self.src then
		if self.src.close then
			self.src:close()
		end
		self.src = nil
		self.rbuf, self.rpos = "", 1
	end
	return true
end

-- over a Chan, which is what a named file is.
local function wrap(c)
	return setmetatable({
		src = c, path = c.path, rbuf = "", rpos = 1,
	}, File)
end

-- over a Chan somebody else opened.
function M.file(c)
	return wrap(c)
end

-- over anything else with read/write: prog's stdin, stdout and stderr.
function M.stream(s, name)
	return setmetatable({
		src = s, path = name, rbuf = "", rpos = 1,
	}, File)
end

-- lua's io.type: a handle answers what it is, anything else nothing.
function M.type(f)
	if getmetatable(f) ~= File then
		return nil
	end
	return f.src and "file" or "closed file"
end
-- open(path, mode) -> file | nil, err
--
-- "w" creates, matching lua and matching dev.create's create-and-open.
-- the namespace decides what that reaches: the ESP, a synthetic tree, or
-- a file server in another proc, all through the same call.
-- open(path, mode, N) -- N is the namespace to resolve in, defaulting
-- to this proc's. A program passes its own, which is rooted at its cwd
-- and is the only one a confined proc may reach.
function M.open(path, mode, N)
	mode = mode or "r"

	N = N or ns.current()

	if not N then
		return nil, "no namespace"
	end

	local m = mode:gsub("b", "")

	if m == "w" or m == "a" then
		local c, err = N:create(path, "rw")

		if not c then
			return nil, err
		end
		if m == "a" then
			local st = c:stat()

			c.pos = st and st.size or 0
		end
		return wrap(c)
	end

	local c, err = N:open(path, m == "r+" and "rw" or "r")

	if not c then
		return nil, err
	end
	return wrap(c)
end

function M.lines(path, fmt, N)
	local f, err = M.open(path, "r", N)

	if not f then
		error(err, 2)
	end
	return function()
		local l = f:read(fmt or "l")

		if l == nil then
			f:close()
		end
		return l
	end
end

function M.close(f)
	if f then
		return f:close()
	end
end

-- install(): replace the FILE half of the global io table in this proc.
--
-- write/read/stdout/stderr/input/output are left exactly as they were --
-- see the note at the top on why the console is not a file here yet.
function M.install()
	if io.__nsio then
		return io
	end
	io.open = M.open
	io.lines = M.lines
	io.close = M.close
	io.__nsio = true
	return io
end

return M
