-- nodedb: who has been heard, and no more of them than will fit.
--
-- A public mesh has more nodes than a handheld has memory, so this
-- keeps a fixed number and drops the one heard longest ago. The caller
-- says what time it is: no clock here, and no radio.

local M = {}

local DB = {}

DB.__index = DB

function M.new(max)
	return setmetatable({
		max = math.max(math.tointeger(tonumber(max) or 200) or 200, 1),
		n = 0,
		at = {},
	}, DB)
end

function DB:count()
	return self.n
end

function DB:get(num)
	return self.at[num]
end

-- the one heard longest ago. A linear scan, run only when the table is
-- full and a stranger turns up, which on any real mesh is rare next to
-- hearing one already known.
function DB:evict()
	local oldest, pick

	for num, e in pairs(self.at) do
		if not pick or (e.heard or 0) < oldest then
			oldest, pick = e.heard or 0, num
		end
	end
	if not pick then
		return false
	end
	self.at[pick] = nil
	self.n = self.n - 1
	return pick
end

-- what a node has told us, merged into what it told us before. `now`
-- is what decides who is dropped later, so a node that keeps talking
-- keeps its place.
function DB:note(num, fields, now)
	local e = self.at[num]

	if not e then
		while self.n >= self.max and self:evict() do
		end
		e = { num = num }
		self.at[num] = e
		self.n = self.n + 1
	end

	for k, v in pairs(fields or {}) do
		e[k] = v
	end
	e.heard = now
	return e
end

function DB:list()
	local out = {}

	for _, e in pairs(self.at) do
		out[#out + 1] = e
	end
	return out
end

return M
