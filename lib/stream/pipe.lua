-- pipe stream: the in-proc pipe, over a channel from thread.chancreate.
--
-- For a launcher running its stages as coroutines in one proc rather
-- than a proc each. Same three methods as a port stream, so a program
-- cannot tell which it was handed.

-- eof is Channel:close(). A port's refcount is its eof and a channel has
-- no equivalent, so the writer says so explicitly: a launcher that
-- forgets to close leaves its reader waiting forever.
--
-- Backpressure is bounded and free: a send on a full buffered channel
-- parks the coroutine until the reader takes one.

local M = {}

local Pipe = {}

Pipe.__index = Pipe

function M.new(c)
	return setmetatable({ c = c }, Pipe)
end

function Pipe:write(data)
	self.c:send(data)
	return #data
end

function Pipe:read(_)
	local v, more = self.c:recv()

	-- "" is eof throughout this ABI, so a program's
	-- `while data ~= ""` loop ends rather than erroring
	if not more then
		return ""
	end
	return v or ""
end

function Pipe:close()
	self.c:close()
end

return M
