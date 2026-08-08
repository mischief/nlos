-- 9P over tcp to a real remote fileserver, serial against parallel.
--
-- This is the case the window was built for. Against virtio-9p there is
-- barely any latency to hide -- the device answers in microseconds, so
-- readparallel wins about 1.5x and most of a read is guest-side work.
-- Over tcp a round trip is milliseconds, almost all of it waiting, and
-- waiting is exactly what a second outstanding request costs nothing to
-- overlap.
--
-- Needs a server and so does not run in the ordinary suite; run it by
-- hand with NET=1 so the harness gives the guest a NIC. The target is
-- written in below rather than read from the environment: there is no
-- os library in a guest, and the payload is the whole configuration
-- channel. Skips cleanly with no tcp capability, since a build without
-- networking is the common case rather than a failure.

local sys = require("los.sys")
local captcp = require("caps.tcp")
local p9fs = require("p9fs")
local p9tcp = require("p9tcp")
local chan = require("chan")
local thread = require("los.thread")
local tap = require("tap")

local HOST = "192.168.0.150"
local PATH = "/usr/mischief/zero.bin"
local MB = 16
local BLOCK = 8168		-- ninep.MSIZE less a Tread header, as 9p(1) uses

tap.plan(5)

local granted = sys.granted()

if not tap.ok(granted.tcp ~= nil, "a tcp capability was granted") then
	tap.diag("no networking this boot; nothing to dial")
	tap.done()
	return
end

local net = captcp.new(granted.tcp)
local a, b, c, d = HOST:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

if not a then
	tap.diag("P9HOST is not dotted-quad: " .. HOST)
	tap.done()
	return
end
a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)

local CYC = sys.stats().cycles_per_ms
local results = {}

-- one connection per phase, so neither phase inherits the other's
-- server-side cache state or a half-drained socket
-- the firmware runs its own dhcp on its own clock (see
-- docs/uefi-notes.md), so the first dial after boot can land before the
-- guest has an address. Retrying is the whole fix -- there is nothing
-- to poll, since a lease arriving is not an event this side can see.
local function dial()
	local T, derr

	for _ = 1, 20 do
		T, derr = p9tcp.dial(net, a, b, c, d, 564)
		if T then
			return T
		end
		thread.sleep(500)
	end
	return nil, derr
end

local function phase(name, fn)
	local T, derr = dial()

	if not T then
		results[name] = { err = derr }
		return
	end

	local t0 = sys.ticks()
	local ok, got = pcall(fn, T)
	local ms = (sys.ticks() - t0) / CYC

	T.close()
	if ok then
		results[name] = { bytes = got, ms = ms }
	else
		results[name] = { err = got }
	end
end

-- open the file and hand back a Chan positioned at 0. p9fs is a dev
-- backend, so this is the same chan.new every other mount uses -- which
-- is the point: readparallel does not know it is talking to tcp.
local function openfile(T)
	local fs = p9fs.new(T)
	local h = fs.attach()

	for part in PATH:gmatch("[^/]+") do
		h = fs.walk(h, part)
	end
	return fs, chan.new(fs, PATH, fs.open(h, "r"))
end

-- reporting happens INSIDE this thread rather than after thread.run().
--
-- Not because anything leaks -- closing a connection DOES retire
-- p9fs's reader: net_close calls Cancel(0), which signals every
-- outstanding token's event, so recv_poll reports completion and
-- lib/tcp.lua answers the parked caller with nil. Verified directly.
--
-- It is because a phase here is slow enough to outlast the harness. At
-- ~120ms per 8K read in a guest (see the note above), 16MB serial is
-- 2055 reads and over four minutes on its own. Reporting as we go means
-- a run that gets cut short still says what it managed to measure,
-- instead of timing out with nothing but the plan line.
thread.spawn(function()
	local limit = MB * 1024 * 1024

	phase("serial", function(T)
		local _, f = openfile(T)
		local n = 0

		while n < limit do
			local blk = f:read(BLOCK)

			if not blk or blk == "" then
				break
			end
			n = n + #blk
		end
		return n
	end)

	for _, w in ipairs({ 4, 16, 64 }) do
		phase("par" .. w, function(T)
			local _, f = openfile(T)
			local n = 0

			for blk in f:readparallel(w, BLOCK) do
				n = n + #blk
				if n >= limit then
					break
				end
			end
			return n
		end)
	end

		local function report(name, label)
		local r = results[name]

		if not r or r.err then
			tap.diag(label .. ": " .. tostring(r and r.err or "not run"))
			return nil
		end
		tap.diag(string.format("%-14s %8.1f ms for %d bytes (%.2f MB/s)",
		    label, r.ms, r.bytes, (r.bytes / 1048576) / (r.ms / 1000)))
		return r
	end

	local s = report("serial", "serial")

	tap.ok(s ~= nil and s.bytes > 0, "read " .. MB .. "MB serially over tcp")

	local best

	for _, w in ipairs({ 4, 16, 64 }) do
		local r = report("par" .. w, "readparallel(" .. w .. ")")

		if r and (not best or r.ms < best.ms) then
			best = r
		end
	end

	tap.ok(best ~= nil, "read the same bytes with a window")
	tap.ok(best and s and best.bytes == s.bytes,
	    "the windowed reads returned the same byte count")

	if best and s then
		tap.diag(string.format("best speedup: %.2fx", s.ms / best.ms))
	end
	tap.ok(best and s and best.ms < s.ms,
	    "a window beats serial over tcp, where the latency is worth hiding")

	tap.done()
end)
thread.run()
