# writing a program that draws

What a panel app has to get right, and what the machine already does
for it. `bin/gpsui.lua` is the worked example; `task/dio.lua` is what
hands it a window, a pointer and an event port.

## pixels stay on the far side

A message will not carry a screen. The draw server keeps images and an
app names them: `fb.alloc` gives back an id, `fb.load` fills it once,
and `fb.draw` afterwards is a few bytes naming what to put where. A
picture drawn twice should cross the port once.

That shapes the design more than anything else here. Decide how many
distinct pictures the program can show, keep them server-side, and make
everything else a message. Sixteen positions of a rotating globe is a
small enough set to hold and a fine enough step to read.

Build the ones a user is about to want while nothing is waiting. What
that costs is a background render, and a background render yields.

## a background render must not borrow a global

A build that yields per row lets the panel keep answering, which is the
point of it. It also means anything the program holds in a module-level
variable may be somebody else's by the next row.

So a routine that draws position N takes N as an argument. Setting a
shared `step` around the call and putting it back afterwards looks
equivalent and is not: the value put back is the one from before the
yield, and a turn that arrived in between is thrown away. The steps a
prefetch builds are exactly the ones the next input moves to, so this
is the case that always loses rather than a rare one.

## the pointer is state, its buttons are edges

A record is `m` and four fixed-width fields -- x, y, buttons, and a
millisecond clock -- 49 bytes, and the width is the framing rule.
`lib/mouse.lua` formats and parses them.

Positions may be dropped. A reader that has fallen behind wants where
the pointer is, not where it has been, so the platform layer coalesces
motion and hands over the latest.

Button transitions may not. A press and a release inside one poll
window are the whole of a click, and reporting the state they left
behind reports that nothing happened. Every edge is queued and handed
over one at a time. An app dispatches on the press edge -- `pressed and
not down` -- which only works if the press was ever delivered.

The bits are plan 9's:

	1, 2, 4     the three buttons
	8, 16       wheel up, wheel down
	32, 64      wheel left, wheel right

A wheel notch is two edges with one position: the bit set, then clear.
It is not a state anything holds.

## who a record belongs to

`dio` routes by position for the tray and by focus for everything else.
A wheel record goes to the app in front, never to whatever the pointer
happens to be over: on a panel the pointer is where a finger last was,
and nothing hovers.

An app gets its own pointer port, its own event port and its own
framebuffer right. A port carries no sender identity, so per-app ports
are what make focus mean anything.

## a flick is not a notch

A trackball sends a burst of records for one roll. A detented wheel
sends one record per notch. A step for each record spins a trackball
app half way round; one step per fixed interval throttles a wheel to
whatever that interval allows.

Gate on the quiet between records instead. A burst is records that keep
arriving; a notch arrives alone. That is the property that actually
separates the two devices, and it needs no flag saying which is fitted.

## a sleeping loop sets your input latency

A redraw loop that parks for a period answers input in that period. A
notch that sets a flag waits out whatever is left of the second.

Sleep in slices and stop early when there is something to draw. The
slice is the worst case a user feels; the period is only how often the
clock and the data get a pass.

## hosted quirks worth knowing

SDL already maps mouse events through the renderer's logical size
before delivering them, so what arrives is in the guest's coordinates
already. Do not transform again. The mistake is invisible while the
window is the size of the screen, where the second transform is the
identity, and shows up the moment anything letterboxes.

Points in the letterbox bars are outside the screen and clamp to its
edge.

## measure it, do not look at it

A quarter turn of a globe is unmistakable. One sixteenth is not, and
guessing from two screenshots is how a working change gets reverted and
a broken one gets shipped.

The hosted build under a virtual X server takes synthetic input and
gives back a number:

	Xvfb :98 -screen 0 1024x768x24 &
	DISPLAY=:98 SDL_VIDEODRIVER=x11 \
	    build-hosted/src/platform/hosted/luaos-hosted --gui -r "$PWD" \
	    -p /init.lua &

	DISPLAY=:98 xdotool mousemove 500 400
	DISPLAY=:98 import -window root before.png
	DISPLAY=:98 xdotool click 4            # 4 and 5 are the wheel
	DISPLAY=:98 import -window root after.png
	compare -metric AE -fuzz 5% before.png after.png null:

A turn of one step changes on the order of 10^5 pixels. A clock ticking
changes tens. The gap between those two numbers is the whole answer,
and it is the same command whether the question is did anything happen,
did the right amount happen, or did two turns and two back come home.

`magick ... -format %c histogram:info:-` lists what colors are on the
screen. A program that draws from a fixed palette should show that
palette and nothing else; a stray color is corruption, and no stray
color means what looks wrong is something the program meant to draw.

Timing works the same way. Grab a frame immediately after the input
rather than after a sleep: if the new frame is already there, the
latency is under the time a screen grab takes.

`xdotool click` presses and releases about 12ms apart, which is faster
than a hand. Use `mousedown`, a sleep, then `mouseup` to imitate a real
click, and the fast form to see what happens to input that arrives
faster than the machine polls.

## a precomputed table is not free

Lua rounds a table's array part up to a power of two, and every slot is
a full value. 1983 entries occupy 2048 slots of sixteen bytes, so one
array of them is 32KB and seven parallel arrays are 230KB. Measured in
the machine rather than reasoned about:

	collectgarbage()
	local b = sys.meminfo()
	-- build the tables here
	collectgarbage()
	print(sys.meminfo() - b)

Precompute what is expensive, not what is merely repeated. A square
root is worth a table on a chip with no double precision in hardware; a
multiply, a compare against a row's width, or the loop counter itself
is not. Deriving six of seven arrays and keeping only the square root
halved a panel app, from 1000403 bytes live to 501394, and left the
picture identical to the pixel.

`ps` gives every proc's live and peak bytes, so the question "where did
it go" has an answer that does not need guessing.

## a return does not end the program

`thread.run()` returns when every thread has finished. A panel app
spawns one to drain the pointer port, and that one is parked on a port
forever -- so returning from the event loop leaves the proc up with
nothing driving it. The window stays, the tray still counts it as
running, and the key that was supposed to quit did nothing anyone can
see.

Quit with `os.exit(0)`, in the hangup case as well as the keystroke.
The launcher is where to check: it marks an entry "(1 running)", which
is the only place the difference shows.

## a menu is how a small screen says what it can do

Keys are invisible, and a row of buttons is the width the content
wanted. `lib/menu.lua` is the other answer: one square in the corner,
and a list that covers the page while it is up and is gone the moment
it is answered. Each row shows the key that does the same thing, so the
menu teaches the shortcut rather than replacing it.

It draws through two primitives the caller passes -- fill a rectangle,
put a string somewhere -- and holds only the geometry and what a point
or a key means. That half needs no framebuffer, so it is tested on the
host.

Closing one costs a full redraw: nothing keeps a copy of what was
underneath. Check that with a pixel count -- the frame after a dismiss
should equal the frame from before the menu opened, exactly.
