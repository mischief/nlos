-- One mount right, restored more than once.
--
-- A namespace description names a server by a right, and restoring it
-- twice gives two mounts talking to one server. Each opens a session of
-- its own, so each has a fid space of its own -- and a walk in one must
-- not depend on what the other has done.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local mnt = require("mnt")
local tap = require("tap")

tap.plan(10)

local SERVER = [[
local dev = require("dev")
local devtree = require("devtree")
local srv = require("srv")

srv.main(function()
	return devtree.mem({
		hello = "hello\n",
		bin = { echo = "echo program\n" },
	})
end)
]]

local pid, h = sys.spawn(SERVER, { name = "mntshare.srv" })

tap.ok(pid ~= nil, "the server is up")

local N0 = ns.new()

N0:mount("/", mnt.new(h), "mnt", { port = { __right = h } })

local desc = N0:describe()

tap.is(#desc, 1, "one mount in the description")

-- ---- the first restore ----

local A = ns.restore(desc)
local ents = A:readdir("/")
local names = {}

for _, e in ipairs(ents or {}) do names[#names + 1] = e.name end
table.sort(names)
tap.is(table.concat(names, " "), "bin hello", "A lists the root")

local t, err = A:readfile("/bin/echo")

tap.is(t, "echo program\n", "A walks into it: " .. tostring(err))

-- ---- the second restore, of the very same description ----

local B = ns.restore(desc)
local ents2 = B:readdir("/")
local names2 = {}

for _, e in ipairs(ents2 or {}) do names2[#names2 + 1] = e.name end
table.sort(names2)
tap.is(table.concat(names2, " "), "bin hello", "B lists the same root")

local t2, err2 = B:readfile("/bin/echo")

tap.is(t2, "echo program\n", "B walks into it too: " .. tostring(err2))

-- and A still works after B exists: one mount's session must not be
-- disturbed by another opening its own
local t3, err3 = A:readfile("/bin/echo")

tap.is(t3, "echo program\n", "A still walks after B: " .. tostring(err3))

-- ---- readdir first, then walk, on a cold third mount ----

local C = ns.restore(desc)

tap.ok(C:readdir("/") ~= nil, "C lists the root first")

local t4, err4 = C:readfile("/bin/echo")

tap.is(t4, "echo program\n", "and then walks: " .. tostring(err4))

-- ---- walk first, on a cold fourth mount ----

local D = ns.restore(desc)
local t5, err5 = D:readfile("/bin/echo")

tap.is(t5, "echo program\n", "a cold mount walks with no readdir first: " ..
    tostring(err5))

