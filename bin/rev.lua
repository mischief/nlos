-- rev: what this machine was built from, and whether the halves agree.
--
--   > rev
--   app 56dd477a-17234d5b
--   fs  56dd477a-17234d5b
--   paired

-- Flashing one partition without the other leaves old code against new
-- files, and that failure looks like anything at all. Hence a pair.

local prog = require("prog")
local sys = require("los.sys")

local N = prog.ns()

local function readrev(path)
	if not N then
		return nil
	end

	local s = N:readfile(path)

	return s and (s:match("^%s*(%S+)"))
end

-- three sources, and they are meant to be identical. The kernel's own
-- symbol answers even with nothing mounted, which is when a machine is
-- least able to say what it is and most needs to.
local sym = sys.rev
local app = readrev("/VERSION.app")
local fs = readrev("/VERSION.fs")

io.write(("app %s\n"):format(app or sym or "unknown"))
io.write(("fs  %s\n"):format(fs or "none"))

-- The embedded file disagreeing with the symbol means the kernel and
-- its own payload were built apart, which no flashing can explain.
if app and sym and app ~= sym then
	io.write(("kernel %s -- the embedded tree is not this kernel's\n")
	    :format(sym))
end

if not fs then
	io.write("no filesystem mounted, so only the app is known\n")
	os.exit(0)
end

local ref = app or sym

if ref and fs ~= ref then
	io.stderr:write("MISMATCH: the app and the filesystem are different" ..
	    " builds\n")
	io.stderr:write("flash both partitions; one alone is what makes this\n")
	os.exit(1)
end

io.write("paired\n")
os.exit(0)
