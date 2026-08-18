-- dio: hand the machine to the window system, and take it back.
--
--	> dio		escape leaves
--
-- task/dio.lua wants a keyboard port; a program holds a console. This
-- reads the one into the other, and is not a second window system --
-- so it stops calling itself dio, and the window system keeps the name
-- it has on a machine that starts one for itself.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local proc = require("proc")

local N = prog.ns()
local fb = prog.screen()
local tty = prog.tty()
local ctx = prog.ctx
local ptr = ctx and ctx.ptr
local rand = prog.rand()

local function die(s)
	io.stderr:write("dio: " .. s .. "\n")
	os.exit(1)
end

if not fb then
	die("no screen on this machine")
end
if not ptr then
	die("no pointer on this machine")
end
if not N then
	die("no namespace")
end

-- dio's keyboard, which this fills from the console. It is a port
-- because that is what dio reads; the keys in it are this program's,
-- lent for as long as it runs.
-- dos named this proc after what was typed, which is the name the
-- window system is about to want.
sys.name("dio.keys")

local kbd = sys.newport("dio.kbd")
local kbdsend = sys.sendright(kbd)

local pid, ctl = proc.start("/task/dio.lua", {
	fb = { __right = ctx.fb },
	ptr = { __right = ptr },
	kbd = { __right = kbd },
	-- our own stderr as its console: dio says what went wrong
	-- with {op="write"}, which is what a stream takes, and
	-- without one its failures go nowhere.
	cons = ctx.stderr and { __right = ctx.stderr.h } or nil,
	-- what this program was lent, lent onward: dio hands it to
	-- each terminal it starts, so a shell on the glass reaches
	-- the same stack as the shell that typed "dio".
	tcp = ctx.net and { __right = ctx.net } or nil,
	ip = ctx.udp and { __right = ctx.udp } or nil,
	dns = ctx.dns and { __right = ctx.dns } or nil,
	power = ctx.power and { __right = ctx.power } or nil,
	seed = rand and rand(32) or nil,
}, { name = "dio" })

if not pid then
	die(tostring(ctl))
end

-- said on the way in, because the screen may not be where this is
-- typed: on a qemu run the window is elsewhere and the shell is here.
io.stderr:write("dio: the screen is the window system now; " ..
    "escape returns to dos\n")

-- raw, or the console hands over lines and a tray never sees a key
if tty then
	tty.rawon()
end

-- dio has no notion of leaving: on the board there is nowhere to leave
-- to. So this program is what ends it.
local ESC = "\27"

while true do
	local k = tty and tty.getch() or nil

	if k == nil or k == ESC then
		break
	end
	-- a full port drops: dio is not reading its keys fast enough,
	-- and a keystroke waited on would stall this loop behind it.
	sys.send(kbdsend, k)
end

if tty then
	tty.rawoff()
end

-- dio's apps go with it: they wait on ports it held, and a dead holder
-- is a hangup to everything parked on one.
pcall(sys.kill, ctl)
sys.close(kbdsend)
sys.close(kbd)

local mode = fb.mode()

if mode then
	fb.fill({ x = 0, y = 0, w = mode.w, h = mode.h }, 0x000000, true)
	fb.sync()
end
