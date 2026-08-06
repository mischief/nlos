-- the esp32 boot payload: what proc 0 runs, and the only thing that can
-- run. There is no fw_cfg on this machine, so unlike microvm there is no
-- injected alternative -- a test payload is chosen at build time by
-- pointing the embed step at a different file.
--
-- It asks for nothing but the console. The board has a display, a
-- keyboard, a radio and 16MB of flash, and none of them are wired yet;
-- a payload that blocked in a driver waiting for a device nobody wrote
-- would say nothing on the serial line about why.

local sys = require("los.sys")
local thread = require("los.thread")

local caps = sys.granted()

require("stdout").set(caps.cons)

-- no claim_input here, unlike microvm. There the one uart is the
-- keyboard and the 9p wire both, so a payload has to say which it
-- wants; this platform has a console and no wire, and
-- platform_console_input answers yes unconditionally.

_G.sys = sys
_G.thread = thread

-- ps is a convenience, not the console, so it must not be able to cost
-- us the console. Internal SRAM is ~240KB with no PSRAM behind it (qemu
-- emulates neither PSRAM mode), and lib/ps.lua on top of lib/thread.lua
-- is enough to run a tight machine out of memory -- which without this
-- killed proc 0 during require and left a booted kernel with nothing to
-- type at.
local ok, magic = pcall(require, "ps")

if ok then
	_G.ps = magic.ps
	_G.stats = magic.stats
	_G.ports = magic.ports
	_G.stack = function(pid)
		return magic.stack(pid or sys.self())
	end
	if caps.power then
		_G.halt = magic.halt(caps.power)
	end
end

-- shot("name.pbm") -- send the screen to the host over ZMODEM.
--
-- Lazy on purpose: lib/zmodem.lua is 27KB of source and its compiled
-- form is resident in this proc once required, which on a board with no
-- PSRAM is memory a repl should not spend until asked.
--
-- The screen comes back as a P4 PBM because that is exactly what the
-- driver keeps: CONFIG_LUAOS_FB_SHADOW is one bit per pixel, so a
-- screenshot is shape and not colour, and a PPM would triple the file
-- to carry two of them. fb.unload hands out BGRx (the shared protocol's
-- layout), so a row is 960 bytes in and 30 bytes out -- built a row at
-- a time so the whole 129600-byte expansion never exists at once.
--
-- ZMODEM rather than printing hex: the console is the only line out,
-- and a guest that free-runs a dump into it blocks forever once the
-- USB-Serial-JTAG buffer fills with nobody draining. ZMODEM has its own
-- flow control, so the transfer is paced by the receiver.
-- shot("name.pbm" [, rows]) -- send the screen to the host over
-- ZMODEM, from a proc of its own.
--
-- Spawned rather than run here: lib/zmodem.lua is ~30KB resident and
-- the image another 4KB, against a repl that is already 63KB on a board
-- with ~120KB free. Doing it in this proc measured "not enough memory"
-- every time; doing it in a proc that exits afterwards costs the same
-- memory for the length of the transfer and hands it straight back.
--
-- Receive it with: lrz -y  (see tools/screenshot-esp32.lua)
-- the framebuffer's right, for driving the panel from the repl:
--	thread.rpc(fb, {op="fill", r={0,0,320,240}, color=0xffffff})
-- Named rather than granted: this proc already holds it, and shot()
-- below is built on the same handle.
if caps.fb then
	_G.fb = caps.fb
end

-- term() -- start the panel+keyboard terminal, in a proc of its own.
--
-- Separate so the serial console survives it: this line is how the
-- board is debugged, and a shell that took both terminals would take
-- the way in with it.
if caps.fb and caps.kbd then
	_G.term = function()
		local f = io.open("/task/fbterm.lua")

		if not f then
			return nil, "no /task/fbterm.lua"
		end

		local src = f:read("a")

		f:close()

		local pid, right = sys.spawn(src, { name = "fbterm" })

		sys.send(right, { fb = { __right = caps.fb },
		    kbd = { __right = caps.kbd },
		    cons = { __right = caps.cons } })
		sys.close(right)
		return pid
	end
end

