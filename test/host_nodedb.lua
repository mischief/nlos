#!/usr/bin/env lua5.4
-- lib/nodedb, which exists to have a ceiling: the point of the tests
-- below is that a mesh larger than the table cannot make it grow.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local nodedb = require("nodedb")

local n, fails = 0, 0

local function ok(cond, name)
	n = n + 1
	if cond then
		print(string.format("ok %d - %s", n, name))
	else
		fails = fails + 1
		print(string.format("not ok %d - %s", n, name))
	end
end

do
	local db = nodedb.new(4)

	db:note(1, { long = "one" }, 100)
	db:note(2, {}, 200)

	ok(db:count() == 2, "two heard, two kept: " .. db:count())
	ok(db:get(1).long == "one", "what a node said is kept")
	ok(db:get(1).num == 1, "and it knows its own number")
	ok(db:get(1).heard == 100, "with when it was heard")
end

do
	-- a second word about a node it already has is a merge, not a
	-- new entry, and does not spend a place
	local db = nodedb.new(4)

	db:note(7, { long = "seven" }, 100)
	db:note(7, { rssi = -90 }, 300)

	ok(db:count() == 1, "hearing one twice is one node: " .. db:count())
	ok(db:get(7).long == "seven" and db:get(7).rssi == -90,
	    "the old fields survive the new ones")
	ok(db:get(7).heard == 300, "and the clock moves")
end

-- ---- the ceiling ----

do
	local db = nodedb.new(10)

	for i = 1, 1000 do
		db:note(i, {}, i)
	end

	ok(db:count() == 10, "a thousand nodes into ten places: " ..
	    db:count())
	ok(#db:list() == 10, "and the list is ten long: " .. #db:list())
end

do
	-- the oldest goes. 1 is heard again before the table fills, so 2
	-- is the one that has been quiet longest.
	local db = nodedb.new(3)

	db:note(1, {}, 100)
	db:note(2, {}, 200)
	db:note(3, {}, 300)
	db:note(1, {}, 400)
	db:note(4, {}, 500)

	ok(db:count() == 3, "still three: " .. db:count())
	ok(db:get(2) == nil, "the one quiet longest is dropped")
	ok(db:get(1) ~= nil, "the one that spoke again is kept")
	ok(db:get(3) ~= nil and db:get(4) ~= nil, "and so are the rest")
end

do
	-- a table of one still works, which is the edge where evicting
	-- and inserting meet
	local db = nodedb.new(1)

	db:note(1, {}, 100)
	db:note(2, {}, 200)

	ok(db:count() == 1 and db:get(2) ~= nil,
	    "one place holds the newest")
end

ok(nodedb.new(0):count() == 0, "a zero ceiling is not a trap")

do
	local db = nodedb.new(0)

	db:note(1, {}, 100)
	ok(db:count() == 1, "and is raised to one rather than refusing all")
end

print("1.." .. n)
os.exit(fails == 0 and 0 or 1)
