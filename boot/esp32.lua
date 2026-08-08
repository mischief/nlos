-- the esp32 boot payload: what proc 0 runs, and the only thing that can
-- run. There is no fw_cfg on this machine, so unlike microvm there is no
-- injected alternative -- a test payload is chosen at build time by
-- pointing the embed step at a different file.
--
-- It asks for nothing but the console to reach a prompt. The display,
-- the keyboard and the flash partition arrive through services() below,
-- each behind its own capability and each optional: a payload that
-- blocked in a driver waiting for a device nobody wrote would say
-- nothing on the serial line about why.

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

-- the hardware entropy source, which this proc alone can see. What a
-- service gets is a seed drawn from it, not the draw itself: see
-- lib/svc.lua on why entropy is data and not authority.
local ok_rng, rng = pcall(require, "los.platform.rng")

if not ok_rng or type(rng) ~= "table" or not rng.bytes then
	rng = nil
end

-- ps arrives after the partition is mounted -- see repltools() below.
local ok, magic

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

	-- proc.spawn rather than sys.spawn, because the sender requires
	-- lib/zmodem.lua and that lives on the partition. A raw spawn
	-- gives the child no namespace, so its require would search the
	-- image alone and find nothing.
	local N = require("ns").current()
	local pid, right = require("proc").spawn(src,
	    { name = "shot", ns = N and N:describe() })

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
-- The namespace has two mounts in it, in plan 9's union order.
--
-- lib/romfs.lua is the embedded image: the libs and driver tasks that
-- have to exist before anything can be mounted at all, read only and
-- fixed at build time. Over it, searched first, is the luafs partition,
-- which is where /bin lives and where an uploaded program lands. So a
-- file on the flash shadows one in the image, and a board whose
-- partition is empty still boots to a prompt.
--
-- Both are described to each service, so a child rebuilds the same two
-- mounts in the same order.
local function services()
	local nsmod = require("ns")
	local rootns = nsmod.new()
	local mok, merr = rootns:mount("/", require("romfs").new(), "romfs")

	if not mok then
		print("svc: mount: " .. tostring(merr))
		return
	end

	-- the flash partition, through a filesystem of its own.
	--
	-- task/blksrv.lua holds the raw sectors and this holds a right to
	-- it; what mounts here is the FAT volume, not the device. Absent
	-- capability, unopenable volume and unformatted partition are all
	-- the same case: say so and carry on with the image alone, because
	-- a prompt that comes up is what makes the partition fixable.
	-- Says what happened either way, as init reports every device. A
	-- step that is silent when it works and silent when it is skipped
	-- cannot be told apart from one that never ran, and telling those
	-- apart by hand costs a boot each time.
	if not caps.flash then
		print("luafs: no flash capability, programs from the image only")
	else
		local src = rootns:readfile("/task/fatsrv.lua")
		local fok, ferr = pcall(function()
			local _, f = sys.spawn(src, { name = "fatsrv" })

			-- one server, both partitions: /config is the
			-- second flash volume, mounted inside fatsrv so
			-- it costs a mount point rather than a proc.
			sys.send(f, { blk = { __right = caps.flash },
			    mounts = { "/config" } })
			assert(rootns:mount("/", require("mnt").new(f), "mnt",
			    { port = { __right = f } }, "before"))
		end)

		if fok then
			print("luafs: mounted over the image")
		else
			print("luafs: " .. tostring(ferr))
		end
	end
	-- the lease, as /net.
	--
	-- task/dhcpd.lua serves what it acquired -- /net/addr, /net/gw,
	-- /net/dns, /net/lease -- and mounting it is what makes network
	-- status a file rather than a capability. lib/dnsc.lua reads its
	-- resolver from /net/dns rather than holding a right to anything,
	-- and a shell can cat /net/lease. init.lua does this on the other
	-- platforms; this payload is where it belongs here.
	if caps.dhcpd then
		local nok, nerr = pcall(function()
			assert(rootns:mount("/net",
			    require("mnt").new(caps.dhcpd), "mnt",
			    { port = { __right = caps.dhcpd } }))
		end)

		if not nok then
			print("svc: /net: " .. tostring(nerr))
		end
	end

	-- the pointer, as /dev/mouse.
	--
	-- Started and mounted here rather than named in /etc/services.lua
	-- for the reason the flash volume is: what a service entry gives
	-- is a running proc, and what a pointer has to be is a file in the
	-- namespace every later proc inherits. Mounting it after the
	-- terminal had started would leave the terminal without one.
	--
	-- It is handed the framebuffer as well as the pointer, so it moves
	-- the cursor itself. That is plan 9's split -- devmouse reports,
	-- devdraw draws -- and it keeps the cursor on the finger instead
	-- of a round trip behind whatever is reading the file.
	if caps.ptr then
		local src = rootns:readfile("/task/mousesrv.lua")
		local mok, merr2 = pcall(function()
			local _, m = sys.spawn(assert(src, "no mousesrv"),
			    { name = "mousesrv" })

			sys.send(m, { ptr = { __right = caps.ptr },
			    fb = caps.fb and { __right = caps.fb } or nil })
			-- the right stays ours: the mount's args hold it,
			-- and describing this namespace for a child
			-- serializes it again. Closing it here leaves a
			-- description nothing can be spawned with, which
			-- fails as "unserializable arg" in the child rather
			-- than here.
			assert(rootns:mount("/dev", require("mnt").new(m),
			    "mnt", { port = { __right = m } }))
		end)

		print("mouse: " .. (mok and "/dev/mouse" or tostring(merr2)))
	end
	nsmod.setcurrent(rootns)

	-- the network this machine is on, from /config/wifi.lua.
	--
	--	return { ssid = "labratory", psk = "..." }
	--
	-- A lua chunk rather than a format, as /etc/services.lua is: it
	-- needs no parser, and a file that will not load says so with a
	-- line number.
	--
	-- Read here rather than in task/eth.lua, which owns the radio but
	-- is a kernel-spawned driver with no namespace and no io.open. So
	-- the proc that can read a file tells the proc that can join a
	-- network, which is one message and no third party.
	--
	-- Absent is the ordinary case on a machine nobody has configured.
	-- Nothing is retried and nothing is watched: this joins once, and
	-- bin/wifi.lua is how it is done again.
	--
	-- /config is the partition the build never writes, so a network
	-- set once survives a reflash. /etc/wifi.lua is read where there
	-- is no config volume, which is what an older board has.
	if caps.eth then
		local where = "/config/wifi.lua"
		local src = rootns:readfile(where)

		if not src then
			where = "/etc/wifi.lua"
			src = rootns:readfile(where)
		end

		if src then
			local ok, conf = pcall(function()
				return assert(load(src, "=" .. where, "t",
				    {}))()
			end)

			if ok and type(conf) == "table" and conf.ssid then
				sys.send(caps.eth, { op = "wifi",
				    how = "connect", ssid = conf.ssid,
				    psk = conf.psk })
				print("wifi: joining " .. conf.ssid)
			else
				print("wifi: " .. where .. ": " ..
				    tostring(conf))
			end
		end
	end

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
		-- entropy for services that want it, as data rather than
		-- as a right: this proc holds los.platform.rng and hands
		-- each service its own 32 bytes to expand. init.lua does
		-- the same on the other platforms.
		seed = rng and rng.bytes or nil,
	})
