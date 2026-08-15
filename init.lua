-- lua-os init (proc 0): spawn the 9p file server, then repl

local sys = require("los.sys")
local thread = require("los.thread")

-- the firmware's own module, which only a machine booted by firmware
-- has. Absent on a board, where every use below is a question this
-- answers with nil rather than a branch on the machine's name.
local ok_efi, efi = pcall(require, "los.efi")

if not ok_efi or type(efi) ~= "table" then
	efi = {}
end

-- what the kernel granted us at boot, by name -> handle. handle
-- numbers are whatever right_new picked and are not stable across
-- boots (no NIC means no tcp/udp task, and everything after shifts
-- down), so nothing here may hardcode one. an absent key means the
-- machine simply doesn't have that capability -- which is also the
-- whole availability test, no probing required.
local caps_of = sys.granted()

-- the root namespace, built here because proc 0 is where the raw ESP
-- reaches. everything proc 0 spawns is handed a DESCRIPTION of it as
-- sys.spawn's `arg`, so a child holds it before its own first line --
-- which is where require() happens, and therefore where a namespace has
-- to already be. plan 9 gets this from fork; we get it from arg.
local nsmod = require("ns")

-- the machine's entropy source, if the firmware has one
-- (los.platform.rng: EFI_RNG_PROTOCOL here, virtio-rng on microvm). it
-- is registered in proc 0's package.preload and nowhere else, because
-- the raw function IS the capability -- there is no handle to check --
-- so what everything else gets is a seed, as data, at spawn.
local ok_rng, rng = pcall(require, "los.platform.rng")

if not ok_rng then
	rng = nil
end

-- route proc 0's own print/io.write through the cons task, so output has
-- an owner rather than every proc calling console_write directly. from
-- here on everything proc.spawn creates inherits this right, and
-- redirecting a proc means handing it a different one.
--
-- proc 0 is PRIV_BOOT so it could have kept the raw path; using the port
-- means the ONE place output is serialised is the task that owns the
-- console, which is what "one owner per resource" asks for.
require("stdout").set(caps_of.cons)

-- the console's input, for the repl below. Where one serial line is both
-- the keyboard and the 9p wire the wire keeps the bytes until someone
-- asks, so a machine that means to be typed at has to say so. A no-op
-- where the two are different devices: lib/console.lua skips it when the
-- backend publishes no claim_input.
sys.send(caps_of.cons, { op = "claim_input" })

-- diagnostics are a different stream from output: sys.log lands in the
-- kernel's ring, stamped and tagged with this proc's name, alongside
-- what the kernel writes there itself.
sys.log("entropy: %s", rng and "los.platform.rng" or
    ("none (" .. tostring(rng == nil and ok_rng) .. ")"))
local rootns = nsmod.new()

-- mount FIRST, adopt second. adopting is what routes require() through
-- the namespace, so doing it to an empty one would leave the next
-- require with nowhere to look.
--
-- / is the esp SERVER, not a local espfs: caps_of.esp is a right to the
-- one task that reaches the disk directly (lib/espsrv.lua), so what
-- describe() hands a child is that right rather than a recipe for
-- rebuilding the driver. a child therefore inherits ESP access the same
-- way it inherits anything else, and one handed a namespace without it
-- cannot reach the disk at all.
-- Which of these a machine has is what decides its root, rather than
-- the machine's name: a disk is served by a task and mounted, and a
-- board with none has the image the kernel was built with.
if caps_of.esp then
	rootns:mount("/", require("mnt").new(caps_of.esp), "mnt",
	    { port = { __right = caps_of.esp } })
else
	local rok, rerr = rootns:mount("/", require("romfs").new(), "romfs")

	if not rok then
		sys.log("boot: no root: %s", tostring(rerr))
	end
end

-- and the flash volume over it, searched first, where there is one: a
-- file on the partition shadows the image, so an uploaded program wins
-- and a board with an empty partition still boots.
if caps_of.flash then
	local fok, ferr = pcall(function()
		assert(rootns:mount("/", require("mnt").new(caps_of.flash),
		    "mnt", { port = { __right = caps_of.flash } }, "before"))
	end)

	sys.log("luafs: %s", fok and "mounted over the image" or
	    tostring(ferr))
end

-- the proc table as files, where the module is on this machine
pcall(function()
	rootns:mount("/proc", require("procfs").new(), "procfs")
end)
nsmod.setcurrent(rootns)

-- after the mounts, since a board carries lib/proc.lua on its
-- partition rather than in the image the kernel was built with.
local proc = require("proc")


local nsdesc = rootns:describe()

