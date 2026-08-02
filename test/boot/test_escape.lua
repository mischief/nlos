-- can a proc with only a mem namespace get back out?
--
-- the child below is spawned with a namespace containing one in-memory
-- tree and nothing else. it should not be able to read the ESP, reach a
-- driver, or recover any C function that would let it.

-- The preempt hook is the other thing a proc must not be able to take
-- off; that is test/boot/test_nohook.lua, same re-strip hazard.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local ns = require("ns")
local tap = require("tap")

tap.plan(13)

local Jail = ns.new()

Jail:mount("/", dev.mem({ ["only.txt"] = "nothing else here\n" }), "mem",
    { tree = { ["only.txt"] = "nothing else here\n" } })

local rp = sys.newport()

require("proc").spawn([[
local sys = require("los.sys")
local out = {}
local myreply = (...).__right	-- do not probe our own reply channel

local function try(name, fn)
	local ok, res = pcall(fn)

	out[name] = ok and (res == nil and "nil" or tostring(res))
	    or ("ERR " .. tostring(res))
end

-- 0. sanity: the jail itself works
try("jail", function()
	return require("ns").current():readfile("/only.txt")
end)

-- 1. the lazy-library reopen. _G has an __index that luaL_requiref's a
-- fresh copy of io/debug/etc on a miss, and requiref only reuses when
-- package.loaded[name] is truthy. clear BOTH and the opener runs again.
try("relazy_io", function()
	package.loaded.io = nil
	_G.io = nil
	local f = io.open("/init.lua", "r")	-- a real ESP file

	if not f then
		return "open returned nil"
	end
	local d = f:read(16)

	f:close()
	return "READ " .. tostring(d and #d)
end)

-- 2. the same trick against the other lazy libs, to confirm the
-- re-strip is targeted rather than breaking them
try("relazy_others", function()
	package.loaded.table = nil
	_G.table = nil
	package.loaded.debug = nil
	_G.debug = nil
	return tostring(table.concat({ "a", "b" })) .. "/" ..
	    tostring(debug ~= nil)
end)

-- 3. is the raw esp module reachable by name?
try("los_fs", function()
	return require("los.fs")
end)

-- 4. loadfile / dofile
try("loadfile", function() return loadfile("/init.lua") end)
try("dofile", function() return dofile("/init.lua") end)

-- 5. os library (never opened at all)
try("os", function() return os.remove end)

-- 6. debug: registry and upvalue extraction
try("registry", function()
	local r = debug.getregistry()
	local n = 0

	for _ in pairs(r) do n = n + 1 end
	return "entries " .. n
end)

-- pull upvalues out of every loaded module's functions, looking for a
-- C function we should not have
try("upvalue_scan", function()
	local found = {}

	for mname, mod in pairs(package.loaded) do
		if type(mod) == "table" then
			for k, v in pairs(mod) do
				if type(v) == "function" then
					local i = 1

					while true do
						local un, uv = debug.getupvalue(v, i)

						if not un then break end
						if type(uv) == "function" and
						    debug.getinfo(uv, "S").what == "C" then
							found[#found + 1] =
							    mname .. "." .. tostring(k) ..
							    ":" .. un
						end
						i = i + 1
					end
				end
			end
		end
	end
	return #found .. " C upvalues: " ..
	    table.concat(found, ",", 1, math.min(#found, 4))
end)

-- 7. can it reach a driver by guessing handles?
try("handle_guess", function()
	local hits = 0

	for h = 0, 20 do
		if h ~= myreply and
		    pcall(function() return sys.send(h, { probe = true }) end) then
			hits = hits + 1
		end
	end
	return "sendable handles " .. hits .. " (reply is " .. myreply .. ")"
end)

-- 8. what does a GRANDCHILD get? it is spawned by us with no namespace.
try("grandchild", function()
	return tostring(sys.granted() and next(sys.granted()))
end)

-- 9. firmware
try("efi", function()
	local efi = require("los.efi")

	return "locate=" .. tostring(efi.locate(
	    "964e5b22-6459-11d2-8e39-00a0c969723b"))	-- SimpleFileSystem
end)

sys.send((...).__right, out)
]], { name = "jailbird", ns = Jail:describe(), arg = { __right = rp } })

local r = thread.recvtimeout(rp, 8000)

local keys = {}

for k, v in pairs(r or {}) do
	keys[#keys + 1] = k .. "=" .. tostring(v)
end
table.sort(keys)
tap.ok(r ~= nil, "child reported: " .. table.concat(keys, " | "))
r = r or {}

tap.is(r.jail, "nothing else here\n", "its own namespace works")

tap.ok(tostring(r.relazy_io):find("ERR") or r.relazy_io == "open returned nil",
    "ESCAPE CHECK relazy_io: " .. tostring(r.relazy_io))
tap.ok(tostring(r.los_fs):find("ERR"),
    "los.fs is not reachable: " .. tostring(r.los_fs))
tap.ok(tostring(r.loadfile):find("ERR"),
    "loadfile is gone: " .. tostring(r.loadfile))
tap.ok(tostring(r.dofile):find("ERR"),
    "dofile is gone: " .. tostring(r.dofile))
-- os is never opened at all (see src/linit.c), and reading an unbound
-- global raises there, so naming it is already the error -- earlier
-- than the index that used to produce it, and saying which name.
tap.ok(tostring(r.os):find("undefined global 'os'") ~= nil,
    "os library absent entirely: " .. tostring(r.os))
tap.ok(tostring(r.handle_guess):find("^sendable handles 1 ") ~= nil,
    "only its own port is sendable: " .. tostring(r.handle_guess))
tap.is(r.grandchild, "nil", "it is granted nothing: " .. tostring(r.grandchild))

-- these are informational, not necessarily failures
tap.is(r.relazy_others, "ab/true",
    "the other lazy libs still reopen normally: " .. tostring(r.relazy_others))
tap.ok(r.registry ~= nil, "debug.getregistry: " .. tostring(r.registry))
tap.ok(r.upvalue_scan ~= nil, "upvalue scan: " .. tostring(r.upvalue_scan))
tap.ok(r.efi ~= nil, "los.efi.locate: " .. tostring(r.efi))

tap.done()
