-- the dev backend interface (lib/dev.lua).
--
-- two things this is really testing:
--
-- 1. ONE conformance suite runs against TWO unrelated backends, an
--    in-memory tree and the real ESP. an interface validated against a
--    single implementation gets shaped around it by accident.
-- 2. errors are RAISED, plan 9 style, and carry bare 9front strings with
--    no lua position prefix -- because an Rerror reading "espfs.lua:88:"
--    would be nonsense to a 9P client.
local dev = require("dev")
local espfs = require("espfs")
local tap = require("tap")

tap.plan(42)

-- ---- the conformance suite, run against anything claiming to be a dev
local function conforms(what, B, known, knowncontent, knowndir)
	local function name(s)
		return what .. ": " .. s
	end

	tap.ok(pcall(dev.check, B, what), name("satisfies dev.check"))

	-- inside the stack nothing checks; this is the entry point, so it
	-- is the one place that pcalls. exactly one, like a syscall.
	local ok, res = dev.protect(function()
		local root = B.attach()
		local rst = B.stat(root)

		assert(rst.dir == true, "root is not a directory")

		local seen = {}

		for _, e in ipairs(B.readdir(root)) do
			seen[e.name] = e
		end
		assert(seen[known] and seen[known].dir == false,
		    known .. " missing or not a file")
		assert(seen[knowndir] and seen[knowndir].dir == true,
		    knowndir .. " missing or not a directory")

		-- <close> is our waserror: this clunks on the way out of the
		-- function, whether by return or by an error blowing through.
		local h <close> = B.open(dev.walkpath(B, root, known), "r")
		local data = B.read(h, 0, #knowncontent)
		local st = B.stat(h)

		assert(data == knowncontent, "read returned " .. tostring(data))
		assert(B.read(h, st.size + 100, 16) == "",
		    "read past eof was not empty")
		return true
	end)

	tap.ok(ok, name("walk/stat/readdir/read all behave (" ..
	    tostring(res) .. ")"))

	-- a missing path raises, and the message names the element rather
	-- than just saying something is absent
	local wok, werr = dev.protect(function()
		return dev.walkpath(B, B.attach(), "no/such/thing")
	end)

	tap.ok(not wok, name("walk of a missing path raises"))
	tap.ok(tostring(werr):find(dev.Enonexist, 1, true) ~= nil,
	    name("raises Enonexist: " .. tostring(werr)))
	tap.ok(tostring(werr):find("'no'", 1, true) ~= nil,
	    name("names the failing element"))

	-- and the message carries no lua source position
	tap.ok(tostring(werr):find("%.lua:%d") == nil,
	    name("message has no position prefix"))

	-- a DIRECTORY handle must come back closable too, not just a file
	-- handle: otherwise <close> works for one and raises for the other,
	-- which is a difference no caller should have to know about.
	local cdok = dev.protect(function()
		local root = B.attach()
		local d <close> = B.open(B.walk(root, knowndir), "r")

		return d
	end)

	tap.ok(cdok, name("an open directory handle is closable"))

	-- reading a directory as a file raises Eisdir
	local dok, derr = dev.protect(function()
		local root = B.attach()
		local d = B.walk(root, knowndir)

		return B.read(d, 0, 16)
	end)

	tap.ok(not dok and tostring(derr) == dev.Eisdir,
	    name("reading a directory raises Eisdir: " .. tostring(derr)))
end

conforms("mem", dev.mem({
	["README"] = "hello from mem\n",
	lib = { ["a.lua"] = "-- a" },
}), "README", "hello from mem\n", "lib")

conforms("espfs", espfs.new("/"), "init.lua",
    (function()
	    local f = io.open("/init.lua", "r")
	    local s = f:read(24)

	    f:close()
	    return s
    end)(), "lib")

-- ---- <close> really runs while an error unwinds ----
-- the whole reason to prefer it over plan 9's waserror bookkeeping: an
-- error thrown mid-scope must still clunk the handle.
local clunked = false
local watched = dev.mem({ f = "xyz" })
local realclunk = watched.clunk

watched.clunk = function(h)
	clunked = true
	realclunk(h)
end

local uok = dev.protect(function()
	local h <close> =
	    watched.open(dev.walkpath(watched, watched.attach(), "f"), "r")

	dev.error("something went wrong halfway through")
	return h
end)

tap.ok(not uok, "<close>: the error did propagate out")
tap.ok(clunked, "<close>: the handle was clunked during unwinding")

-- ---- writes, which only mem can do without a disk capability ----
local m = dev.mem({ f = "0123456789" })
local mh = m.open(dev.walkpath(m, m.attach(), "f"), "rw")

tap.ok(m.write(mh, 0, "AB") == 2, "mem: write reports bytes written")
tap.ok(m.read(mh, 0, 10) == "AB23456789", "mem: write lands at the offset")
tap.ok(m.write(mh, 8, "XY") == 2, "mem: write near the end")
tap.ok(m.read(mh, 0, 10) == "AB234567XY", "mem: second write lands too")

local cm = dev.mem({})
local ch = cm.create(cm.attach(), "new.txt", "rw")

tap.ok(ch ~= nil and cm.write(ch, 0, "fresh") == 5,
    "mem: create makes a writable file")
tap.ok(select(2, dev.protect(cm.create, cm.attach(), "new.txt", "rw")) ==
    dev.Eexist, "mem: create of an existing name raises Eexist")

-- ---- espfs writes, where the disk capability actually bites ----
-- this payload is the boot payload, so it holds disk. a proc without it
-- raises Eperm here and reads keep working. -snapshot keeps the image
-- untouched.
local E = espfs.new("/")
local eok, eres = dev.protect(function()
	local h <close> = E.create(E.attach(), "devscratch.txt", "w")

	return E.write(h, 0, "dev backend wrote this")
end)

tap.ok(eok, "espfs: create+write with the disk capability (" ..
    tostring(eres) .. ")")
tap.ok(eres == 22, "espfs: write reported 22 bytes (" .. tostring(eres) .. ")")

local rok, rdata = dev.protect(function()
	local h <close> =
	    E.open(dev.walkpath(E, E.attach(), "devscratch.txt"), "r")

	return E.read(h, 0, 22)
end)

tap.ok(rok and rdata == "dev backend wrote this",
    "espfs: the bytes are really on the esp")

-- ---- dev.check rejects an impostor, by raising ----
local cok, cerr = dev.protect(dev.check, { attach = function() end }, "stub")

tap.ok(not cok and tostring(cerr):find("missing") ~= nil,
    "dev.check names the missing method: " .. tostring(cerr))
tap.ok(not (dev.protect(dev.check, "not a table")),
    "dev.check rejects a non-table")

-- ---- closable must not eat a backend's own metatable ----
-- dev.closable is called by every backend, so a plain setmetatable there
-- would silently delete an __index or __tostring the backend relies on.
local marked = dev.mem({ f = "z" })
local realopen = marked.open

marked.open = function(h, mode)
	setmetatable(h, {
		__index = { mine = true },
		__tostring = function() return "custom" end,
	})
	return realopen(h, mode)
end

local mh2 = marked.open(dev.walkpath(marked, marked.attach(), "f"), "r")

tap.ok(mh2.mine == true, "closable preserves the backend's __index")
tap.is(tostring(mh2), "custom", "closable preserves __tostring")
tap.ok(getmetatable(mh2).__close ~= nil, "and still added __close")

-- ---- not-implemented is absence, not a raising stub ----
-- remove/wstat are checkable before calling, which a stub would destroy.
tap.ok(dev.mem({}).remove == nil, "remove is absent, not a stub")
tap.ok(espfs.new("/").remove == nil, "espfs remove is absent too")

-- ---- walkmany: used when offered, and the loop when not ----
--
-- optional exactly like remove(), so walkpath has to check rather than
-- call. a backend with none must still resolve a deep path.

local tree = { a = { b = { c = "leaf\n" } } }
local plain = dev.mem(tree)
local nwalk = 0

tap.ok(plain.walkmany == nil, "dev.mem offers no walkmany")

do
	local counted = {}

	for k, v in pairs(plain) do
		counted[k] = v
	end
	counted.walk = function(h, name)
		nwalk = nwalk + 1
		return plain.walk(h, name)
	end

	local h = dev.walkpath(counted, counted.attach(), "/a/b/c")

	tap.is(counted.read(h, 0, 99), "leaf\n",
	    "a backend without walkmany resolves a deep path")
	tap.is(nwalk, 3, "by walking each element once (" .. nwalk .. ")")
end

-- and one that DOES offer it gets the whole path in a single call
do
	local batched = {}
	local calls, got = 0, nil

	for k, v in pairs(plain) do
		batched[k] = v
	end
	batched.walkmany = function(h, names)
		calls = calls + 1
		got = table.concat(names, "/")
		return dev.walkall(plain, h, names)
	end

	local h = dev.walkpath(batched, batched.attach(), "/a/./b//c")

	tap.is(calls, 1, "walkmany was preferred, and called once")
	tap.is(got, "a/b/c", "with '.' and empty elements already dropped")
	tap.is(batched.read(h, 0, 99), "leaf\n", "and it resolved the path")

	-- a zero-element path must NOT call it: that is a clone in 9P, and
	-- here it is simply the handle you already hold
	calls = 0
	local root = batched.attach()

	tap.ok(dev.walkpath(batched, root, "/") == root and calls == 0,
	    "an empty path returns the same handle without a walk")
end

-- the failing element is still named, which is the whole reason
-- walkall exists as a shared helper
do
	local ok, err = pcall(dev.walkpath, plain, plain.attach(), "/a/nope/c")

	tap.ok(not ok and tostring(err):find("'nope'", 1, true) ~= nil,
	    "a deep walk names the element that failed: " .. tostring(err))
end

tap.done()
