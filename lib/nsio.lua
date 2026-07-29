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
-- a Chan (lib/chan.lua) already has read/write/seek/close at a position.
-- what it does not have is lua's read FORMATS -- "a", "l", a count --
-- because a Chan is the plan 9 object and formats are a lua convenience.
-- so this wraps rather than extends: the layering stays honest and
-- chan.lua does not grow a second personality.

local ns = require("ns")

local M = {}

local File = {}

File.__index = File
File.__close = function(f)
	f:close()
end
File.__tostring = function(f)
	return "file (" .. (f.chan and f.chan.path or "closed") .. ")"
end

-- read(fmt) with lua's spelling: a count, "a"/"*a" for the rest, or
-- "l"/"*l" for a line. nil at eof for a count or a line, "" for "a",
-- which is what lua does.
function File:read(fmt)
	if not self.chan then
		return nil, "file is closed"
	end
	fmt = fmt or "l"

	if type(fmt) == "number" then
		local s, err = self.chan:read(fmt)

		if not s then
			return nil, err
		end
		return s ~= "" and s or nil
	end

	fmt = tostring(fmt):gsub("^%*", "")

	if fmt == "a" then
		local parts = {}

		while true do
			local s, err = self.chan:read(4096)

			if not s then
				return nil, err
			end
			if s == "" then
				break
			end
			parts[#parts + 1] = s
		end
		return table.concat(parts)
	end
	if fmt == "l" or fmt == "L" then
		local parts = {}

		while true do
			local s, err = self.chan:read(1)

			if not s then
				return nil, err
			end
			if s == "" then
				break
			end
			if s == "\n" then
				if fmt == "L" then
					parts[#parts + 1] = s
				end
				return table.concat(parts)
			end
			parts[#parts + 1] = s
		end
		if #parts == 0 then
			return nil
		end
		return table.concat(parts)
	end
	return nil, "unsupported format '" .. tostring(fmt) .. "'"
end

function File:write(...)
	if not self.chan then
		return nil, "file is closed"
	end
	for _, v in ipairs({ ... }) do
		local n, err = self.chan:write(tostring(v))

		if not n then
			return nil, err
		end
	end
	return self
end

function File:seek(whence, off)
	if not self.chan then
		return nil, "file is closed"
	end
	return self.chan:seek(whence, off)
end

function File:lines(fmt)
	return function()
		return self:read(fmt or "l")
	end
end

function File:close()
	if self.chan then
		self.chan:close()
		self.chan = nil
	end
	return true
end

local function wrap(c)
	return setmetatable({ chan = c }, File)
end

-- open(path, mode) -> file | nil, err
--
-- "w" creates, matching lua and matching dev.create's create-and-open.
-- the namespace decides what that reaches: the ESP, a synthetic tree, or
-- a file server in another proc, all through the same call.
function M.open(path, mode)
	mode = mode or "r"

	local N = ns.current()

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

function M.lines(path, fmt)
	local f, err = M.open(path, "r")

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
