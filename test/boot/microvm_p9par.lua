-- Chan:readparallel -- a single reader keeping several reads in flight.
--
-- The window under lib/mnt.lua only does anything when several requests
-- reach the server at once, and one thread calling read() in a loop
-- never produces that. This is what turns one caller into several
-- in-flight requests, so this test is where "the fan-out is actually
-- used" is established rather than assumed.
--
-- Checked against the same file read serially: same bytes, same order,
-- same length. The blocks carry their own indices (see
-- scripts/boottest-microvm.lua), so a block delivered out of order
-- fails on content rather than on a count.

local sys = require("los.sys")
local ns = require("ns")
local mnt = require("mnt")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(7)

local caps = sys.granted()

if not tap.ok(caps.p9 ~= nil, "a p9 capability was granted") then
	tap.done()
	return
end

local N = ns.new()
local mok, merr = N:mount("/host", mnt.new(caps.p9), "mnt",
    { port = { __right = caps.p9 } })

if not tap.ok(mok, "mounted virtio-9p at /host") then
	tap.diag("mount failed: " .. tostring(merr))
	tap.done()
	return
end

local want = assert(N:readfile("/host/blocks.bin"), "serial read failed")

tap.ok(#want > 0, "read blocks.bin serially: " .. #want .. " bytes")

-- ---- at the top level of a proc ----
--
-- no scheduler is running here, so readparallel has to drive one
-- itself. This is the context a plain script is in.

local function collect(f, window, blocksize)
	local parts = {}

	for block, err in f:readparallel(window, blocksize) do
		if not block then
			return nil, err
		end
		parts[#parts + 1] = block
	end
	return table.concat(parts)
end

local f = assert(N:open("/host/blocks.bin", "r"))
local got, gerr = collect(f, 8, 4096)

f:close()
if not tap.ok(got == want, "readparallel(8) at top level matches the serial read") then
	tap.diag("got " .. tostring(got and #got or gerr) .. ", wanted " .. #want)
end

-- a window wider than the file has blocks, so the first group runs
-- past eof and every thread past it must come back empty
local f2 = assert(N:open("/host/blocks.bin", "r"))
local big = collect(f2, 128, 4096)

f2:close()
tap.ok(big == want, "a window wider than the file still stops at eof")

-- a block size that does not divide the file, so the last block is
-- short -- which must end the file without truncating it
local f3 = assert(N:open("/host/blocks.bin", "r"))
local odd = collect(f3, 8, 3000)

f3:close()
if not tap.ok(odd == want, "an uneven block size reads the whole file") then
	tap.diag("got " .. tostring(odd and #odd) .. ", wanted " .. #want)
end

-- ---- inside a thread ----
--
-- the other half of runjoin: a scheduler is already running, so
-- readparallel must park on a channel instead of starting a second one.
-- Two readers at once, because that is the case where a nested
-- thread.run() would drive the same run queue from two places.

local r1, r2

thread.spawn(function()
	local g = assert(N:open("/host/blocks.bin", "r"))

	r1 = collect(g, 8, 4096)
	g:close()
end)
thread.spawn(function()
	local g = assert(N:open("/host/blocks.bin", "r"))

	r2 = collect(g, 8, 4096)
	g:close()
end)
thread.run()

tap.ok(r1 == want and r2 == want,
    "two concurrent readparallel(8) readers inside threads both match")

tap.done()