-- fbtest(text) -- draw through the framebuffer console backend.
--
-- The rendering half of it, alone: no lib/console.lua, no shell. What
-- this answers is whether glyphs land where the grid says, which
-- shot() can then read back off the panel.
if caps.fb and caps.kbd then
	_G.fbtest = function(msg)
		local fbcons = require("fbcons")
		local b = fbcons.new({ fb = caps.fb, keyport = caps.kbd,
		    font = require("los.font") })

		b.write(msg or "lua-os on the panel\n")
		return b.cols .. "x" .. b.rows
	end
end

_G.shot = function(name, rows)
	local f = io.open("/task/shot.lua")

	if not f then
		return nil, "no /task/shot.lua"
	end

	local src = f:read("a")

	f:close()

	local pid, right = sys.spawn(src, { name = "shot" })

	-- rights are copied rather than moved, so ours stay ours.
	sys.send(right, {
		cons = { __right = caps.cons },
		fb = { __right = caps.fb },
		name = name,
		rows = rows,
		done = { __right = sys.SELF },
	})
	sys.close(right)

	-- hear the death as well as the reply. A sender that raises never
	-- sends anything, and without this the wait below is indefinite --
	-- so a crashed child and a stalled transfer look identical from
	-- here, which is how an unbound global read like a protocol bug.
	sys.monitor(pid)

	-- Wait. Not politeness: while the transfer runs this proc must not
	-- ask cons for a line, or the shell and the sender both take from
	-- the same keyboard and the receiver's headers land in the repl --
	-- "unexpected symbol near '*'", which is a ZMODEM frame being
	-- parsed as lua.
	while true do
		local m = thread.recv(sys.SELF)

		if type(m) == "table" and m.exit == pid then
			-- a proc that raised is a corpse, and a corpse keeps
			-- its heap so it can be inspected. Nothing else will
			-- free it, so a few failed shots would eat the board.
			pcall(sys.reap, pid)
			return nil, "shot died: " .. tostring(m.reason or
			    m.exitmsg)
		elseif type(m) == "table" and m.ok ~= nil then
			return m.ok, m.err
		end
	end
end

-- what this machine runs, from /etc/services.lua.
--
-- The same table and the same loader init.lua uses on the other
-- platforms, so a service is described once and starts wherever its
-- capabilities exist. A service naming one this board does not have is
-- skipped rather than started to fail, which is what keeps the panel
-- terminal out of a build with no keyboard.
--
-- The namespace comes from lib/romfs.lua: the embedded image, mounted
-- read only. It is described to each service so the child rebuilds the
-- same mount, which is how a program reaches /bin at all.
local function services()
	local nsmod = require("ns")
	local rootns = nsmod.new()
	local mok, merr = rootns:mount("/", require("romfs").new(), "romfs")

	if not mok then
		print("svc: mount: " .. tostring(merr))
		return
	end
	nsmod.setcurrent(rootns)

	local svc = require("svc")
	local list, why = svc.load(rootns, "/etc/services.lua")

	if not list then
		print("svc: " .. tostring(why))
		return
	end
	svc.start(list, {
		ns = rootns:describe(),
		granted = caps,
		readfile = function(p)
			return rootns:readfile(p)
		end,
		log = print,
	})
end

local sok, serr = pcall(services)

if not sok then
	print("svc: " .. tostring(serr))
end

print(_VERSION .. " on esp32")
if ok then
	print("mach-lite kernel + plan9 furniture. ps, stats, stack(pid)" ..
	    (caps.power and ", halt()" or ""))
else
	print("mach-lite kernel. ps unavailable: " .. tostring(magic))
end
print("")

-- the same two-step the other repls do: try the line as an expression
-- first so a bare `ps` prints something, then as a statement.
local function evaluate(line)
	local chunk, err = load("return " .. line, "=repl")

	if not chunk then
		chunk, err = load(line, "=repl")
	end
	return chunk, err
end

while true do
	local line = thread.readline(caps.cons, "> ")

	if line == nil then
		break
	end

	if #line > 0 then
		local chunk, err = evaluate(line)

		if chunk then
			local res = table.pack(xpcall(chunk, debug.traceback))

			if res[1] then
				if res.n > 1 then
					print(table.unpack(res, 2, res.n))
				end
			else
				print("error: " .. tostring(res[2]))
			end
		else
			print(err)
		end
	end
end

print("")
print("-- session ended --")
