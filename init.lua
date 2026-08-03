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

-- diagnostics are a different stream from output: stamped and tagged,
-- sharing kernel.c klog()'s format so the boot transcript reads as one
-- thing. see lib/log.lua.
local log = require("log")

log.set(caps_of.cons, "init")
log.log("entropy: %s", rng and "los.platform.rng" or
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
	log.log("granted: %s", table.concat(names, " "))
end

print(("%s on %s (fw rev 0x%x)"):format(_VERSION, efi.firmware,
    efi.firmware_revision))
print("mach-lite kernel + plan9 furniture (threads, channels, alt, 9p)")
print("")

-- 9p server proc: serves a synthetic namespace on com2. it gets a
-- send-right to wire in its first message -- wire is the sole task
-- with raw access to com2, both directions, so reading and writing
-- the 9p wire both mean sending it a message.
local _, ninesrv = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local p9 = require("ninep")
	local m = thread.recv(sys.SELF)
	local wire = m.wire.__right
	local readreply = sys.newport()

	local function wire_read()
		sys.send(wire, { op = "read",
		    reply = { __right = readreply } })
		return thread.recv(readreply)
	end

	local function wire_write(bytes)
		sys.send(wire, { op = "write", data = bytes })
	end

	local root = p9.synth({
		["README"] = "this is lua-os, mounted over 9p. hello!\n",
		["uname"] = "lua-os " .. sys.stats().arch .. " uefi\n",
		["version"] = _VERSION .. "\n",
		["ticks"] = function(off, n)
			if off > 0 then return "" end
			return tostring(sys.ticks()) .. "\n"
		end,
		["proc"] = { children = {
			["list"] = function(off, n)
				if off > 0 then return "" end
				local t = sys.procs()
				local out = {}
				for i, pid in ipairs(t) do
					out[i] = tostring(pid)
				end
				return table.concat(out, " ") .. "\n"
			end,
		}},
	})

	p9.serve(root, wire_read, wire_write)
]], { name = "9p" })

-- hand over a send-right to wire (proc 0 owns handle 2 at boot)
sys.send(ninesrv, { wire = { __right = caps_of.wire } })
print("9p server listening on com2 (mount me!)")

-- same namespace, served over tcp/7777 instead of the com2 wire, via
-- the tcp task's request/reply protocol (lib/tcp.lua) instead of
-- wire's. tcp only exists when a NIC was found at boot (see have_net
-- in kernel.c), in which case it appears in sys.granted().
local _, tcp9srv = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local p9 = require("ninep")
	local m = thread.recv(sys.SELF)
	local net = m.net.__right
	local replyport = sys.newport()

	local function req(op, extra)
		extra = extra or {}
		extra.op = op
		extra.reply = { __right = replyport }
		sys.send(net, extra)
		return thread.recv(replyport)
	end

	local function make_io(connid)
		local rx = function() return req("recv", { connid = connid, maxlen = 4096 }) end
		local tx = function(bytes) req("send", { connid = connid, data = bytes }) end
		return rx, tx
	end

	local root = p9.synth({
		["README"] = "this is lua-os, mounted over 9p-over-tcp. hello!\n",
		["uname"] = "lua-os " .. sys.stats().arch .. " uefi\n",
		["version"] = _VERSION .. "\n",
	})

	-- a listen before an address exists fails with EFI_NO_MAPPING, so
	-- retry. this used to allow fifteen seconds because it was waiting
	-- out the firmware's own dhcp; init now runs lib/dhcpd.lua, which
	-- has an address in ~15ms, so the only thing left to cover is being
	-- scheduled before it finishes. thread.sleep parks, so this costs
	-- no cpu either way.
	local listener
	for _ = 1, 20 do
		listener = req("listen", { port = 7777 })
		if listener then
			break
		end
		thread.sleep(50)
	end
	if not listener then
		return
	end
	while true do
		local conn = req("accept", { connid = listener })
		if conn then
			local rx, tx = make_io(conn)
			-- a client dropping the tcp connection mid-request (no
			-- clean Tclunk) makes rx() return nil; ninep.lua isn't
			-- eof-hardened for that, so pcall keeps one bad
			-- connection from taking the whole listener down.
			pcall(p9.serve, root, rx, tx)
			-- fire-and-forget: tcp.lua's "close" handler never
			-- replies (see lib/tcp.lua's op table comment), so
			-- this must NOT go through req()/thread.recv or it
			-- deadlocks forever waiting on a reply that never
			-- comes -- which then wedges this proc and silently
			-- stops it from ever accepting again.
			sys.send(net, { op = "close", connid = conn })
		end
	end
]], { name = "9ptcp" })

local has_tcp = caps_of.tcp ~= nil
local has_udp = caps_of.udp ~= nil

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
local dhcpd = nil

