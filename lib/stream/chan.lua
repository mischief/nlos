-- chan stream: over an ns Chan, which is what NS:open answers.
--
-- Offsets and a position, no eof signal and no backpressure: a file is
-- neither a queue nor a party to a hangup.

local M = {}

local Chan = {}

Chan.__index = Chan

function M.new(f)
	return setmetatable({ f = f }, Chan)
end

function Chan:write(data)
	local n = self.f:write(data)

	return n or 0
end

function Chan:read(n)
	return self.f:read(n or 8192) or ""
end

function Chan:close()
	self.f:close()
end

return M