end

local sok, serr = pcall(services)

if not sok then
	print("svc: " .. tostring(serr))
end

-- the repl's own conveniences, which live on the partition.
--
-- After services(), because that is where the volume is mounted and
-- require starts resolving through the namespace. lib/ps.lua is not in
-- the image: it is a convenience and it must not be able to cost us the
-- console. Internal SRAM is ~240KB with no PSRAM behind it (qemu
-- emulates neither PSRAM mode), and ps on top of src/thread.c is
-- enough to run a tight machine out of memory -- which without a pcall
-- here killed proc 0 during require and left a booted kernel with
-- nothing to type at.
ok, magic = pcall(require, "ps")

if ok then
	_G.ps = magic.ps
	_G.stats = magic.stats
	_G.ports = magic.ports
	_G.stack = function(pid)
		return magic.stack(pid or sys.self())
	end
	if caps.power then
		_G.halt = magic.halt(caps.power)
		_G.reboot = magic.reboot(caps.power)
	end
end

-- dos(): hand the console to the launcher, as init.lua does it on the
-- other platforms. Same name and same shape, so a session on this board
-- is the one you already know.
--
-- It matters more here than there. lib/fbsh.lua is the only other dos
-- shell and task/fbterm.lua runs it, which wants a framebuffer and a
-- keyboard -- so on a board with neither the lua repl is the whole of
-- the machine's interface, and without this there is no way to run a
-- program by name at all.
--
-- Runs in this proc, so the repl below is blocked inside the call until
-- you type exit and there is one reader of the console throughout. Two
-- procs reading it is what makes a shell eat the repl's input, which is
-- why the panel terminal has a proc of its own.
--
-- Parens, like halt: a bare __tostring must never do something this
-- consequential.
_G.dos = setmetatable({}, {
	__tostring = function()
		return "dos: type dos() to start the launcher"
	end,
	__call = function()
		local N = require("ns").current()

		if not N then
			return "dos: no namespace to run programs from"
		end
		-- udp is the ip task: it serves the datagram ops on the
		-- same right, and nothing publishes a capability by that
		-- name. bin/host.lua and bin/date.lua spend it.
		require("dos").start({ ns = N, cons = caps.cons,
		    fb = caps.fb, net = caps.tcp, udp = caps.udp or caps.ip,
		    power = caps.power },
		    "lua-os. programs live in /bin; type exit to " ..
		    "return to lua.\n")
		return "back at the lua repl"
	end,
})

print(_VERSION .. " on esp32")
if ok then
	print("mach-lite kernel + plan9 furniture. ps, stats, stack(pid)" ..
	    ", dos()" .. (caps.power and ", halt(), reboot()" or ""))
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
