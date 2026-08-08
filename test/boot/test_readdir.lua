-- los.fs: directory enumeration and metadata over the real ESP.
-- this is what a namespace needs before it can route anything, and it
-- is the first time anything here could list a directory at all.
local fs = require("los.fs")
local tap = require("tap")

tap.plan(10)

-- ---- the root ----
local root, err = fs.readdir("/")

tap.ok(root ~= nil, "readdir / succeeds (" .. tostring(err) .. ")")

local byname = {}
for _, e in ipairs(root or {}) do
	byname[e.name] = e
end

tap.ok(byname["init.lua"] ~= nil, "root lists init.lua")
tap.ok(byname["lib"] ~= nil, "root lists lib")
tap.ok(byname["lib"] and byname["lib"].dir == true, "lib is flagged a directory")
tap.ok(byname["init.lua"] and byname["init.lua"].dir == false,
    "init.lua is not flagged a directory")
tap.ok(byname["init.lua"] and byname["init.lua"].size > 0,
    "init.lua has a nonzero size (" ..
    tostring(byname["init.lua"] and byname["init.lua"].size) .. ")")

-- ---- a subdirectory, and it is not empty ----
local lib = fs.readdir("/lib")
local found = 0
for _, e in ipairs(lib or {}) do
	if e.name == "srv.lua" or e.name == "ninep.lua" then
		found = found + 1
	end
end
tap.ok(found == 2, "readdir /lib finds srv.lua and ninep.lua")

-- ---- stat agrees with readdir ----
local st = fs.stat("/init.lua")

tap.ok(st ~= nil and st.dir == false and st.size == byname["init.lua"].size,
    "stat /init.lua agrees with the listing")

-- ---- errors are values, not crashes ----
local bad, berr = fs.readdir("/no-such-directory")

tap.ok(bad == nil and type(berr) == "string",
    "readdir of a missing path returns nil + reason")

-- reading a plain file as a directory must fail cleanly rather than
-- returning byte soup as entries
local notdir = fs.readdir("/init.lua")

tap.ok(notdir == nil, "readdir of a plain file returns nil, not garbage")

tap.done()
