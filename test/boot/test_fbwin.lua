-- a window is a session over an image, and the right to it is the
-- grant. This is what lets a window manager stop forwarding pixels: it
-- allocates the image, hands out a session on it, and after that says
-- only where the window sits.

local sys = require("los.sys")
local draw = require("draw")
local memdraw = require("memdraw")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(11)

tap.ok(caps_of.fb ~= nil, "boot payload was granted fb")
if not caps_of.fb then
	tap.done()
	return
end

local fb = draw.new(caps_of.fb)
local screen = fb.mode()

-- ---- the manager's side ----

local W, H = 64, 48
local AT = { x = 120, y = 60 }
local win = fb.alloc(W, H, nil, memdraw.blue)
local app = fb.session(win)

tap.ok(app ~= nil, "a session over an image is a window")

-- ---- the app's side ----
--
-- it never learns an id for its own window: absent means the window,
-- exactly as absent meant the glass before.

local m = app.mode()

tap.is(m.w, W, "a window's client is told the window's width")
tap.is(m.h, H, "and its height, not the screen's")

fb.fill(memdraw.rect(0, 0, screen.w, screen.h), memdraw.red, true)
fb.place(win, AT, true, true)

local at = memdraw.fromBytes(W, H, fb.unload(memdraw.rect(AT.x, AT.y, W, H)))

tap.is(memdraw.at(at, 0, 0), memdraw.blue,
    "placing it puts the whole window on the glass")

-- a fill with no id lands in the window, offset to where it was placed
app.fill(memdraw.rect(0, 0, 8, 8), memdraw.green, true)

local got = memdraw.fromBytes(W, H, fb.unload(memdraw.rect(AT.x, AT.y, W, H)))

tap.is(memdraw.at(got, 0, 0), memdraw.green,
    "and a fill inside it reaches the glass at the placed corner")
tap.is(memdraw.at(got, 63, 47), memdraw.blue,
    "without disturbing the rest of the window")

-- ---- and it cannot reach past its own edges ----

local outside = memdraw.rect(0, 0, 16, 16)

fb.fill(outside, memdraw.red, true)
app.fill(memdraw.rect(-200, -200, 8, 8), memdraw.green, true)

local corner = memdraw.fromBytes(16, 16, fb.unload(outside))

tap.is(memdraw.at(corner, 0, 0), memdraw.red,
    "a fill outside the window does not reach the glass at all")

local nope, err = app.unload(memdraw.rect(0, 0, 8, 8))

tap.ok(not nope and tostring(err):find("not a window"),
    "and it cannot read the screen either: " .. tostring(err))

local moved, merr = app.place(nil, { x = 0, y = 0 }, true, true)

tap.ok(not moved and tostring(merr):find("not a window"),
    "nor move itself: where a window sits is the manager's to say")

-- an offscreen image of its own still works, and stays offscreen
local off = app.alloc(8, 8, nil, memdraw.red)

app.fill(memdraw.rect(0, 0, 8, 8), memdraw.green, true, off)

local edge = memdraw.fromBytes(W, H, fb.unload(memdraw.rect(AT.x, AT.y, W, H)))

tap.is(memdraw.at(edge, 0, 0), memdraw.green,
    "an image of its own is not its window")

tap.done()
