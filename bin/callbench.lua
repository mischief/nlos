-- callbench: what one call costs, by how much it touches.
--
-- Anything measured per packet, per frame or per file is built out of
-- these, so a layer that looks slow is either doing many of them or
-- paying more for each than this says it should. Best of R rounds,
-- because sys.ticks is wall time and another proc lands in the sample.

local sys = require("los.sys")
local thread = require("los.thread")

local CPMS = sys.stats().cycles_per_ms
local N = tonumber(arg and arg[1]) or 200
local R = tonumber(arg and arg[2]) or 10
local big = string.rep("z", 1480)
local small = "0123456789abcdefghij"

local function bench(what, fn)
	local best

	for _ = 1, R do
		local t0 = sys.ticks()

		for _ = 1, N do
			fn()
		end

		local d = sys.ticks() - t0

		if not best or d < best then
			best = d
		end
	end
	print(string.format("%-22s %9.2f us", what, best / N * 1000 / CPMS))
end

local function noop() end
local sub, byte, unpack = string.sub, string.byte, string.unpack

-- ---- the interpreter, touching nothing ----

bench("empty loop", noop)
bench("lua call, 1 arg", function() return noop(1) end)
bench("#big", function() return #big end)
bench("big:byte(1)", function() return byte(big, 1) end)
bench("unpack tcp hdr", function()
	return unpack(">I2I2I4I4I2I2I2I2", big)
end)

-- ---- allocation ----
--
-- A table with a hash part and a full-sized string cost far more than
-- the bytes they move: what is being measured is the allocator and the
-- collector behind it. Compare against buf copy, which moves the same
-- bytes into memory that already exists.
bench("{} literal", function() return {} end)
bench("{9 fields}", function()
	return { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8,
	    i = 9 }
end)
bench("small:sub(1,20)", function() return sub(small, 1, 20) end)
bench("big:sub(21)", function() return sub(big, 21) end)

local buf = require("los.buf")
local b = buf.new(1480)

bench("buf.new(1480)", function() return buf.new(1480) end)
bench("buf copy 1480", function() b:copy(1, big) end)

-- ---- the kernel ----
--
-- uptime_ms is the floor: one entry, one integer back. What a message
-- costs over that is the serializer and the port, and a receive pays
-- for the table and the string it builds on the way out.
local p1 = sys.newport("cb1")
local p2 = sys.newport("cb2")
local p3 = sys.newport("cb3")
local h3 = sys.sendright(p3)
local cases = { { port = p1 }, { port = p2 }, { port = p3 } }
local msg = { src = "abcd", dst = "efgh", proto = 6, data = big }

bench("uptime_ms", function() return sys.uptime_ms() end)
bench("tryrecv empty", function() return sys.tryrecv(p1) end)
bench("send 1480", function() return sys.send(h3, msg) end)
bench("send+tryrecv 1480", function()
	sys.send(h3, msg)
	return sys.tryrecv(p3)
end)
-- thread.alt polls every case with a tryrecv of its own before it
-- blocks, so a task with three cases pays for three.
bench("alt, 3rd ready", function()
	sys.send(h3, msg)
	return thread.alt(cases)
end)
