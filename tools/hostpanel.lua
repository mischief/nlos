-- hostpanel: drive a board's panel from the host, over the serial line.
--
-- One serial session that can type at the lua repl, read what comes
-- back, inject pointer and keyboard events, and pull a screenshot.
-- tools/poke-esp32.lua is the command line over it, and
-- tools/screenshot-esp32.lua is the same session doing only the last
-- of those.
--
-- ---- why input needs nothing in the kernel ----
--
-- The pointer and the keyboard are ports. The kernel pushes a record
-- or a keystroke onto one, and whoever holds the receive right takes it
-- off -- task/mousesrv.lua for the pointer, the panel console for the
-- keys. A synthetic event is therefore an ordinary send to the same
-- port, and the boot repl already holds a right to both.
--
-- So there is no debug hook here, no test mode, and no path that exists
-- only for a test: what this injects is indistinguishable from what the
-- hardware produces, because it is the same message on the same port.
-- A driver that produced a different shape would be caught by this
-- rather than hidden by it.
--
-- ---- one opener ----
--
-- The serial port is opened once for the whole session, commands and
-- transfer alike. A second opener asserts DTR/RTS, and on a native
-- USB-Serial-JTAG those are the reset strap -- the board reboots
-- mid-session and takes the screen's contents with it.

local M = {}

local Panel = {}

Panel.__index = Panel

local function hostutil()
	local so = os.getenv("HOSTUTIL_SO")

	if not so then
		error("HOSTUTIL_SO is not set " ..
		    "(build it: ninja -C build hostutil.so)", 0)
	end
	return assert(package.loadlib(so, "luaopen_hostutil"))()
end

-- open(port, baud) -> panel
function M.open(port, baud)
	local hu = hostutil()
	local f = assert(hu.serial(port or "/dev/ttyACM0", baud or 115200))

	return setmetatable({ hu = hu, f = f, fd = hu.fileno(f) }, Panel)
end

local function nap(seconds)
	os.execute("sleep " .. tostring(seconds))
end

M.nap = nap

-- say(line) -- type one line at the repl.
--
-- The flush matters. The stream is read/write, and C wants the
-- direction change separated by a flush whatever the buffering; without
-- it a later read blocks forever on a line that is working perfectly.
function Panel:say(line, settle)
	self.f:write(line, "\r\n")
	self.f:flush()
	nap(settle or 0.4)
	return self
end

-- torepl() -- get to the lua prompt, wherever the console was.
--
-- The console comes up in the launcher, which answers a lua line with
-- "not found". exit returns to the repl from there and is a word that
-- does nothing at the repl, so this lands in the same place either way
-- and needs to know neither. Panel:shot types dos() for the mirror.
function Panel:torepl()
	return self:say(""):say("exit")
end

