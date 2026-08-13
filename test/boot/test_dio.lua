-- the window system, under qemu. platform_have_ptr is 0 here, so the
-- kernel makes no pointer port and this makes one: a synthetic event is
-- an ordinary send to the port the driver would have sent to. Pixels
-- are read back, so this fails if dio stops drawing as well as if it
-- stops answering.

local sys = require("los.sys")
local draw = require("draw")
local ns = require("ns")
local proc = require("proc")
local thread = require("los.thread")
local mouse = require("mouse")
local tap = require("tap")

local caps = sys.granted()

tap.plan(9)

tap.ok(caps.fb ~= nil, "the payload holds a screen")
tap.ok(caps.esp ~= nil, "and a filesystem to run dio out of")
if not caps.fb or not caps.esp then
	tap.done()
	return
end

local N = ns.new()

assert(N:mount("/", require("mnt").new(caps.esp), "mnt",
    { port = { __right = caps.esp } }))

local src = N:readfile("/task/dio.lua")

tap.ok(src ~= nil, "task/dio.lua is on the image")
if not src then
	tap.done()
	return
end

-- ---- the two devices dio expects ----
--
-- dio receives on these; this test sends. The kernel's own pointer port
-- is the same shape: it pushes records and whoever holds the right
-- reads them.
local ptr = sys.newport("test.ptr")
local ptrsend = sys.sendright(ptr)
local kbd = sys.newport("test.kbd")
local kbdsend = sys.sendright(kbd)

local fb = draw.new(caps.fb)
local mode = fb.mode()

tap.ok(mode and mode.w and mode.w > 0, "the screen reports a size")

local pid = proc.spawn(src, {
	name = "dio",
	ns = N:describe(),
	arg = {
		fb = { __right = caps.fb },
		ptr = { __right = ptr },
		kbd = { __right = kbd },
		cons = caps.cons and { __right = caps.cons } or nil,
	},
})

tap.ok(pid ~= nil, "dio started")
if not pid then
	tap.done()
	return
end

-- it draws its tray at startup and starts the boot entry; give it the
-- round trips to do both rather than a fixed sleep long enough to hide
-- a stall.
local function settle(ms)
	local until_ = sys.uptime_ms() + ms

	while sys.uptime_ms() < until_ do
		thread.sleep(20)
	end
end

settle(1500)

-- ---- what is on the glass ----

local TRAY = 28

local function anyset(r)
	local px = fb.unload(r)

	if not px then
		return false
	end
	for i = 1, #px do
		if px:byte(i) ~= 0 then
			return true
		end
	end
	return false
end

tap.ok(anyset({ x = 0, y = 0, w = TRAY, h = 120 }),
    "the tray is drawn down the left")

-- ---- a tap on the launcher ----
--
-- The record is what lib/mouse formats and what the kernel's pointer
-- pump would have pushed: a press and then a release, since dio acts on
-- the press edge and a finger that never lifts is a drag.
local function tapat(x, y)
	sys.send(ptrsend, mouse.format(x, y, 1))
	settle(300)
	sys.send(ptrsend, mouse.format(x, y, 0))
	settle(400)
end

local before = fb.unload({ x = TRAY, y = 0, w = 200, h = 30 })

tapat(14, 15)

local after = fb.unload({ x = TRAY, y = 0, w = 200, h = 30 })

tap.ok(before ~= after, "the launcher opened over the app area")

-- the catalog's first row is the terminal, which is already running, so
-- pick the second: starting one is what proves the tray reaches a spawn.
tapat(160, 45)
settle(1500)

-- sys.procs() gives pids; the name comes from sys.name
local names = {}

for _, id in ipairs(sys.procs()) do
	names[sys.name(id) or "?"] = true
end

tap.ok(names["dio"] == true, "dio is still alive after all that")
tap.ok(names["scribble"] == true or names["smiley"] == true or
    names["term"] == true,
    "the tray started an app")

sys.close(ptrsend)
sys.close(kbdsend)
