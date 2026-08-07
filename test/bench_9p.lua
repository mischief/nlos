-- what the 9P codec costs, message by message.
--
-- Encoding and decoding are separated, and the small messages are kept
-- apart from the two that carry a payload: a walk is nine fields and
-- forty bytes, an Rread is four fields and as many bytes as a block, so
-- one number over both would say nothing about either.
--
-- Registered as a benchmark rather than a test -- it asserts only that
-- it ran. Run it with `meson test -C build --benchmark`, or on a board
-- through the repl with dofile("/test/bench_9p.lua").

local sys = require("los.sys")
local p9 = require("ninep")

print("1..1")

local CPMS = sys.stats().cycles_per_ms
local ROUNDS = 3

local function bench(name, iters, fn)
	local best

	for _ = 1, ROUNDS do
		local t0 = sys.ticks()

		fn(iters)

		local d = sys.ticks() - t0

		if not best or d < best then
			best = d
		end
	end

	local ns = (best // iters * 1000000) // CPMS

	print(string.format("# %-22s %8d ns  %8.2f us", name, ns, ns / 1000))
end

-- ---- the small messages: fields, not bytes ----

local qid = { type = p9.QTFILE, vers = 1, path = 0x1234567890 }
local st = {
	qid = qid, mode = 0644, atime = 1, mtime = 2, length = 8192,
	name = "hello.txt", uid = "luaos", gid = "luaos", muid = "luaos",
}

bench("twalk encode", 5000, function(n)
	for i = 1, n do
		p9.twalk(i % 65535, 1, 2, { "usr", "lib", "ninep.lua" })
	end
end)

local twalk = p9.twalk(1, 1, 2, { "usr", "lib", "ninep.lua" })

bench("twalk decode", 5000, function(n)
	for _ = 1, n do
		p9.decode(twalk)
	end
end)

bench("tread encode", 5000, function(n)
	for i = 1, n do
		p9.tread(i % 65535, 3, i * 4096, 4096)
	end
end)

local tread = p9.tread(1, 3, 0, 4096)

bench("tread decode", 5000, function(n)
	for _ = 1, n do
		p9.decode(tread)
	end
end)

bench("packstat", 5000, function(n)
	for _ = 1, n do
		p9.packstat(st)
	end
end)

local statb = p9.packstat(st):sub(3)

bench("unpackstat", 5000, function(n)
	for _ = 1, n do
		p9.unpackstat(statb)
	end
end)

-- ---- the two that carry a block ----

for _, sz in ipairs({ 512, 4096 }) do
	local data = string.rep("x", sz)

	bench("rread encode " .. sz, 2000, function(n)
		for i = 1, n do
			p9.rread(i % 65535, data)
		end
	end)

	local rread = p9.rread(1, data)

	bench("rread decode " .. sz, 2000, function(n)
		for _ = 1, n do
			p9.decode(rread)
		end
	end)

	bench("twrite encode " .. sz, 2000, function(n)
		for i = 1, n do
			p9.twrite(i % 65535, 3, 0, data)
		end
	end)

	local twrite = p9.twrite(1, 3, 0, data)

	bench("twrite decode " .. sz, 2000, function(n)
		for _ = 1, n do
			p9.decode(twrite)
		end
	end)
end

-- a directory read: many stats back to back, which is the case that is
-- neither small nor one block.
bench("packstat x16", 2000, function(n)
	for _ = 1, n do
		local out = {}

		for i = 1, 16 do
			out[i] = p9.packstat(st)
		end
		table.concat(out)
	end
end)

print("ok 1 - benchmarked")
sys.send(sys.granted().power, { op = "reset", mode = "shutdown" })
