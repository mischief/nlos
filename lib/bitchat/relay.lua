-- Relaying, which is what makes the mesh a mesh.
--
-- Sans-io: what arrives goes in, and out comes the ttl to send it on
-- with and how long to wait first. The caller owns the radio and the
-- clock, so this is testable without either.

local sha256 = require("crypto.sha256")

local M = {}

-- a packet may not be relayed past this however high its ttl arrived,
-- so a peer cannot make one circulate by claiming 255 hops.
M.TTLMAX = 7

-- above this many links a node is in a crowd: its copies are the ones
-- most likely to be redundant, so they go shorter and later.
M.CROWD = 6

-- what a seen packet is remembered by. No ttl in it: a relayed copy
-- differs from the original in exactly that, and it is the copy we mean
-- to recognise.
M.MAXSEEN = 1000
M.MAXAGE = 300

local Relay = {}

Relay.__index = Relay

-- new{me = <8 bytes>, now = <function returning seconds>,
--     random = <function(a, b)>}
function M.new(o)
	return setmetatable({
		me = o.me,
		now = o.now or function() return 0 end,
		random = o.random or math.random,
		keys = {},		-- key -> when it was seen
		order = {},		-- keys oldest first, to drop by age
	}, Relay)
end

function M.key(p)
	local digest = sha256.new():update(p.payload):final():sub(1, 4)

	return p.sender .. string.pack(">I8", p.timestamp) ..
	    string.char(p.type) .. digest
end

-- true where this packet has been through here before. Recording it is
-- the same call: a caller that asks and forgets would relay twice.
function Relay:seen(p)
	local k = M.key(p)
	local at = self.now()

	if self.keys[k] then
		return true
	end

	self.keys[k] = at
	self.order[#self.order + 1] = k

	-- by age first, then by count: a quiet hour should not hold a
	-- thousand keys, and a loud one must not hold more.
	local i = 1

	while i <= #self.order do
		local k2 = self.order[i]

		if at - (self.keys[k2] or at) <= M.MAXAGE then
			break
		end
		self.keys[k2] = nil
		i = i + 1
	end
	while #self.order - i + 1 > M.MAXSEEN do
		self.keys[self.order[i]] = nil
		i = i + 1
	end
	if i > 1 then
		self.order = table.move(self.order, i, #self.order, 1, {})
	end
	return false
end

-- the ttl to relay with and the milliseconds to wait, or nil where this
-- packet stops here. `degree` is how many links we hold.
--
-- Only the ttl changes on the way through: the signature covers the
-- packet with ttl zeroed precisely so a relay does not invalidate it.
function Relay:decide(p, degree)
	local ttl = math.min(p.ttl or 0, M.TTLMAX)

	-- ours, or for us, or out of hops. One short of zero rather than
	-- zero: a packet relayed at ttl 1 would be relayed with 0 and
	-- every hop would have to agree what 0 means.
	if ttl <= 1 or p.sender == self.me or p.recipient == self.me then
		return nil
	end

	local directed = p.recipient ~= nil
	local limit = ttl

	if not directed then
		-- a broadcast in a crowd is cut short, and one at the edge
		-- of the mesh is not: the far side has nobody else to hear
		-- it from.
		if degree >= M.CROWD then
			limit = math.max(2, math.min(ttl, 5))
		elseif degree > 2 then
			limit = math.max(2, math.min(ttl, 6))
		end
	end

	local lo, hi

	if directed then
		lo, hi = 20, 60
	elseif degree <= 2 then
		lo, hi = 10, 40
	elseif degree <= 5 then
		lo, hi = 60, 150
	elseif degree <= 9 then
		lo, hi = 80, 180
	else
		lo, hi = 100, 220
	end

	return limit - 1, self.random(lo, hi)
end

M.Relay = Relay

return M
