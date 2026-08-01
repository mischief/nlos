-- exercises the REAL namespace/mount path for virtio-9p: /lib/p9srv.lua
-- is spawned automatically at boot (kernel.c's PRIV_P9 driver, exactly
-- like cons/wire/power), granting us a "p9" capability the same way
-- espsrv.lua grants "esp" -- this mounts it with mnt.lua/ns.lua, the
-- SAME mechanism the esp already uses, and reads a real host file
-- through it. no raw 9P calls here at all; that's the point.

local sys = require("los.sys")
local stdout = require("stdout")
local ns = require("ns")
local mnt = require("mnt")

stdout.set(sys.granted().cons)

local ok = true
local caps = sys.granted()

if not caps.p9 then
	print("FAIL: no p9 capability granted (no virtio-9p device?)")
	ok = false
else
	local N = ns.new()
	local mok, merr = N:mount("/host", mnt.new(caps.p9), "mnt",
	    { port = { __right = caps.p9 } })

	if not mok then
		print("FAIL: mount failed: " .. tostring(merr))
		ok = false
	else
		print("ok: mounted virtio-9p at /host")

		local data, rerr = N:readfile("/host/hello.txt")

		if data == "hello from 9p\n" then
			print("ok: read /host/hello.txt through the mount: " ..
			    data:gsub("\n", "\\n"))
		else
			print("FAIL: read /host/hello.txt: " .. tostring(data or rerr))
			ok = false
		end

		-- a second, independent read -- proving open() really
		-- doesn't mutate the walked handle, since both reads must
		-- see the same content from independent fids.
		local data2 = N:readfile("/host/hello.txt")

		ok = ok and data2 == data
		print((data2 == data) and
		    "ok: a second independent open reads the same content" or
		    "FAIL: second open diverged")

		local ents, derr = N:readdir("/host")

		if ents then
			local names = {}

			for _, e in ipairs(ents) do
				names[#names + 1] = e.name
			end
			print("ok: /host readdir -> " .. table.concat(names, ","))
		else
			print("FAIL: readdir /host: " .. tostring(derr))
			ok = false
		end

		-- create: a new file through the mount, then read it back --
		-- both as a fresh open (proving Tcreate really wrote it, not
		-- just cached the content locally) and via readdir (proving
		-- it's a real host-visible file, not held open-only).
		local wn, werr = N:writefile("/host/created.txt", "made by lua-os\n")

		if not wn then
			print("FAIL: create /host/created.txt: " .. tostring(werr))
			ok = false
		else
			local rdata, rderr = N:readfile("/host/created.txt")

			if rdata == "made by lua-os\n" then
				print("ok: created file reads back correctly: " ..
				    rdata:gsub("\n", "\\n"))
			else
				print("FAIL: created file readback: " .. tostring(rdata or rderr))
				ok = false
			end

			local ents2 = N:readdir("/host")
			local seen = false

			for _, e in ipairs(ents2 or {}) do
				if e.name == "created.txt" then
					seen = true
				end
			end
			print(seen and "ok: created file appears in /host readdir" or
			    "FAIL: created file missing from readdir")
			ok = ok and seen
		end
	end
end

print(ok and "microvm: p9 mount test PASSED" or "microvm: p9 mount test FAILED")

sys.send(sys.granted().power, { op = "reset" })