do
	-- what proc 0 was granted. these names exist nowhere else until
	-- something calls sys.granted(), so a boot that is missing a
	-- capability otherwise gives no sign of it.
	local names = {}

	for k in pairs(caps_of) do
		names[#names + 1] = k
	end
	table.sort(names)
	sys.log("granted: %s", table.concat(names, " "))
end

if efi.firmware then
	print(("%s on %s (fw rev 0x%x)"):format(_VERSION, efi.firmware,
	    efi.firmware_revision))
else
	print(_VERSION)
end
print("mach-lite kernel + plan9 furniture (threads, channels, alt, 9p)")
print("")

-- com2 -- the "wire" -- is left unused now. It once carried a 9P server,
-- the machine's namespace mounted over the serial line, from before there
-- was a network to carry one; task/9pexport.lua on tcp/7777 is that today,
-- and better. The capability has not gone anywhere: the kernel still
-- starts the wire driver and grants proc 0 a right to it (caps_of.wire),
-- so a serial 9P mount could be brought back by spawning a server on it
-- the way the tcp export is spawned below -- ninep.serve takes a
-- read/write pair, and wire's op="read"/op="write" messages are one. It
-- is documented rather than kept because a demo tree on a wire nobody
-- mounts is a crutch, and the real namespace over tcp is the thing.

-- the whole namespace goes out over tcp/7777 with task/9pexport.lua, the
-- same exportfs that serves gefs on 564 -- rooted at "/" instead of
-- /n/gefs, so `9p tcp!host!7777 ls /` shows /net, /srv, /n and the rest.
-- It is spawned after the namespace is fully assembled (below), because
-- it needs those mounts to be there to export them.

-- ---- get an address, before anything wants one ----
--
-- run DHCP ourselves rather than waiting for the firmware to finish its
-- own. the firmware sits on an offer it already has for four seconds --
-- Ip4Config2 gives Dhcp4 no callback, so an offer is only selected when
-- mDhcp4DefaultTimeout[0] expires -- and that timeout is unreachable
-- from outside, since one Dhcp4 child may be active at a time and
-- Ip4Config2 owns it. lib/dhcp.lua carries the whole argument.
--
-- measured: the four-way completes in 12ms on the wire and listen
-- succeeds 2ms later, against ~3300ms of spinning on EFI_NO_MAPPING.
--
-- a PROC rather than a call here, because a lease has to be renewed --
-- see lib/dhcpd.lua. nothing waits for it: every listen below already
-- retries, so the address simply appears underneath them. and if it
-- never does, the firmware's own DHCP was left running and they retry
-- exactly as they always did.
-- This proc mounts nothing: /net, /srv, /n/gefs and both 9P exports are
-- entries in /etc/services.lua. A mount an entry declares is inherited
-- by the entries after it, which is what lets one list say partsrv,
-- then gefssrv at /n/gefs, then an export rooted there.
-- dhcpd keeps the description made above, without /net: it serves /net,
-- and a namespace holding a mount to itself is a loop to be walked.

-- the network a radio is on: { ssid = "labratory", psk = "..." }.
--
-- Read here because task/eth.lua owns the radio but is a kernel driver
-- with no namespace. /config survives a reflash; a machine whose
-- interface is a cable has neither file and does nothing.
if caps_of.eth then
	local where = "/config/wifi.lua"
	local src = rootns:readfile(where)

	if not src then
		where = "/etc/wifi.lua"
		src = rootns:readfile(where)
	end
	if src then
		local wok, conf = pcall(function()
			return assert(load(src, "=" .. where, "t", {}))()
		end)

		if wok and type(conf) == "table" and conf.ssid then
			sys.send(caps_of.eth, { op = "wifi", how = "connect",
			    ssid = conf.ssid, psk = conf.psk })
			sys.log("wifi: joining %s", conf.ssid)
		else
			sys.log("wifi: %s: %s", where, tostring(conf))
		end
	end
end

-- what this machine has: the kernel's own grants to start with, and
-- below, everything /etc/services.lua started as well, under the name
-- the list gave it. The stack is in the second group -- ip, tcp and
-- dhcpd are services -- so a shell is lent the same procs the panel's
-- services were, from one table.
local avail = caps_of

print("")

-- ---- services ----
--
-- what this machine runs, from /etc/services.lua, each granted exactly
-- the capabilities it named there. see lib/svc.lua for why this exists
-- rather than everyone replacing init with a fw_cfg payload.
--
-- started BEFORE the repl, so a machine whose job is to serve something
-- is serving it whether or not anyone is at the console.
do
	local svc = require("svc")

	-- a read-only right to the same ESP server, offered under the name
	-- "espro". a service that only reads the disk names that instead of
	-- "esp". the distinction is which right it holds, not a check
	-- anywhere: see lib/dev.lua's readonly.
	-- do not give a public session "esp". espsrv holds diskport, so a
	-- holder can write the real boot volume.
	local grants = {}

	for k, v in pairs(caps_of) do
		grants[k] = v
	end

	-- a machine with no ESP, such as a board on flash, wants no warning.
	if caps_of.esp then
		local ok, roesp = pcall(require("mnt").readonly, caps_of.esp)

		if ok and type(roesp) == "number" then
			grants.espro = roesp
		else
			sys.log("svc: no read-only esp right (%s)", tostring(roesp))
		end
	end
	-- fw_cfg WINS over the disk. a host can therefore configure what
	-- this machine runs -- and hand it the service source too, under
	-- opt/org.luaos.svc/<name>.lua, resolved by svc.start before the
	-- namespace -- without modifying the image at all. that is what
	-- tools/website.lua does to enable webterm, which is deliberately
	-- commented out in the baked-in config.
	local injected = efi.fwcfg and efi.fwcfg("opt/org.luaos.services")
	local list, why

	if injected then
		list, why = svc.parse(injected, "fw_cfg:services")
	else
		list, why = svc.load(rootns, "/etc/services.lua")
	end

	if list then
		svc.start(list, {
			ns = nsdesc,
			granted = grants,
			-- fw_cfg first, then the disk. so a host can inject a
			-- service's SOURCE as well as the config that names
			-- it -- `-fw_cfg name=opt/org.luaos.svc/foo.lua` --
			-- and run something this image has never seen.
			-- NB the fw_cfg key stays opt/org.luaos.svc/ even
			-- though the directory is now task/: it is an
			-- external interface a host types on a qemu command
			-- line, so renaming it would break every invocation
			-- that exists for a tidiness nobody outside this
			-- repo can see.
			readfile = function(p)
				local base = tostring(p):match("([^/]+)$")
				local inj = base and efi.fwcfg and
				    efi.fwcfg("opt/org.luaos.svc/" .. base)

				return inj or rootns:readfile(p)
			end,
			log = sys.log,
			-- where a service that serves a filesystem belongs.
			-- One callback for every machine, because
			-- /etc/services.lua is one file for both machines: a
			-- mount declared there has to mean the same thing on
			-- either, and without this it silently meant nothing
			-- here.
			-- a name for a right, published into srvd, so a shell
			-- can say what it wants to mount -- a right is not a
			-- string, and there is otherwise no way to name a
			-- server at a prompt. sendright, not the handle: this
			-- proc keeps its own, and posting gives a right away.
			post = function(h, as, cap)
				require("srvc").post(h, as,
				    sys.sendright(cap))
			end,
			-- the backend an entry asked for. /srv is srvfs, which
			-- lists names rather than forwarding to a server, and
			-- everything else forwards.
			mount = function(prefix, h, fs)
				local mok, merr = pcall(function()
					assert(rootns:mount(prefix,
					    require(fs).new(h), fs,
					    { port = { __right = h } }))
				end)

				if not mok then
					return nil, merr
				end
				-- what later services are spawned with, and
				-- what the repl worker below inherits.
				nsdesc = rootns:describe()
				return nsdesc
			end,
			-- entropy for services that want it. absent on a
			-- machine whose firmware publishes no RNG, which
			-- makes a service that needs one fail loudly at its
			-- own drbg.new rather than quietly at a weaker one.
			seed = rng and rng.bytes or nil,
		})
		-- svc publishes a started service under its name, so this
		-- now holds the stack and the resolver as well as what the
		-- kernel granted.
		avail = grants
	elseif why and not why:match("^no ") then
		-- a missing config is a machine with no services, which is
		-- fine. a config that failed to load is a mistake worth saying.
		sys.log("svc: %s", tostring(why))
	end
end

-- repl worker: everything below runs as its own spawned proc, NOT
-- proc 0 itself, respawned fresh by the supervisor loop at the bottom
-- of this file every time a session ends (^d, or a crash) -- so any
-- globals/locals a session leaks (from testing, poking around, etc)
-- die with that lua_State instead of accumulating forever. proc 0
-- becomes a small permanent supervisor: it never runs a repl itself,
-- just hands each fresh worker the capabilities it needs and waits
-- for it to exit.
--
-- a plain string (not sys.spawn(function...)): the worker needs
-- CONS/WIRE/POWER/DISK/[TCP]/[UDP] handed to it via the {__right=}
-- message below, at handles it can't know until it receives them, so
-- it has to pull them out of that first message itself -- same shape
-- as the task servers above, not a closure over this scope (lua_dump
-- can't carry live upvalue values across to a different lua_State
-- anyway, only _ENV survives that trip).
local repl_worker_src = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	-- the firmware module, where the machine has firmware
	local ok_efi, efi = pcall(require, "los.efi")
	local powerc = require("client.power")
	local dnsc = require("client.dns")
	local tcpc = require("client.tcp")
	local udpc = require("client.udp")

	local m = thread.recv(sys.SELF)
	local consh = m.cons.__right
	local powerh = m.power.__right
	local diskh = m.disk.__right
	local tcph = m.tcp and m.tcp.__right
	-- the udp server is task/ip.lua: it answers open/send/recv/close
	-- on the datagram side of the same right that carries the stack's
	-- own config ops, and nothing publishes a capability called "udp".
	local udph = (m.udp and m.udp.__right) or (m.ip and m.ip.__right)
	local dnsh = m.dns and m.dns.__right
	local fbh = m.fb and m.fb.__right
	-- the panel keyboard, which bin/term.lua spends to hand the
	-- screen to a terminal of its own.
	local kbdh = m.kbd and m.kbd.__right
	-- the pointer, on the same terms as the screen. Nothing here reads
	-- it: it is for a program that takes the machine whole, and a
	-- machine without one lends none.
	local ptrh = m.ptr and m.ptr.__right
	-- the debug capability: a right to it debugs any proc, which is
	-- what reaches a boot service. The console gets it and dos
	-- inherits it; nothing else is offered one.
	local dbgh = m.dbg and m.dbg.__right

	-- pre-imported as bare globals (_G.x, not local x): the repl's
	-- evaluate() loads each typed line as its own chunk via load(),
	-- which gets a fresh _ENV pointing at _G -- locals from this
	-- chunk aren't visible there, only globals are.
	_G.sys = sys
	_G.thread = thread
	_G.efi = ok_efi and efi or nil
	-- ps, stats, ports, stack, trace, tracehist, halt and reboot are
	-- each a program in /bin, so a word here that shadows one is a
	-- second implementation to keep in step. Bound only where there is
	-- no launcher to run the programs from -- a machine with no root
	-- at all, where this prompt is the whole of the interface. See the
	-- call below.
	local function rescuewords()
		local ok_ps, magic = pcall(require, "ps")

		if not ok_ps then
			return
		end
		_G.ps = magic.ps
		_G.stats = magic.stats
		_G.ports = magic.ports
		_G.stack = function(pid)
			return magic.stack(pid or sys.self())
		end
		-- arming a trace is a real effect on the target -- a line
		-- hook costs the traced proc about 4.7x -- so it stays an
		-- explicit sys.set_trace rather than another word here.
		_G.trace = function(pid)
			return magic.trace(pid or sys.self())
		end
		_G.tracehist = function(pid, top)
			return magic.tracehist(pid or sys.self(), top)
		end
		_G.halt = magic.halt(powerh)
		_G.reboot = magic.reboot(powerh)
	end

	_G.power = powerc.new(powerh)
	local dns = dnsh and dnsc.new(dnsh) or nil

	_G.tcp = tcph and tcpc.new(tcph) or nil
	_G.udp = udph and udpc.new(udph) or nil
	_G.dnscap = dns
	-- a convenience, and the only one big enough to be worth leaving
	-- on the root it lives on: a machine whose root did not mount has
	-- no network configured either, so this is absent there rather
	-- than carried in the firmware against the chance. help lists what
	-- is bound, so it simply does not appear.
	local ok_http, http = pcall(require, "http")

	_G.http = ok_http and http or nil

	-- resolve: a real function (needs an argument) rather than a word
	-- that explains itself. plain nil when there's no dns capability
	-- (no NIC, no ip task, or dns task never spawned).
	_G.resolve = dns and dns.resolve or nil


	-- the console, handed to the launcher until you type exit. The
	-- namespace is this proc's own, so the launcher sees a mount the
	-- session made. No srv capability: `mount` reads /srv out of that
	-- same namespace. Power goes with it, because this console's repl
	-- already has halt() and bin/reboot.lua adds nothing a session
	-- here did not have -- a public session gets no such grant.
	local function startdos()
		require("dos").start({ ns = require("ns").current(),
		    cons = consh, fb = fbh, ptr = ptrh,
		    kbd = kbdh, net = tcph,
		    udp = udph, power = powerh, dbg = dbgh },
		    "lua-os. programs live in /bin; type exit to " ..
		    "return to lua.\n")
	end

	-- dos(): back to the launcher from the repl. Like halt it needs
	-- parens -- a bare __tostring must never do something this
	-- consequential.
	_G.dos = setmetatable({}, {
		__tostring = function()
			return "dos: type dos() to start the launcher"
		end,
		__call = function()
			local ok, err = pcall(startdos)

			if not ok then
				return "dos: " .. tostring(err)
			end
			return "back at the lua repl"
		end,
	})

	-- help: without it a bare word that is not defined just errors, and
	-- there was no way to discover dos() from the prompt. a word that
	-- only explains itself -- no parens, no effect. it lists only what
	-- is actually bound (tcp and resolve are nil with no NIC), so it
	-- never names a word that would error if you typed it, and a
	-- capability added here shows up without editing a recital.
	_G.help = setmetatable({}, {
		__tostring = function()
			local words = {
				{ "dos", "dos()", "back to the shell, where the programs are" },
				{ "ps", "ps", "the process table" },
				{ "stats", "stats", "scheduler counters" },
				{ "ports", "ports", "open ports" },
				{ "halt", "halt()", "power the machine off" },
				{ "reboot", "reboot()", "restart the machine" },
				{ "resolve", "resolve(name)", "look a name up over dns" },
				{ "tcp", "tcp", "the tcp capability" },
				{ "udp", "udp", "the udp capability" },
				{ "http", "http", "the http client" },
				{ "power", "power", "the power capability" },
			}
			local out = {
				"the lua prompt behind the shell -- any lua expression works.",
				"ps and the rest are programs where there is a /bin to run",
				"them from; `lua` there is this prompt with a program's rights.",
				"",
			}
			for _, w in ipairs(words) do
				if rawget(_G, w[1]) ~= nil then
					out[#out + 1] = ("  %-14s %s"):format(w[2], w[3])
				end
			end
			return table.concat(out, "\n")
		end,
	})

	local function evaluate(line)
		local chunk, err = load("return " .. line, "=repl")
		if not chunk then
			chunk, err = load(line, "=repl")
		end
		return chunk, err
	end

	-- The launcher first, the repl behind it. Not everything arriving
	-- at a console is typed by a person: a ZMODEM sender opens by
	-- writing "rz" at whatever prompt it finds, which a launcher
	-- answers and a lua prompt calls an undefined global. The repl is
	-- what is left when there is nothing to launch -- no /bin, or a
	-- root that never mounted -- and it is what you repair that from.
	local dosok, doserr = pcall(startdos)

	if not dosok then
		print("dos: " .. tostring(doserr) .. " -- the lua repl instead")
		rescuewords()
	end

	while true do
		local line = thread.readline(consh, "> ")
		if line == nil then
			break
		end
		if #line > 0 then
			local chunk, err = evaluate(line)
			while not chunk and err and err:sub(-5) == "<eof>" do
				local more = thread.readline(consh, ">> ")
				if more == nil then
					break
				end
				line = line .. "\n" .. more
				chunk, err = load(line, "=repl")
			end
			if chunk then
				-- xpcall's handler runs while the stack is
				-- still live (during unwinding), unlike a
				-- plain pcall -- that's what lets
				-- debug.traceback see anything.
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
]]

