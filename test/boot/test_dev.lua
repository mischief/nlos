-- the dev backend interface (lib/dev.lua).
--
-- the load-bearing part of this test is that ONE set of assertions runs
-- against TWO unrelated backends: an in-memory tree and the real ESP. an
-- interface validated against a single implementation tends to be shaped
-- around it by accident, and neither of these can quietly define the
-- contract on its own.
local dev = require("dev")
local espfs = require("espfs")
local tap = require("tap")

-- 9 shared assertions per backend, plus 6 specific ones
tap.plan(29)

-- ---- the conformance suite, run against anything claiming to be a dev
--
-- `known` is a file the backend must have, with known contents, and
-- `knowndir` a directory it must have.
local function conforms(what, B, known, knowncontent, knowndir)
	local function name(s)
		return what .. ": " .. s
	end

	tap.ok(dev.check(B, what) ~= nil, name("satisfies dev.check"))

	local root = B.attach()

	tap.ok(root ~= nil, name("attach returns a root handle"))

	local rst = root and B.stat(root)

	tap.ok(rst and rst.dir == true, name("root stats as a directory"))

	-- readdir finds the two things we were promised
	local ents = root and B.readdir(root) or {}
	local seen = {}

	for _, e in ipairs(ents) do
		seen[e.name] = e
	end
	tap.ok(seen[known] ~= nil and seen[known].dir == false,
	    name("readdir lists " .. known .. " as a file"))
	tap.ok(seen[knowndir] ~= nil and seen[knowndir].dir == true,
	    name("readdir lists " .. knowndir .. " as a directory"))

	-- walk to the file and read it
	local h, werr = dev.walkpath(B, root, known)

	tap.ok(h ~= nil, name("walkpath reaches " .. known ..
	    " (" .. tostring(werr) .. ")"))

	local oh = h and B.open(h, "r")
	local data = oh and B.read(oh, 0, #knowncontent)

	tap.ok(data == knowncontent,
	    name("read returns the expected bytes"))

	-- reading past the end is "" rather than nil or an error
	local st = oh and B.stat(oh)
	local past = oh and st and B.read(oh, st.size + 100, 16)

	tap.ok(past == "", name("read past eof returns empty string"))
	if oh then
		B.clunk(oh)
	end

	-- walking to something absent fails as a value, naming the element
	local bad, berr = dev.walkpath(B, root, "no/such/thing")

	tap.ok(bad == nil and type(berr) == "string" and
	    berr:find("no") ~= nil,
	    name("walk of a missing path fails cleanly: " .. tostring(berr)))
end

-- ---- backend 1: in-memory reference ----
conforms("mem", dev.mem({
	["README"] = "hello from mem\n",
	lib = { ["a.lua"] = "-- a" },
}), "README", "hello from mem\n", "lib")

-- ---- backend 2: the real ESP ----
conforms("espfs", espfs.new("/"), "init.lua",
    -- just the first bytes of the real file, whatever they are
    (function()
	    local f = io.open("/init.lua", "r")
	    local s = f:read(24)

	    f:close()
	    return s
    end)(), "lib")

-- ---- things only the mem backend can prove (writes without a disk) ----
local m = dev.mem({ f = "0123456789" })
local mr = m.attach()
local mh = m.open(dev.walkpath(m, mr, "f"), "rw")

tap.ok(m.write(mh, 0, "AB") == 2, "mem: write reports bytes written")
tap.ok(m.read(mh, 0, 10) == "AB23456789", "mem: write lands at the offset")
tap.ok(m.write(mh, 8, "XY") == 2, "mem: write near the end")
tap.ok(m.read(mh, 0, 10) == "AB234567XY", "mem: second write lands too")

-- ---- espfs writes, which is where the disk capability bites ----
-- this payload is the boot payload, so it holds disk. a proc without it
-- would get nil + a message from open(h, "w") and nothing else would
-- break -- the gate sits where the risk is, not over reads.
-- -snapshot keeps the image itself untouched.
local E = espfs.new("/")
local er = E.attach()
local eh, eerr = E.create(er, "devscratch.txt", "w")

tap.ok(eh ~= nil, "espfs: create succeeds with the disk capability (" ..
    tostring(eerr) .. ")")

local wrote = eh and E.write(eh, 0, "dev backend wrote this")

tap.ok(wrote == 22, "espfs: write reports bytes written (" ..
    tostring(wrote) .. ")")
if eh then
	E.clunk(eh)
end

local rh = E.open(dev.walkpath(E, er, "devscratch.txt"), "r")

tap.ok(rh and E.read(rh, 0, 22) == "dev backend wrote this",
    "espfs: the bytes are really on the esp")
if rh then
	E.clunk(rh)
end

-- create is required of every backend, so the mem one does it too
local cm = dev.mem({})
local ch = cm.create(cm.attach(), "new.txt", "rw")

tap.ok(ch ~= nil and cm.write(ch, 0, "fresh") == 5,
    "mem: create makes a writable file")
tap.ok(cm.create(cm.attach(), "new.txt", "rw") == nil,
    "mem: create refuses an existing name")

-- ---- dev.check rejects an impostor ----
local bad, cerr = dev.check({ attach = function() end }, "stub")

tap.ok(bad == nil and cerr:find("missing") ~= nil,
    "dev.check names the missing method: " .. tostring(cerr))
tap.ok(dev.check("not a table") == nil, "dev.check rejects a non-table")

tap.done()
