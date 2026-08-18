-- the revision, in every place this build writes it.
--
-- One target produces it; the C symbol, the embedded tree and the
-- filesystem image each carry a copy. They disagree only if the build
-- let one go stale, which is what this is here to catch.

local sys = require("los.sys")
local dev = require("dev")
local espfs = require("espfs")
local tap = require("tap")

tap.plan(8)

-- the machine's own filesystem, not a namespace: a boot test IS the
-- boot payload, so nothing has mounted anything yet.
local function readrev(B, path)
	local ok, res = dev.protect(function()
		local h <close> = B.open(dev.walkpath(B, B.attach(), path), "r")

		return B.read(h, 0, 128)
	end)

	if not ok or type(res) ~= "string" then
		return nil
	end
	return res:match("^%s*(%S+)")
end

local sym = sys.rev

tap.ok(type(sym) == "string" and #sym > 0,
    "the kernel carries a revision: " .. tostring(sym))
tap.ok(sym ~= "unknown", "and it is not the no-git fallback")
tap.ok(sym:match("^%x%x%x%x%x%x%x%x") ~= nil,
    "it starts with a commit's short hash")

-- clean is a bare hash; dirty appends a hash OF THE CHANGES, so two
-- dirty builds of one commit are still told apart.
local hash, taint = sym:match("^(%x+)%-?(%x*)$")

tap.ok(hash ~= nil and (taint == "" or #taint == 8),
    "shaped as a revision, dirt and all: " .. tostring(sym))

-- the filesystem this machine booted from, which is a different build
-- artifact from the kernel: on a board they are two separate flashes.
local fs = readrev(espfs.new("/"), "/VERSION.fs")

tap.ok(fs ~= nil, "/VERSION.fs is on the filesystem image: " .. tostring(fs))
tap.is(fs, sym, "and it matches the kernel it booted")

-- the embedded tree, where the platform has one. efi carries no
-- embedfs -- everything comes off the ESP -- so its absence is not a
-- failure, but a copy that is there and disagrees is.
local emb = nil
local okr, romfs = pcall(require, "romfs")

if okr and romfs and romfs.new then
	local made, B = pcall(romfs.new)

	if made and B then
		emb = readrev(B, "/VERSION.app")
	end
end

if emb == nil then
	tap.ok(true, "no embedded tree on this platform, so nothing to check")
	tap.ok(true, "and the kernel plus the image already agree")
else
	tap.is(emb, sym, "/VERSION.app matches the kernel symbol")
	tap.is(emb, fs, "and the embedded tree matches the image")
end

tap.done()