-- ask(line) -- type a line and collect what comes back.
--
-- Lines rather than a prompt match: the repl prints its prompt without
-- a newline, and other procs print to the same console at any moment,
-- so what arrives is not a transcript with a shape to parse. This
-- gathers for `quiet` seconds of silence and hands back everything,
-- caller's problem to read.
function Panel:ask(line, quiet)
	self.f:write(line, "\r\n")
	self.f:flush()

	local out = {}
	local deadline = os.time() + 10

	-- A byte at a time, and only when poll says one is there. Reading
	-- a line instead blocks until a newline that may never arrive: the
	-- repl ends its prompt without one, so a board with nothing to say
	-- would hold this port until the process was killed.
	while os.time() < deadline do
		if not self.hu.readable(self.fd, quiet or 0.6) then
			break
		end

		local c = self.f:read(1)

		if not c then
			break
		end
		out[#out + 1] = c
	end
	return (table.concat(out):gsub("\r", ""))
end

-- ---- input ----
--
-- The helpers are defined in the guest once per session, so an event is
-- one short line rather than a formatted record per event: a drag of
-- thirty points is one line of lua and one settle, not thirty.
--
-- PTR and KBD are send rights minted from the rights the repl holds,
-- which is ordinary and is what makes this need no new authority.
-- `panel` rather than sys.granted(): the repl is a proc init spawns, so
-- its rights arrive in its grant message. What the kernel granted is
-- init's, and this console's own table is empty.
local SETUP = [[
do local g = panel
PTR = g.ptr and sys.sendright(g.ptr)
KBD = g.kbd and sys.sendright(g.kbd)
function P(x, y, b)
	sys.send(PTR, string.format("m%12d%12d%12d%12d", x, y, b,
	    sys.uptime_ms()))
end
function K(s)
	local at = 1
	while at <= #s do
		local b = s:byte(at)
		local n = b < 0x80 and 1 or b < 0xe0 and 2 or b < 0xf0 and 3 or 4
		sys.send(KBD, s:sub(at, at + n - 1))
		at = at + n
	end
end
function DRAG(x0, y0, x1, y1, n, ms)
	for i = 0, n do
		P(x0 + (x1 - x0) * i // n, y0 + (y1 - y0) * i // n, 1)
		thread.sleep(ms or 40)
	end
	P(x1, y1, 0)
end
print("poke: ptr=" .. tostring(PTR) .. " kbd=" .. tostring(KBD))
end
]]

function Panel:setup()
	if self.ready then
		return self
	end
	-- one line: the repl evaluates a line at a time, so a do/end block
	-- has to arrive as one.
	self:say((SETUP:gsub("\n", " ")), 0.6)
	self.ready = true
	return self
end

-- where the pointer is, with no button down
function Panel:move(x, y)
	return self:setup():say(("P(%d,%d,0)"):format(x, y), 0.15)
end

-- press and release in one place, which is a tap on the panel and a
-- click anywhere else. Two records with a pause between them, because a
-- press and a release at the same millisecond is not something a finger
-- can do and not something a program should have to handle.
function Panel:tap(x, y)
	self:setup()
	self:say(("P(%d,%d,1)"):format(x, y), 0.2)
	return self:say(("P(%d,%d,0)"):format(x, y), 0.2)
end

function Panel:press(x, y)
	return self:setup():say(("P(%d,%d,1)"):format(x, y), 0.15)
end

function Panel:release(x, y)
	return self:setup():say(("P(%d,%d,0)"):format(x, y), 0.15)
end

-- a stroke: down at the start, along, up at the end.
--
-- Paced, because a read of the pointer answers with where it is now
-- rather than with every place it has been -- so a burst of records
-- sent as fast as the guest can loop coalesces into its last one, and a
-- whole stroke arrives as a single release. A finger cannot outrun the
-- readers and neither should this.
function Panel:drag(x0, y0, x1, y1, steps, ms)
	self:setup()
	return self:say(("DRAG(%d,%d,%d,%d,%d,%d)"):format(x0, y0, x1, y1,
	    steps or 12, ms or 40),
	    0.4 + (steps or 12) * (ms or 40) / 1000)
end

-- the wheel: 8 up and 16 down as plan 9 numbers it, 32 left and 64
-- right as x11 does. The trackball is where these come from on a
-- T-Deck.
local WHEEL = { up = 8, down = 16, left = 32, right = 64 }

function Panel:wheel(dir, n, x, y)
	local b = WHEEL[dir] or WHEEL.up

	self:setup()
	for _ = 1, n or 1 do
		self:say(("P(%d,%d,%d)"):format(x or 200, y or 120, b), 0.15)
	end
	return self
end

-- keystrokes at the panel's keyboard, not at this serial line. That is
-- the distinction worth keeping: what this drives is the terminal on
-- the glass, which is a different console with a different reader.
function Panel:typeat(s)
	self:setup()
	return self:say(("K(%q)"):format(s), 0.3)
end

local KEYS = {
	enter = "\r", ["return"] = "\r", tab = "\t", esc = "\27",
	backspace = "\8", space = " ", intr = "\3",
}

function Panel:key(name)
	local c = KEYS[name]

	if not c then
		return nil, "no such key: " .. tostring(name)
	end
	return self:typeat(c)
end

-- ---- reading the screen back ----
--
-- The panel cannot be read: neither board routes the display's SDO
-- anywhere. What comes back is the shadow the driver keeps, which is
-- colour where CONFIG_LUAOS_FB_SHADOW keeps colour and one bit per
-- pixel otherwise -- hence PPM or PBM, whichever the guest sends.
--
-- ZMODEM rather than printing pixels. The console is the only line out,
-- and a guest that free-runs a dump into it blocks forever once the
-- USB-Serial-JTAG buffer fills with nobody draining. ZMODEM is paced by
-- the receiver and moves a 320x240 screen in about a second.
-- read and discard whatever the guest is still saying, until it has
-- been quiet for `quiet` seconds or `limit` has passed.
--
-- What this is for is a transfer that failed: the sender goes on
-- streaming a screen into a console with nobody receiving, and every
-- command typed afterwards lands in the middle of it. Draining is how
-- the line becomes a line again.
function Panel:drain(limit, quiet)
	local deadline = os.time() + (limit or 6)
	local n = 0

	while os.time() < deadline do
		if not self.hu.readable(self.fd, quiet or 0.4) then
			break
		end
		-- A byte at a time. read(n) on a buffered stream waits for
		-- n bytes, and a serial line has no end to cut it short:
		-- ask for a block with one byte in hand and the read waits
		-- for bytes that may never come.
		if not self.f:read(1) then
			break
		end
		n = n + 1
	end
	return n
end

-- ZMODEM's cancel: the sender stops on a run of CAN. Sent when the
-- receiver has gone, which is exactly when the guest would otherwise
-- keep sending.
--
-- Bounded rather than "until it stops". A sender that has stopped
-- reading its console does not hear this, and waiting for a guest that
-- cannot answer holds the serial port -- the one way in -- for as long
-- as the wait. Better to give the line back and say so.
function Panel:cancel()
	self.f:write(string.rep("\24", 10))
	self.f:flush()
	self:drain(6, 0.4)
	self.f:write("\r\n")
	self.f:flush()
	nap(0.3)
	return self
end

function Panel:shot(out, rows)
	-- anything still arriving is from before this call and would be
	-- read as the start of the transfer.
	self:drain(3, 0.3)

	-- rz writes to the current directory under the name the sender
	-- gave and cannot be told otherwise, so ask for a name of our
	-- choosing and move it afterwards.
	local tmp = ".shot-esp32.pbm"

	os.remove(tmp)
	-- a program in /bin rather than a word at the lua prompt, so the
	-- session goes through dos and comes back. dos blocks while it
	-- runs, which is what keeps the shell off the console during the
	-- transfer.
	self:say("dos()", 0.6)
	self:say(("shot %s%s"):format(tmp, rows and (" " .. rows) or ""),
	    0.5)

	local pid = self.hu.spawn({ "rz", "-y" },
	    { stdin = self.fd, stdout = self.fd, stderr = 2 })

	if not pid then
		return nil, "cannot run rz (install lrzsz)"
	end

	-- Slack for a guest that is busy rather than for a transfer that
	-- is slow: if it expires the transfer has failed and waiting
	-- longer will not mend it.
	--
	-- Longer than the sender's own budget (see task/shot.lua), on
	-- purpose. The guest is the one holding the console, so it must be
	-- the one that gives up first; a host that quits earlier only
	-- leaves a sender pushing pixels at nobody.
	local deadline = os.time() + 100
	local rc

	while os.time() < deadline do
		rc = self.hu.poll(pid)
		if rc then
			break
		end
		nap(0.2)
	end

	local timedout = not rc

	if timedout then
		self.hu.kill(pid)
		-- with the receiver gone the guest is still sending, and
		-- what it sends lands in whatever is typed next.
		self:cancel()
	end

	-- the guest reports its own result and says why it failed, which
	-- is worth surfacing: "no receiver" and "not enough memory" are
	-- different problems and both look like an empty file out here.
	-- A byte at a time, for the reason drain says: read("l") waits for
	-- a newline, and what is queued after a transfer ends with a
	-- prompt that has none -- so a line read with a byte in hand
	-- blocks until something else happens to type at the board.
	local why = nil
	local tail = {}
	local stop = os.time() + 3

	while os.time() < stop do
		if not self.hu.readable(self.fd, 0.4) then
			break
		end

		local c = self.f:read(1)

		if not c then
			break
		end
		tail[#tail + 1] = c
	end
	for l in table.concat(tail):gmatch("[^\r\n]+") do
		if l:match("shot:") then
			why = (l:gsub("%c", ""))
		end
	end

	-- back to the lua prompt, so the next call finds the session where
	-- it left it rather than one dos deep.
	self:say("exit", 0.4)

	local fh = io.open(tmp, "rb")

	if timedout or not fh then
		if fh then
			fh:close()
		end
		os.remove(tmp)
		return nil, why or "no file received"
	end

	local data = fh:read("a")

	fh:close()
	os.remove(tmp)

	local kind, w, h, body = data:match("^(P[46])\n(%d+) (%d+)\n()")

	if not kind then
		return nil, "not a netpbm: " ..
		    string.format("%q", data:sub(1, 16))
	end

	w, h = tonumber(w), tonumber(h)

	-- A transfer that stopped early leaves a file with a good header
	-- and a short body, and rz keeps what it got. Read as an image
	-- that is a screenshot of the top of the screen and black below --
	-- which is a picture wrong in a way nothing downstream can catch,
	-- since every pixel in it is correct. The header says how many
	-- there should be, so ask.
	local want

	if kind == "P6" then
		-- maxval line, then three bytes a pixel
		local px = data:match("^P[46]\n%d+ %d+\n255\n()")

		want = px and (px - 1 + w * h * 3)
	else
		want = body - 1 + ((w + 7) // 8) * h
	end
	if want and #data < want then
		return nil, ("short: %d of %d bytes"):format(#data, want)
	end

	local o, oerr = io.open(out, "wb")

	if not o then
		return nil, tostring(oerr)
	end
	o:write(data)
	o:close()
	return { kind = kind, w = w, h = h, bytes = #data }
end

-- push(file, dir) -- send a file to the board, over zmodem.
--
-- The mirror of shot: dos(), because what receives is bin/rz.lua and
-- the launcher runs it. No "rz" is typed -- sz writes that word itself
-- and the launcher takes it. A program on the flash volume is then an
-- upload where the same edit in the firmware is a rebuild and a flash.
function Panel:push(file, dir)
	local fh = io.open(file, "rb")

	if not fh then
		return nil, "cannot read " .. tostring(file)
	end
	fh:close()

	self:drain(3, 0.3)
	self:say("dos()", 0.6)
	if dir then
		self:say("cd " .. dir, 0.4)
	end

	-- session: lrzsz sets the line raw and flushes it, and a child
	-- without a controlling terminal gets EIO for both rather than
	-- SIGTTOU.
	local pid = self.hu.spawn({ "sz", "-q", "-b", file },
	    { stdin = self.fd, stdout = self.fd, stderr = 2,
	      session = true })

	if not pid then
		return nil, "cannot run sz (install lrzsz)"
	end

	local deadline = os.time() + 60
	local code = nil

	while os.time() < deadline do
		code = self.hu.poll(pid)
		if code then
			break
		end
		nap(0.1)
	end

	if not code then
		self.hu.kill(pid)
		self:say("exit", 0.4)
		return nil, "sz did not finish"
	end

	-- what the guest said about it, the way shot reads its sender's
	-- complaint: a refused write and a full volume both look like a
	-- transfer that simply ended out here.
	local tail = {}
	local stop = os.time() + 2

	while os.time() < stop do
		if not self.hu.readable(self.fd, 0.3) then
			break
		end

		local c = self.f:read(1)

		if not c then
			break
		end
		tail[#tail + 1] = c
	end
	self:say("exit", 0.4)

	local said = table.concat(tail)

	if code ~= 0 then
		return nil, "sz failed: " .. (said:match("rz: [^\r\n]+") or
		    ("exit " .. tostring(code)))
	end
	return { bytes = nil, said = said }
end

function Panel:close()
	self.f:close()
end

return M
