#!/usr/bin/env lua5.4
-- lib/svc.lua's start, and lib/svcarg.lua's two forms, on the host.
-- proc.spawn is a function that records what it was handed, so what a
-- service list means is checked without a machine to start one on.
-- TAP direct: lib/tap.lua needs los.sys.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

-- every spawn, in order, so a test can read back the arg an entry built.
local spawned = {}
local nextpid = 100
local recvq = {}

package.preload["los.sys"] = function()
	return { SELF = 1 }
end
package.preload["los.thread"] = function()
	return {
		recv = function()
			return table.remove(recvq, 1)
		end,
	}
end
package.preload["proc"] = function()
	return {
		spawn = function(src, opts)
			nextpid = nextpid + 1
			spawned[#spawned + 1] =
			    { src = src, opts = opts, pid = nextpid }
			return nextpid, 500 + nextpid
		end,
	}
end

local svc = require("svc")
local svcarg = require("svcarg")

local n, fails = 0, 0

local function ok(cond, what)
	n = n + 1
	if cond then
		print(string.format("ok %d - %s", n, what))
	else
		fails = fails + 1
		print(string.format("not ok %d - %s", n, what))
	end
end

local function run(list, granted)
	spawned = {}
	local logged = {}
	local started, skipped = svc.start(list, {
		readfile = function(p) return "-- " .. p end,
		granted = granted or {},
		log = function(m) logged[#logged + 1] = m end,
	})
	return started, skipped, logged
end

-- an array entry names the capability and calls it that in the arg.
local started = run({ { path = "/task/a.lua", caps = { "tcp" } } },
    { tcp = 42 })

ok(#started == 1, "an entry whose capability the machine has starts")
ok(spawned[1].opts.arg.tcp.__right == 42, "an array cap keeps its name")

-- a map entry names the same capability under the name the task reads.
started = run({ { path = "/task/a.lua", caps = { net = "tcp" } } },
    { tcp = 42 })

ok(spawned[1].opts.arg.net.__right == 42, "a map cap is renamed")
ok(spawned[1].opts.arg.tcp == nil, "and does not also arrive under the granted name")

-- both forms in one entry, which is what a task wanting a machine's own
-- name for one thing and its own name for another has to say.
started = run({ { path = "/task/a.lua",
    caps = { "fb", blk = "part" } } }, { fb = 7, part = 9 })

ok(spawned[1].opts.arg.fb.__right == 7, "the array half of a mixed list")
ok(spawned[1].opts.arg.blk.__right == 9, "the map half of a mixed list")

-- a missing capability is the entry's own name for it that is reported,
-- since that is what the machine was asked for.
local _, skipped, logged = run({ { path = "/task/a.lua",
    caps = { blk = "part" } } }, {})

ok(#skipped == 1, "an entry naming a capability the machine lacks is skipped")
ok(table.concat(logged, " "):find("no part capability", 1, true) ~= nil,
    "and the granted name is what the log reports")

-- optcaps rename the same way, and are never a reason to skip.
started = run({ { path = "/task/a.lua", optcaps = { net = "tcp" } } }, {})
ok(#started == 1, "a missing optcap does not skip the entry")

started = run({ { path = "/task/a.lua", optcaps = { net = "tcp" } } },
    { tcp = 42 })
ok(spawned[1].opts.arg.net.__right == 42, "a present optcap is renamed too")

-- needs: the capability has to exist, and is not handed over.
started = run({ { path = "/task/a.lua", caps = { net = "tcp" },
    needs = { "gefs" } } }, { tcp = 42, gefs = 9 })

ok(#started == 1, "an entry whose needs the machine meets starts")
ok(spawned[1].opts.arg.gefs == nil, "a needed capability is not granted")
ok(spawned[1].opts.arg.net.__right == 42, "and the granted ones still are")

_, skipped = run({ { path = "/task/a.lua", caps = { net = "tcp" },
    needs = { "gefs" } } }, { tcp = 42 })

ok(#skipped == 1, "an unmet need skips the entry")
ok(#spawned == 0, "and nothing is spawned")

-- svcarg: the spawn-arg form. Rights top level, scalars under `args`.
local m0, cfg = svcarg({ net = { __right = 42 },
    args = { root = "/n/gefs", port = 564 } })

ok(m0.net.__right == 42, "a spawn arg's rights are top level")
ok(cfg.root == "/n/gefs", "a spawn arg's scalars come from args")
ok(cfg.port == 564, "and so do its numbers")

-- svcarg: the message form. Nothing in `...`, so it takes a message,
-- where the scalars sit beside the rights.
recvq = { { net = { __right = 7 }, root = "/", port = 7777 } }
m0, cfg = svcarg(nil)

ok(m0.net.__right == 7, "a message's rights are top level too")
ok(cfg.root == "/", "a message's scalars are beside them")
ok(cfg.port == 7777, "and a task reads both the same way")

-- a service started under one name is a capability under that name to
-- whatever the list names after it.
local granted = { fb = 1 }
run({ { path = "/task/a.lua", name = "part", caps = { "fb" } },
      { path = "/task/b.lua", caps = { blk = "part" } } }, granted)

ok(spawned[2] ~= nil, "the second entry starts")
ok(spawned[2].opts.arg.blk.__right == granted.part,
    "and takes the first as a capability, under its own name for it")

print("1.." .. n)
os.exit(fails == 0 and 0 or 1)
