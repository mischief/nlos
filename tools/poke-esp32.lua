#!/usr/bin/env lua5.4
-- poke-esp32.lua PORT ACTION... -- drive a board's panel from the host.
--
--	HOSTUTIL_SO=build/hostutil.so lua5.4 tools/poke-esp32.lua \
--	    /dev/ttyACM0 tap 14,40 sleep 1 shot /tmp/after.ppm
--
-- Actions run in order over one serial session, so a sequence of
-- touches and screenshots is one command and one connection. The port
-- must be free: a picocom on the same line takes the bytes this is
-- waiting for, and a second opener can reset the board.
--
-- What the actions do is in tools/hostpanel.lua, including why
-- injecting a touch needs nothing in the kernel: the pointer and the
-- keyboard are ports, and a synthetic event is an ordinary send to the
-- same port the driver pushes to.
--
--	move X,Y            the pointer, no button
--	tap X,Y             press and release, which is a touch
--	press X,Y           down and stay down
--	release X,Y         up
--	drag X0,Y0 X1,Y1    a stroke, button held along the way
--	wheel up|down|left|right [N]
--	                    the wheel, or a T-Deck's trackball
--	type TEXT           keystrokes at the panel's keyboard
--	key NAME            enter, esc, tab, backspace, space, intr
--	run LUA             one line at the serial repl
--	ask LUA             the same, and print what comes back
--	sh CMD              a command line at the shell, and its output
--	shot FILE [ROWS]    read the screen back as a netpbm
--	push FILE [DIR]     send a file to the flash volume, /bin by
--	                    default -- an edit without a reflash
--	sleep SECONDS       wait

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/?.lua;" .. scriptdir .. "/../lib/?.lua;" ..
    package.path

local hostpanel = require("hostpanel")

local function die(msg)
	io.stderr:write("poke: " .. msg .. "\n")
	os.exit(1)
end

local function usage()
	io.stderr:write((io.open(arg[0]):read("a"):gsub("^#![^\n]*\n", "")
	    :gsub("\n[^-].*$", "")))
	os.exit(2)
end

local function point(s)
	local x, y = tostring(s):match("^(%-?%d+),(%-?%d+)$")

	if not x then
		die("cannot read a point from " .. tostring(s))
	end
	return tonumber(x), tonumber(y)
end

local port = arg[1]

if not port or port:sub(1, 1) == "-" then
	usage()
end

local p = hostpanel.open(port)

-- A bare line first: the console may be mid-line from whatever last
-- touched this port, and a stray prompt beats a command joined onto
-- somebody's half-typed one. Which prompt each action wants is the
-- action's own business.
-- and back to the shell: the board keeps whatever prompt the last
-- session left, so a new one cannot assume which it is at.
p:say("")
p:todos()

-- what a word may be instead of an argument, so an optional one knows
-- where it ends.
local actions = {}

for _, a in ipairs({ "move", "tap", "press", "release", "drag", "wheel",
    "type", "key", "run", "ask", "sh", "shot", "push", "cancel", "sleep" }) do
	actions[a] = true
end

local i = 2

local function next_arg(what)
	i = i + 1
	if not arg[i] then
		die("missing " .. what)
	end
	return arg[i]
end

while i <= #arg do
	local a = arg[i]

	if a == "move" then
		p:move(point(next_arg("X,Y")))
	elseif a == "tap" then
		p:tap(point(next_arg("X,Y")))
	elseif a == "press" then
		p:press(point(next_arg("X,Y")))
	elseif a == "release" then
		p:release(point(next_arg("X,Y")))
	elseif a == "drag" then
		local x0, y0 = point(next_arg("X0,Y0"))
		local x1, y1 = point(next_arg("X1,Y1"))

		p:drag(x0, y0, x1, y1)
	elseif a == "wheel" then
		local dir = next_arg("up or down")
		local n = tonumber(arg[i + 1])

		if n then
			i = i + 1
		end
		p:wheel(dir, n or 1)
	elseif a == "type" then
		p:typeat(next_arg("text"))
	elseif a == "key" then
		local name = next_arg("a key name")
		local ok, err = p:key(name)

		if not ok then
			die(err)
		end
	elseif a == "run" then
		p:tolua()
		p:say(next_arg("a lua line"), 0.5)
	elseif a == "ask" then
		p:tolua()
		print(p:ask(next_arg("a lua line")))
	elseif a == "sh" then
		p:todos()
		print(p:ask(next_arg("a command line")))
	elseif a == "shot" then
		local out = next_arg("a filename")
		local rows = tonumber(arg[i + 1])

		if rows then
			i = i + 1
		end

		local st, err = p:shot(out, rows)

		if not st then
			die("shot: " .. tostring(err))
		end
		print(("%s: %s %dx%d, %d bytes"):format(out, st.kind, st.w,
		    st.h, st.bytes))
	elseif a == "push" then
		local file = next_arg("a filename")
		local dir = arg[i + 1]

		-- what follows is the directory unless it names an action,
		-- since a directory may hold slashes and so cannot be told
		-- from a path by its shape
		if dir and actions[dir] then
			dir = nil
		end
		if dir then
			i = i + 1
		end

		local st, err = p:push(file, dir and ("/" .. dir) or "/bin")

		if not st then
			die("push: " .. tostring(err))
		end
		print(("%s: sent"):format(file))
	elseif a == "cancel" then
		-- for a line left mid-transfer: stop the sender and read
		-- what it has already sent, so the next command lands at a
		-- prompt rather than inside a screenshot.
		p:cancel()
	elseif a == "sleep" then
		hostpanel.nap(tonumber(next_arg("seconds")) or 1)
	else
		die("no such action: " .. a)
	end
	i = i + 1
end

p:close()
