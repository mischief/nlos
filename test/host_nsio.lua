#!/usr/bin/env lua5.4
-- lua's io read formats, ours against the real one.
--
-- Every case is run twice: once on this host's io, once on lib/nsio's
-- file over an in-memory source. The reference is not a table of
-- expected values written here -- it is what lua itself answers.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path
package.loaded["los.sys"] = { MAXMSG = 8192 }
package.preload["los.thread"] = function()
	return { inthread = function() return false end }
end
package.loaded["ns"] = { current = function() return nil end }

local nsio = require("nsio")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	io.write((cond and "ok " or "not ok ") .. count .. " - " .. name .. "\n")
	if not cond then
		failed = failed + 1
	end
end

-- a byte source over a string, which is what a Chan or a stream is to
-- the file object: read(n) -> bytes, "" at end.
local function source(s)
	local at = 1

	return {
		read = function(self, n)
			if at > #s then
				return ""
			end

			local out = s:sub(at, at + n - 1)

			at = at + #out
			return out
		end,
		write = function() return true end,
		close = function() end,
	}
end

local function tmpfile(s)
	local path = os.tmpname()
	local f = assert(io.open(path, "wb"))

	f:write(s)
	f:close()
	return path
end

-- run one sequence of reads against both, and compare the answers
local function same(body, fmts, what)
	local path = tmpfile(body)
	local real = assert(io.open(path, "rb"))
	local ours = nsio.stream(source(body), "test")
	local agree = true
	local detail = ""

	for _, f in ipairs(fmts) do
		local a = table.pack(real:read(table.unpack(f)))
		local b = table.pack(ours:read(table.unpack(f)))

		if a.n ~= b.n then
			agree = false
			detail = ("count %d vs %d"):format(a.n, b.n)
			break
		end
		for i = 1, a.n do
			if a[i] ~= b[i] then
				agree = false
				detail = ("%q vs %q"):format(tostring(a[i]),
				    tostring(b[i]))
				break
			end
		end
		if not agree then
			break
		end
	end
	real:close()
	os.remove(path)
	ok(agree, what .. (agree and "" or " -- " .. detail))
end

local L = "one\ntwo\nthree\n"
local NOEOL = "a\nb"

same(L, { { "l" }, { "l" }, { "l" }, { "l" } }, "lines, then eof")
same(L, { { "L" }, { "L" } }, "L keeps the newline")
same(L, { { "a" } }, "a reads it all")
same(L, { { "a" }, { "a" } }, "a at eof is empty string, not nil")
same(L, { { 3 }, { 1 }, { 100 } }, "counts, and a short last read")
same(L, { { 0 } }, "zero is the eof probe")
same("", { { 0 } }, "and answers nil at eof")
same("", { { "l" } }, "a line at eof is nil")
same("", { { "a" } }, "all of nothing is empty")
same(NOEOL, { { "l" }, { "l" }, { "l" } }, "a last line without a newline")
same(NOEOL, { { "L" }, { "L" } }, "L on a line without one")
same(L, { { "l", "l" } }, "two formats in one call")
same(L, { { "l", "l", "l", "l" } }, "and stops at the first nil")
same("42 7.5 -3\n", { { "n" }, { "n" }, { "n" } }, "numbers")
same("  12abc", { { "n" }, { "a" } }, "a number stops where it stops")
same("0x10 x\n", { { "n" }, { "a" } }, "hex, as tonumber takes it")
same("nope\n", { { "n" } }, "not a number answers nil")
same(L, { { "l" }, { "a" } }, "a line then the rest")

-- io.type, which is a function of ours rather than a comparison
local h = nsio.stream(source("x"), "t")

ok(nsio.type(h) == "file", "io.type of an open file")
h:close()
ok(nsio.type(h) == "closed file", "io.type of a closed one")
ok(nsio.type(42) == nil, "io.type of something else")
ok(nsio.type("string") == nil, "and of a string")

-- lines() as an iterator, with and without a format
do
	local f = nsio.stream(source(L), "t")
	local got = {}

	for line in f:lines() do
		got[#got + 1] = line
	end
	ok(table.concat(got, ",") == "one,two,three", "lines() iterates")

	local g = nsio.stream(source(L), "t")
	local n = 0

	for line in g:lines("L") do
		if line:sub(-1) == "\n" then
			n = n + 1
		end
	end
	ok(n == 3, "lines('L') keeps the newlines")
end

-- ---- how many reads one line costs ----
--
-- The source is what a mount is: every read is a round trip, 1.3ms on
-- the board. A line read a byte at a time is the defect this buffering
-- exists for, so the count is asserted rather than the timing.
do
	local reads = 0
	local body = ("x"):rep(300) .. "\n" .. ("y"):rep(300) .. "\n"
	local at = 1
	local counting = {
		read = function(_, n)
			reads = reads + 1
			if at > #body then
				return ""
			end

			local out = body:sub(at, at + n - 1)

			at = at + #out
			return out
		end,
		write = function() return true end,
		close = function() end,
	}
	local h = nsio.stream(counting, "counted")
	local line = h:read("l")

	ok(#line == 300, "a 300-byte line reads whole (" .. #line .. ")")
	ok(reads == 1, "and costs one read of the source, not 300 (" ..
	    reads .. ")")

	local before = reads

	h:read("l")
	ok(reads - before == 0, "the second line comes out of the buffer (" ..
	    (reads - before) .. " reads)")
end

io.write("1.." .. count .. "\n")
os.exit(failed == 0 and 0 or 1)
