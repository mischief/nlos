-- sys.reclaim hands back what the lua heap holds but does not use.
--
-- Most of that is the large-block cache: a freed block over 512 bytes is
-- kept against the next request of its size, which is right for a
-- machine moving 9p messages and wrong for one that has gone quiet. It
-- is memory nothing can see -- not the proc that freed it, not the rest
-- of the machine -- until the chunk source refuses an allocation.
--
-- lua_cached is that part of lua_unused, so the two together say whether
-- what is held can be had back or is fragmentation inside chunks still
-- in use. What is left after a reclaim is the second kind.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(7)

local function churn()
	local t = {}

	for i = 1, 400 do
		t[i] = string.rep("x", 4000 + i)
	end
	t = nil
	collectgarbage()
	collectgarbage()
end

-- garbage of the shape the cache is for: well over the 512-byte class
-- ceiling, freed all at once.
churn()

local a = sys.stats()

tap.ok(a.lua_cached > 0, "freeing large blocks leaves them cached")
tap.ok(a.lua_cached <= a.lua_unused, "and cached is part of unused")

local freed = sys.reclaim()

tap.ok(freed >= a.lua_cached, "reclaim returns at least what was cached")

local b = sys.stats()

tap.is(b.lua_cached, 0, "and the cache is empty after")
tap.ok(b.lua_mapped < a.lua_mapped,
    "so the heap has given the machine its chunks back")

-- and without being asked: a machine with nothing to dispatch sweeps
-- once on its own, which is the case a board is in between the program
-- you just ran and the one you run next.
thread.spawn(function()
	churn()
	tap.ok(sys.stats().lua_cached > 0, "cached again, with nobody asking")

	-- long enough for the lap counter to reach the sweep with this
	-- proc parked. Nothing else runs here, so these are idle laps.
	thread.sleep(2000)

	tap.is(sys.stats().lua_cached, 0, "a quiet machine gives it back")
	tap.done()
	os.exit(0)
end)

thread.run()
