-- term: start a terminal on the panel, in a proc of its own.
--
--	> term
--
-- For a board whose services start no window system. It returns at
-- once: the panel gets its own shell and this console keeps the one it
-- had, so the serial line stays usable.

local prog = require("prog")
local sys = require("los.sys")
local proc = require("proc")

local ctx = prog.ctx
local fb = ctx and ctx.fb
local kbd = ctx and ctx.kbd
local cons = ctx and ctx.stdout and ctx.stdout.h

if not fb then
	io.stderr:write("term: no screen on this machine\n")
	os.exit(1)
end
if not kbd then
	io.stderr:write("term: no keyboard on this machine\n")
	os.exit(1)
end

-- what the shell was lent goes on, so a program run on the panel
-- reaches the same network this one would.
local pid, right = proc.start("/task/fbterm.lua", {
	fb = { __right = fb },
	kbd = { __right = kbd },
	cons = cons and { __right = cons } or nil,
	tcp = ctx.net and { __right = ctx.net } or nil,
	ip = ctx.udp and { __right = ctx.udp } or nil,
	dns = ctx.dns and { __right = ctx.dns } or nil,
	power = ctx.power and { __right = ctx.power } or nil,
	seed = prog.rand() and prog.rand()(32) or nil,
}, { name = "fbterm" })

if not pid then
	io.stderr:write("term: " .. tostring(right) .. "\n")
	os.exit(1)
end
sys.close(right)
print("term: pid " .. pid)
