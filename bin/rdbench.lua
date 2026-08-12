-- what a readdir costs, split into what it pays per call and what it
-- pays per entry.
--
-- Directories of very different sizes, timed the same way: if a small
-- one costs nearly as much as a large one, the cost is the round trip
-- and the entries are free. If it tracks the count, the cost is per
-- entry and worth chasing into the layers.
--
-- A stat sits beside them as the one-message floor: it crosses the same
-- proc boundary and carries almost nothing back.
local sys = require("los.sys")
local prog = require("prog")

local N = assert(prog.ns(), "rdbench: no namespace")
local CPMS = sys.stats().cycles_per_ms
local ROUNDS = tonumber(arg and arg[1]) or 20

local function ms(t) return t * 1000 // CPMS / 1000 end

local function timeit(fn)
	local best
	for _ = 1, ROUNDS do
		local t0 = sys.ticks()

		fn()
		local d = sys.ticks() - t0

		if not best or d < best then best = d end
	end
	return best
end

local paths = { "/lib", "/bin", "/etc", "/" }

print(string.format("%-10s %6s %10s %10s %10s",
    "path", "ents", "readdir", "per ent", "stat"))

for _, p in ipairs(paths) do
	local ents = N:readdir(p)

	if ents then
		local rd = timeit(function() N:readdir(p) end)
		local st = timeit(function() N:stat(p) end)

		print(string.format("%-10s %6d %8.2fms %8.3fms %8.2fms",
		    p, #ents, ms(rd), ms(rd) / #ents, ms(st)))
	end
end

-- Is it the entries, or the message that carries them? A server that
-- replies with a table of n entries and does nothing else, swept over
-- the sizes above. Whatever this costs per entry is what a readdir pays
-- before any of its own work.
local server = [[
	local a = ...
	local sys = require("los.sys")
	local p = sys.newport("rdbench_srv")
	local back = a.reply.__right

	sys.send(back, { port = { __right = sys.sendright(p) } })
	while true do
		local _, m = sys.altrecv({ p })

		if type(m) ~= "table" then break end
		local out = {}

		for i = 1, m.n do
			out[i] = { name = "entry" .. i, size = i, dir = false }
		end
		sys.send(back, { ents = out })
	end
]]

local rp = sys.newport("rdbench_reply")
local myright = sys.sendright(rp)
local pid = sys.spawn(server, { arg = { reply = { __right = myright } } })
local _, hello = sys.altrecv({ rp })
local sright = hello and hello.port and hello.port.__right

if sright then
	print("")
	print(string.format("%-10s %6s %10s %10s", "reply", "ents",
	    "round trip", "per ent"))
	for _, n in ipairs({ 0, 8, 28, 73 }) do
		local t = timeit(function()
			sys.send(sright, { n = n })
			sys.altrecv({ rp })
		end)

		print(string.format("%-10s %6d %8.2fms %8.3fms", "table", n,
		    ms(t), n > 0 and ms(t) / n or 0))
	end
	sys.send(sright, "quit")
end
