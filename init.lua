-- lua-os init (proc 0): spawn the 9p file server, then repl

local sys = require("los.sys")
local efi = require("los.efi")
local thread = require("los.thread")

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
local proc = require("proc")

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
rootns:mount("/", require("mnt").new(caps_of.esp), "mnt",
    { port = { __right = caps_of.esp } })
rootns:mount("/proc", require("procfs").new(), "procfs")
nsmod.setcurrent(rootns)


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

print(("%s on %s (fw rev 0x%x)"):format(_VERSION, efi.firmware,
    efi.firmware_revision))
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
-- it needs those mounts to be there to export them. tcp only exists when
-- a NIC was found at boot (see have_net in kernel.c).
local has_tcp = caps_of.tcp ~= nil

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
-- srvd: names for rights, so a shell can say what it wants to mount.
-- Without it `mount` has nothing to take an argument -- a right is not
-- a string, so there is no way to name a server at a prompt. See
-- lib/srvd.lua.
--
-- The listing mounts at /srv so `ls /srv` shows what is there; the
-- rights themselves come from messages to srvd, never from reading
-- those files.
local _, srvdh = proc.spawn(assert(rootns:readfile("/task/srvd.lua")),
    { name = "srv", ns = nsdesc })

if srvdh then
	-- the right goes in args so a child adopting this namespace can
	-- rebuild the backend, exactly as /net's mnt does
	rootns:mount("/srv", require("srvfs").new(srvdh), "srvfs",
	    { port = { __right = srvdh } })

	-- publish what is actually mountable. These are srv.lua-style
	-- servers, which is what mnt.new can forward to -- unlike the 9P
	-- export on tcp/7777, which speaks 9P to clients off the machine and
	-- has no port to hand out.
	--
	-- sendright, not the handle: init keeps its own, and posting is
	-- giving a right away.
	local srvc = require("srvc")

	srvc.post(srvdh, "esp", sys.sendright(caps_of.esp))
	if caps_of.dhcpd then
		srvc.post(srvdh, "net", sys.sendright(caps_of.dhcpd))
	end
end

-- the gefs partition, mounted so every session inherits it in the
-- namespace. blksrv is a kernel driver where the platform has a disk
-- (platform_have_blk); partsrv slices the gefs partition off it and
-- gefssrv serves the filesystem, the chain test/boot/microvm_gefspart
-- drives. Guarded: a machine with no disk, no gefs partition, or a volume
-- that will not open stays up without /n/gefs rather than failing to boot.
local gefs_mounted = false

if caps_of.blk then
	gefs_mounted = pcall(function()
		local _, ph = proc.spawn(
		    assert(rootns:readfile("/task/partsrv.lua")),
		    { name = "part", ns = nsdesc })

		sys.send(ph, { blk = { __right = caps_of.blk },
		    partition = "gefs" })

		local _, g = proc.spawn(
		    assert(rootns:readfile("/task/gefssrv.lua")),
		    { name = "gefs", ns = nsdesc })

		sys.send(g, { blk = { __right = ph }, label = "main" })
		rootns:mount("/n/gefs", require("mnt").new(g), "mnt",
		    { port = { __right = g } })
	end)
	sys.log(gefs_mounted and "gefs mounted at /n/gefs" or
	    "gefs: no volume mounted this boot")
end

-- the lease as a filesystem, at /net: addr, mask, gw, dns, ntp, domain,
-- one per file. This is how a program finds the resolver without
-- holding a right to dhcpd or being told an address at spawn -- see
-- task/dns.lua and bin/host.lua, which both just read /net/dns.
if caps_of.dhcpd then
	rootns:mount("/net", require("mnt").new(caps_of.dhcpd), "mnt",
	    { port = { __right = caps_of.dhcpd } })
end

-- RE-taken, because neither /net nor /srv existed when the first
-- description was made. dhcpd deliberately keeps the earlier one: it
-- SERVES /net, and a namespace containing a mount to itself is a loop
-- waiting to be walked. /n/gefs is taken in here too.
nsdesc = rootns:describe()

-- export the gefs subtree over 9P on the styx port, so `9fs host` or the
-- 9p tool can reach the same volume from off the machine. It is spawned
-- with the namespace above (which now holds /n/gefs) and told to export
-- that subtree: exactly `exportfs -r /n/gefs`, and a different root or a
-- differently-built namespace exports anything else the same way.
if gefs_mounted and caps_of.tcp then
	local _, xh = proc.spawn(
	    assert(rootns:readfile("/task/9pexport.lua")),
	    { name = "9pexport", ns = nsdesc })

	sys.send(xh, { net = { __right = caps_of.tcp },
	    root = "/n/gefs", port = 564 })
	sys.log("gefs exported over 9p on tcp/564")
end

-- and the whole namespace over tcp/7777: the same exportfs, rooted at "/"
-- instead of /n/gefs, so a client sees /net, /srv, /n, /proc and the ESP
-- together. This is where a synth "hello" tree used to be; now it is the
-- machine's real namespace, which is what 9P is for.
if has_tcp then
	local _, wh = proc.spawn(
	    assert(rootns:readfile("/task/9pexport.lua")),
	    { name = "9pexport-all", ns = nsdesc })

	sys.send(wh, { net = { __right = caps_of.tcp },
	    root = "/", port = 7777 })
	sys.log("9p server listening on tcp/7777")
end

-- dns server proc: resolves hostnames via lib/dns.lua, riding on the
-- udp task's capability -- not a kernel-level exclusive task itself
-- (no raw efi access of its own), same shape as the 9P export.
local _, dnssrv = proc.spawn(assert(rootns:readfile("/task/dns.lua")),
    { name = "dns", ns = nsdesc })
