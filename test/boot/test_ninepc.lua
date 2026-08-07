-- the C 9P codec against the Lua one, message by message.
--
-- Neither is trusted alone. src/ninep.c is selected automatically when
-- it is present, and lib/ninep.lua keeps its own version reachable as
-- ninep.pure, so this compares the two on the same inputs -- including
-- the malformed ones, where agreeing on nil matters as much as
-- agreeing on a field.

local p9 = require("ninep")
local tap = require("tap")

tap.plan(34)

local C, L = p9, p9.pure

tap.ok(C.decode ~= L.decode, "the C codec is the one in use")

-- same table, or say where they differ. Compared by field rather than
-- by serialising, because a number and its string are not the same
-- thing and this has to notice that.
local function same(a, b, path)
	path = path or ""
	if type(a) ~= type(b) then
		return false, path .. ": " .. type(a) .. " vs " .. type(b)
	end
	if type(a) ~= "table" then
		if a ~= b then
			return false, path .. ": " .. tostring(a) .. " vs " ..
			    tostring(b)
		end
		return true
	end
	for k, v in pairs(a) do
		local ok, why = same(v, b[k], path .. "." .. tostring(k))
		if not ok then
			return false, why
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false, path .. "." .. tostring(k) .. ": only in one"
		end
	end
	return true
end

local function agree(name, msg)
	local a, b = C.decode(msg), L.decode(msg)
	local ok, why = same(a, b)

	tap.ok(ok, "decode agrees: " .. name .. (ok and "" or " -- " .. why))
end

local function encodes(name, fn, ...)
	local a, b = fn(C, ...), fn(L, ...)

	if not tap.ok(a == b, "encode agrees: " .. name) then
		tap.diag(string.format("C   %q", a))
		tap.diag(string.format("lua %q", b))
	end
	return a
end

-- ---- the messages ----

local qid = { type = p9.QTDIR, vers = 7, path = 0x123456789a }

agree("tversion", p9.tversion(p9.NOTAG, 8192, "9P2000"))
agree("tattach", p9.tattach(1, 0, p9.NOFID, "glenda", ""))
agree("rattach", p9.rattach(1, qid))
agree("rerror", p9.rerror(3, "file does not exist"))
agree("ropen", p9.ropen(4, qid, 8192))
agree("rwalk", p9.rwalk(5, { qid, qid, qid }))
agree("rwalk empty", p9.rwalk(5, {}))
agree("tclunk", p9.tclunk(6, 3))
agree("rwrite", p9.rwrite(7, 4096))
agree("rflush", p9.rflush(8))

local twalk = encodes("twalk", function(m, ...) return m.twalk(...) end,
    9, 1, 2, { "usr", "lib", "ninep.lua" })

agree("twalk", twalk)
agree("twalk none", encodes("twalk none",
    function(m, ...) return m.twalk(...) end, 9, 1, 2, {}))

local tread = encodes("tread", function(m, ...) return m.tread(...) end,
    10, 3, 1 << 33, 4096)

agree("tread", tread)

local data = string.rep("payload ", 64)
local rread = encodes("rread", function(m, ...) return m.rread(...) end,
    11, data)

agree("rread", rread)
tap.is(C.decode(rread).data, data, "rread's payload survives")

local twrite = encodes("twrite", function(m, ...) return m.twrite(...) end,
    12, 3, 99, data)

agree("twrite", twrite)
tap.is(C.decode(twrite).data, data, "twrite's payload survives")

-- ---- stat, and the defaults it fills in ----

local full = {
	qid = qid, mode = 0x81a4, atime = 111, mtime = 222, length = 4096,
	name = "hello.txt", uid = "glenda", gid = "sys", muid = "bootes",
}
local bare = { qid = qid, mode = 0, length = 0, name = "x" }

local sf = encodes("packstat", function(m, ...) return m.packstat(...) end,
    full)

encodes("packstat defaults", function(m, ...) return m.packstat(...) end,
    bare)

local su = same(C.unpackstat(sf:sub(3)), L.unpackstat(sf:sub(3)))

tap.ok(su, "unpackstat agrees")
tap.is(C.unpackstat(sf:sub(3)).name, "hello.txt", "and reads the name")
agree("rstat", p9.rstat(13, sf:sub(3)))

-- ---- malformed input: agreeing on refusal ----
--
-- A short message is what a wire produces when a connection is cut, so
-- the codec has to say nothing rather than raise.

local short = rread:sub(1, 20)
local okc, rc = pcall(C.decode, short)
local okl, rl = pcall(L.decode, short)

tap.ok(okc, "a truncated message does not raise in C")
tap.ok(not okc or rc == nil or okl, "and the two treat it the same way")

tap.ok(pcall(C.decode, ""), "an empty message does not raise")
tap.ok(C.decode("") == nil, "and decodes to nothing")
tap.ok(C.decode("\3\0\0\0") == nil, "nor does a header cut in half")

-- a count that runs past the end: the length field is attacker-supplied
-- and must not be believed.
local lying = string.pack("<I4BI2I4", 7 + 4 + 4, p9.Rread, 1, 0xffffff) ..
    "abcd"

tap.ok(C.decode(lying) == nil, "a count past the end decodes to nothing")

tap.done()
