#!/usr/bin/env lua5.4
-- mkgefs.lua OUTPUT [size] [user] -- ream a gefs volume with one file in
-- it, for the build to drop into a disk partition. The single file is
-- enough to prove, later, that a firmware-booted guest read the gefs
-- partition rather than an empty one; a real root fills it in.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local gefs = require "gefs"

local out = arg[1] or error("usage: mkgefs.lua OUTPUT [size] [user]", 0)
local size = tonumber(arg[2]) or (48 * 1024 * 1024)
local user = arg[3] or "glenda"

local dev = assert(gefs.io.create(out, size))
gefs.ream(dev, { user = user })

local fs = gefs.open(dev)
local m = fs:mount("main")
m:createfile("/README")
m:writefile("/README", "hello from a gefs partition\n")
fs:sync()
dev:close()

io.write(("reamed %s: %d bytes, user %s, one file\n"):format(out, size, user))