while true do
	local pid, worker = proc.spawn(repl_worker_src,
	    { name = "repl", ns = nsdesc })

	sys.monitor(pid)

	local grant = {
		cons = { __right = caps_of.cons },
		power = { __right = caps_of.power },
		disk = { __right = caps_of.disk },
	}
	if caps_of.dbg then
		grant.dbg = { __right = caps_of.dbg }
	end
	if avail.tcp then
		grant.tcp = { __right = avail.tcp }
	end
	-- the stack, which is what serves udp: there is no separate udp
	-- capability on any platform.
	if avail.ip then
		grant.ip = { __right = avail.ip }
	end
	if avail.dns then
		grant.dns = { __right = avail.dns }
	end
	if caps_of.fb then
		grant.fb = { __right = caps_of.fb }
	end
	if caps_of.kbd then
		grant.kbd = { __right = caps_of.kbd }
	end
	-- the pointer travels with the screen: what spends it is bin/win.lua,
	-- which hands both to a window system and takes them back.
	if caps_of.ptr then
		grant.ptr = { __right = caps_of.ptr }
	end
	-- no srv grant: the worker reaches the registry through /srv in
	-- the namespace it was spawned with, the same way it reaches the
	-- disk through /.
	sys.send(worker, grant)
	sys.close(worker)

	local m = thread.recv(sys.SELF)	-- {exit=pid, normal=, reason=?}

	print("")
	if m.normal then
		print("-- session ended, starting a new one --")
	else
		print("-- repl crashed: " .. tostring(m.reason) ..
		    " -- starting a new one --")
	end
end