if has_tcp and has_udp then
	-- the rights ride in the spawn ARG, not a first message: dhcpd's own
	-- port is srv.serve's, and a message arriving there would have to be
	-- consumed before serving began and never after. rights travel
	-- through arg exactly as through a message (api_spawn's comment).
	local pid, h = proc.spawn(assert(rootns:readfile("/task/dhcpd.lua")),
	    { name = "dhcp", ns = nsdesc, arg = {
	        tcp = { __right = caps_of.tcp },
	        udp = { __right = caps_of.udp },
	    } })

	if pid then
		dhcpd = h
		-- the lease as a filesystem, at /net. mounted BEFORE nsdesc
		-- is taken below, so every child inherits it -- which is how
		-- lib/dns.lua finds its resolver without holding a right to
		-- dhcpd or being told an address at spawn time.
		rootns:mount("/net", require("mnt").new(h), "mnt",
		    { port = { __right = h } })
	end
end

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
	-- servers, which is what mnt.new can forward to -- unlike ninesrv
	-- and tcp9srv above, which speak 9P over a byte wire to clients
	-- off the machine and have no port to hand out.
	--
	-- sendright, not the handle: init keeps its own, and posting is
	-- giving a right away.
	local srvc = require("srvc")

	srvc.post(srvdh, "esp", sys.sendright(caps_of.esp))
	if dhcpd then
		srvc.post(srvdh, "net", sys.sendright(dhcpd))
	end
end

-- RE-taken, because neither /net nor /srv existed when the first
-- description was made. dhcpd deliberately keeps the earlier one: it
-- SERVES /net, and a namespace containing a mount to itself is a loop
-- waiting to be walked.
nsdesc = rootns:describe()

if has_tcp then
	sys.send(tcp9srv, { net = { __right = caps_of.tcp } })
	print("9p server listening on tcp/7777 (mount me!)")
end
-- no NIC: tcp9srv just sits parked in thread.recv(sys.SELF) forever,
-- same as any other never-sent-to blocked proc -- harmless.

-- dns server proc: resolves hostnames via lib/dns.lua, riding on the
-- udp task's capability -- not a kernel-level exclusive task itself
-- (no raw efi access of its own), same shape as ninesrv/tcp9srv.
local _, dnssrv = proc.spawn(assert(rootns:readfile("/task/dns.lua")),
    { name = "dns", ns = nsdesc })
local has_dns = has_udp and
    pcall(sys.send, dnssrv, { udp = { __right = caps_of.udp } })

if has_dns then
	print("dns resolver ready")
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
		log.log("svc: no read-only esp right (%s)", tostring(roesp))
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
			log = print,
			-- entropy for services that want it. absent on a
			-- machine whose firmware publishes no RNG, which
			-- makes a service that needs one fail loudly at its
			-- own drbg.new rather than quietly at a weaker one.
			seed = rng and rng.bytes or nil,
		})
	elseif why and not why:match("^no ") then
		-- a missing config is a machine with no services, which is
		-- fine. a config that failed to LOAD is a mistake worth saying.
		print("svc: " .. tostring(why))
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
-- as ninesrv/tcp9srv above, not a closure over this scope (lua_dump
-- can't carry live upvalue values across to a different lua_State
-- anyway, only _ENV survives that trip).
local repl_worker_src = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local efi = require("los.efi")
	local caps = require("caps")

	local m = thread.recv(sys.SELF)
	local consh = m.cons.__right
	local wireh = m.wire.__right
	local powerh = m.power.__right
	local diskh = m.disk.__right
	local tcph = m.tcp and m.tcp.__right
	local udph = m.udp and m.udp.__right
	local dnsh = m.dns and m.dns.__right
	local fbh = m.fb and m.fb.__right

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
	_G.caps = caps
	_G.wire = caps.wire(wireh)
	_G.power = caps.power(powerh)
	local dns = dnsh and caps.dns(dnsh) or nil

	_G.tcp = tcph and caps.tcp(tcph) or nil
	_G.udp = udph and caps.udp(udph) or nil
	_G.dnscap = dns
	_G.http = require("http")

	-- resolve: a real function (needs an argument), not a bare
	-- magic word like ps/halt/stats. plain nil when there's no dns
	-- capability (no NIC, no udp4 driver, or dns task never spawned).
	_G.resolve = dns and dns.resolve or nil

	-- see lib/ps.lua for why the effect needs parens and the bare
	-- word only explains itself.
	_G.halt = magic.halt(powerh)

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
			launcher.start({ ns = require("ns").current(),
			    cons = consh, fb = fbh },
			    "lua-os. programs live in /bin; type exit to " ..
			    "return to lua.\n")
			return "back at the lua repl"
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
		wire = { __right = caps_of.wire },
		power = { __right = caps_of.power },
		disk = { __right = caps_of.disk },
	}
	if has_tcp then
		grant.tcp = { __right = caps_of.tcp }
	end
	if has_udp then
		grant.udp = { __right = caps_of.udp }
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
