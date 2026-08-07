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

	while os.time() < deadline do
		if not self.hu.readable(self.fd, quiet or 0.6) then
			break
		end

		local l = self.f:read("l")

		if not l then
			break
		end
		out[#out + 1] = (l:gsub("[\r\n]", ""))
	end
	return table.concat(out, "\n")
end

-- ---- input ----
--
-- The helpers are defined in the guest once per session, so an event is
-- one short line rather than a formatted record per event: a drag of
-- thirty points is one line of lua and one settle, not thirty.
--
-- PTR and KBD are send rights minted from the receive rights the repl
-- was granted. Minting a send right from a right you hold is ordinary,
-- and it is what makes this need no new authority.
local SETUP = [[
do local g = sys.granted()
PTR = g.ptr and sys.sendright(g.ptr)
KBD = g.kbd and sys.sendright(g.kbd)
function P(x, y, b)
	sys.send(PTR, string.format("m%11d %11d %11d %11d", x, y, b,
	    sys.uptime_ms()))
end
function K(s)
	for i = 1, #s do sys.send(KBD, s:sub(i, i)) end
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

-- the wheel, as plan 9 numbers it: 8 up, 16 down. The trackball is
-- where these come from on a T-Deck.
function Panel:wheel(dir, n, x, y)
	local b = (dir == "down") and 16 or 8

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
function Panel:shot(out, rows)
	-- lrz writes to the current directory under the name the sender
	-- gave and cannot be told otherwise, so ask for a name of our
	-- choosing and move it afterwards.
	local tmp = ".shot-esp32.pbm"

	os.remove(tmp)
	self:say(("shot(%q%s)"):format(tmp, rows and (", " .. rows) or ""),
	    0.5)

	local pid = self.hu.spawn({ "lrz", "-y" },
	    { stdin = self.fd, stdout = self.fd, stderr = 2 })

	if not pid then
		return nil, "cannot run lrz (install lrzsz)"
	end

	-- A screen is about 10KB and moves at ~114KB/s, so this is slack
	-- for a guest that is busy rather than for a transfer that is
	-- slow. If it expires the transfer has failed and waiting longer
	-- will not mend it.
	local deadline = os.time() + 20
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
	end

	-- the guest reports its own result and says why it failed, which
	-- is worth surfacing: "no receiver" and "not enough memory" are
	-- different problems and both look like an empty file out here.
	local why = nil

	for _ = 1, 3 do
		if not self.hu.readable(self.fd, 1.0) then
			break
		end

		local l = self.f:read("l")

		if not l then
			break
		end
		l = l:gsub("%c", "")
		if l:match("shot:") then
			why = l
		end
	end

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

	local kind, w, h = data:match("^(P[46])\n(%d+) (%d+)\n")

	if not kind then
		return nil, "not a netpbm: " ..
		    string.format("%q", data:sub(1, 16))
	end

	local o, oerr = io.open(out, "wb")

	if not o then
		return nil, tostring(oerr)
	end
	o:write(data)
	o:close()
	return { kind = kind, w = tonumber(w), h = tonumber(h), bytes = #data }
end

function Panel:close()
	self.f:close()
end

return M