local has_dns = caps_of.ip and
    pcall(sys.send, dnssrv, { ip = { __right = caps_of.ip } })

if has_dns then
	sys.log("dns resolver ready")
end
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

	-- a read-only right to the same ESP server, offered to services under
	-- the name "espro". a service that only needs to READ the disk names
	-- that instead of "esp" and cannot write it -- and the distinction is
	-- which right it holds, not a check anywhere. see lib/dev.lua's
	-- readonly and lib/srv.lua's op.
	--
	-- NEVER give a public session "esp": espsrv holds diskport, so a
	-- holder can write the real boot volume.
	local grants = {}

	for k, v in pairs(caps_of) do
		grants[k] = v
	end

	local roesp = caps_of.esp and
	    select(2, pcall(require("mnt").readonly, caps_of.esp))

	if type(roesp) == "number" then
		grants.espro = roesp
	else
		sys.log("svc: no read-only esp right (%s)", tostring(roesp))
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
			-- entropy for services that want it. absent on a
			-- machine whose firmware publishes no RNG, which
			-- makes a service that needs one fail loudly at its
			-- own drbg.new rather than quietly at a weaker one.
			seed = rng and rng.bytes or nil,
		})
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
	local efi = require("los.efi")
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
	_G.efi = efi
	local magic = require("ps")
	_G.ps = magic.ps
	-- stack(pid): a cross-proc traceback. safe to call on anything,
	-- including a wedged proc, because every proc but this one is
	-- suspended between resumes.
	_G.stack = function(pid)
		return magic.stack(pid or sys.self())
	end
	-- trace(pid): the last lines a proc ran, once sys.set_trace(pid, n)
	-- has armed it. arming stays an explicit sys call rather than
	-- another magic word, because unlike everything else here it has an
	-- effect on the target -- a line hook costs the traced proc about
	-- 4.7x -- and that should be typed on purpose.
	_G.trace = function(pid)
		return magic.trace(pid or sys.self())
	end
	-- tracehist(pid): the same ring by cost, hottest line first. Needs
	-- the same explicit arming, for the same reason.
	_G.tracehist = function(pid, top)
		return magic.tracehist(pid or sys.self(), top)
	end
	_G.stats = magic.stats
	_G.ports = magic.ports
	_G.power = powerc.new(powerh)
	local dns = dnsh and dnsc.new(dnsh) or nil

	_G.tcp = tcph and tcpc.new(tcph) or nil
	_G.udp = udph and udpc.new(udph) or nil
	_G.dnscap = dns
	_G.http = require("http")

	-- resolve: a real function (needs an argument), not a bare
	-- magic word like ps/halt/stats. plain nil when there's no dns
	-- capability (no NIC, no ip task, or dns task never spawned).
	_G.resolve = dns and dns.resolve or nil

	-- see lib/ps.lua for why the effect needs parens and the bare
	-- word only explains itself.
	_G.halt = magic.halt(powerh)
	_G.reboot = magic.reboot(powerh)

	-- dos(): hand the console to the DOS-shaped launcher. it takes over
	-- input until you type exit, so like halt it needs parens -- a bare
	-- __tostring must never do something this consequential.
	--
	-- the lua repl stays the debugging tool underneath; dos is where you
	-- run programs from /bin. sh.lua and vi.lua, when they exist, are
	-- programs you start FROM dos rather than alternatives to it.
	_G.dos = setmetatable({}, {
		__tostring = function()
			return "dos: type dos() to start the launcher"
		end,
		__call = function()
			local launcher = require("dos")

			-- the proc's own namespace, inherited at spawn. it
			-- used to build a fresh one here, which meant the
			-- launcher could never see a mount the session had
			-- made.
			-- no srv capability: `mount` reads /srv out of this
			-- namespace, which the worker inherited.
			-- power goes with it: this is the boot console,
			-- whose repl already has halt(), so bin/reboot.lua
			-- adds no authority a session here did not have.
			-- A public session gets no such grant.
			launcher.start({ ns = require("ns").current(),
			    cons = consh, fb = fbh, net = tcph,
			    udp = udph, power = powerh, dbg = dbgh },
			    "lua-os. programs live in /bin; type exit to " ..
			    "return to lua.\n")
			return "back at the lua repl"
		end,
	})

	-- help: without it a bare word that is not defined just errors, and
	-- there was no way to discover dos() or halt() from the prompt. a word
	-- that only explains itself -- no parens, no effect -- like ps and
	-- stats. it lists only what is actually bound (tcp and resolve are nil
	-- with no NIC), so it never names a word that would error if you typed
	-- it, and a capability added here shows up without editing a recital.
	_G.help = setmetatable({}, {
		__tostring = function()
			local words = {
				{ "dos", "dos()", "the shell: run programs from /bin (help there lists them)" },
				{ "halt", "halt()", "power the machine off" },
				{ "reboot", "reboot()", "restart the machine" },
				{ "ps", "ps", "the process table" },
				{ "stats", "stats", "scheduler counters" },
				{ "ports", "ports", "open ports" },
				{ "resolve", "resolve(name)", "look a name up over dns" },
				{ "tcp", "tcp", "the tcp capability" },
				{ "udp", "udp", "the udp capability" },
				{ "http", "http", "the http client" },
			}
			local out = {
				"lua 5.4 repl -- any lua expression works. these words are built in",
				"(a bare word explains itself; parens do the thing):",
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
	if has_tcp then
		grant.tcp = { __right = caps_of.tcp }
	end
	-- the stack, which is what serves udp: there is no separate udp
	-- capability on any platform.
	if caps_of.ip then
		grant.ip = { __right = caps_of.ip }
	end
	if has_dns then
		grant.dns = { __right = dnssrv }
	end
	if caps_of.fb then
		grant.fb = { __right = caps_of.fb }
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
