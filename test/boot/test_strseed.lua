-- every proc hashes a string the same way.
--
-- lua draws a string hash seed per state, which makes hash flooding
-- hard and makes a shared string impossible: two states put the same
-- text in different buckets, so neither finds what the other interned.
-- src/coreg.h pins luai_makeseed to one seed per boot instead, which
-- keeps the randomness and makes the buckets agree. That is what
-- test/arena_test.c needs to splice a shared string into a state.
--
-- The seed is not readable, and must not be: a proc that knows it can
-- build colliding keys. What is readable is its effect. A table's
-- iteration order follows the hash of its keys, so two procs walking
-- the same string-keyed table in the same order is the seed agreeing.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(3)

-- enough keys to fill several buckets, so a shared order is evidence
-- rather than luck.
local WORDS = [[
attach walk stat open create read write readdir clunk mount unmount
bind describe restore adopt current searcher elements walkpath subtree
readonly protect closable error nonexist exist notdir isdir perm
]]

local function order()
	local t = {}

	for w in WORDS:gmatch("%a+") do
		t[w] = true
	end

	local seen = {}

	for k in pairs(t) do
		seen[#seen + 1] = k
	end
	return table.concat(seen, " ")
end

local mine = order()

tap.ok(#mine > 100, "a table of string keys to walk")

local out = sys.newport("strseed.out")
local outr = sys.sendright(out)

local body = ([[
local sys = require("los.sys")
local thread = require("los.thread")
local WORDS = %q
local t = {}
for w in WORDS:gmatch("%%a+") do t[w] = true end
local seen = {}
for k in pairs(t) do seen[#seen + 1] = k end
local ctx = thread.recv(sys.SELF)
sys.send(ctx.out.__right, table.concat(seen, " "))
]]):format(WORDS)

local pid, h = sys.spawn(body, { name = "strseed" })

tap.ok(pid ~= nil, "a second proc, with a lua state of its own")
sys.send(h, { out = { __right = outr } })
sys.close(h)

thread.spawn(function()
	local theirs = thread.recvtimeout(out, 5000)

	tap.is(theirs, mine,
	    "two procs walk one table of string keys in one order")
	tap.done()
	os.exit(0)
end)

thread.run()
