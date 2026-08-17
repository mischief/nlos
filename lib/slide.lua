-- slide: the 2048 board, and what a move does to it.
--
-- Sans-io: no screen, no input, no clock. A move is a pure function of
-- the cells, and where a new tile lands comes from an injected rand,
-- so a test can play a whole game with no luck in it.

local M = {}

local Board = {}

Board.__index = Board

-- what a new tile is. Four in five are a 2, as the original does.
local function newtile(rand)
	return rand(10) <= 8 and 2 or 4
end

-- new{ n =, rand = } -- rand(k) answers 1..k. Two tiles are placed, so
-- what comes back is a board someone can move.
function M.new(o)
	o = o or {}

	local n = o.n or 4
	local b = setmetatable({
		n = n,
		cells = {},
		score = 0,
		rand = o.rand or math.random,
	}, Board)

	for i = 1, n * n do
		b.cells[i] = 0
	end
	if o.empty then
		return b
	end
	b:spawn()
	b:spawn()
	return b
end

function Board:index(x, y)
	return (y - 1) * self.n + x
end

function Board:at(x, y)
	return self.cells[self:index(x, y)]
end

function Board:set(x, y, v)
	self.cells[self:index(x, y)] = v
end

-- a tile in a free cell, or nil where there is none. The cell is picked
-- among the empty ones rather than by retrying a random square, so a
-- nearly full board costs the same as an empty one.
function Board:spawn()
	local free = {}

	for i = 1, self.n * self.n do
		if self.cells[i] == 0 then
			free[#free + 1] = i
		end
	end
	if #free == 0 then
		return nil
	end

	local i = free[self.rand(#free)]

	self.cells[i] = newtile(self.rand)
	return i
end

-- one line, slid toward its front. Returns the new values and what the
-- merges scored. A tile merges once per move: 2 2 2 2 is two 4s, not
-- one 8, which is the rule the whole game turns on.
local function slide(line, n)
	local out, gained, k = {}, 0, 0

	for i = 1, n do
		local v = line[i]

		if v ~= 0 then
			if k > 0 and out[k] == v then
				out[k] = v * 2
				gained = gained + v * 2
				k = 0	-- spent: it cannot merge again
			else
				out[#out + 1] = v
				k = #out
			end
		end
	end
	for i = #out + 1, n do
		out[i] = 0
	end
	return out, gained
end

-- the cells a direction walks, as lines of indexes. Reading a line in
-- reverse is what makes right and down the same code as left and up.
function Board:lines(dir)
	local n, out = self.n, {}

	for a = 1, n do
		local line = {}

		for b = 1, n do
			local x, y

			if dir == "left" then
				x, y = b, a
			elseif dir == "right" then
				x, y = n + 1 - b, a
			elseif dir == "up" then
				x, y = a, b
			else
				x, y = a, n + 1 - b
			end
			line[b] = self:index(x, y)
		end
		out[a] = line
	end
	return out
end

-- move(dir) -> moved, gained. A move that changes nothing is not a
-- move: no tile spawns, and the caller has not used their turn.
function Board:move(dir)
	local moved, gained = false, 0

	for _, line in ipairs(self:lines(dir)) do
		local vals = {}

		for i, at in ipairs(line) do
			vals[i] = self.cells[at]
		end

		local out, got = slide(vals, self.n)

		gained = gained + got
		for i, at in ipairs(line) do
			if self.cells[at] ~= out[i] then
				moved = true
				self.cells[at] = out[i]
			end
		end
	end

	self.score = self.score + gained
	return moved, gained
end

-- whether any direction would move something. Asked of a full board,
-- which is the only time the answer is interesting.
function Board:canmove()
	local n = self.n

	for i = 1, n * n do
		if self.cells[i] == 0 then
			return true
		end
	end
	for y = 1, n do
		for x = 1, n do
			local v = self:at(x, y)

			if x < n and self:at(x + 1, y) == v then
				return true
			end
			if y < n and self:at(x, y + 1) == v then
				return true
			end
		end
	end
	return false
end

function Board:best()
	local top = 0

	for i = 1, self.n * self.n do
		if self.cells[i] > top then
			top = self.cells[i]
		end
	end
	return top
end

M.Board = Board
M.slide = slide

return M
