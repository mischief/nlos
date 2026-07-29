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

	-- Configure() self-triggers DHCP but doesn't block for it (see
	-- kernel.c/net.c's EFI_NO_MAPPING handling); retry listen for a
	-- few real seconds rather than giving up on the first attempt.
	-- thread.sleep parks, so this costs no cpu while dhcp completes --
	-- it used to spin on sys.ticks(), which pegged the machine for the
	-- whole of boot.
	local listener
	for _ = 1, 60 do
		listener = req("listen", { port = 7777 })
		if listener then
			break
		end
		thread.sleep(250)
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

if has_tcp then
	sys.send(tcp9srv, { net = { __right = caps_of.tcp } })
	print("9p server listening on tcp/7777 (mount me!)")
end
-- no NIC: tcp9srv just sits parked in thread.recv(sys.SELF) forever,
-- same as any other never-sent-to blocked proc -- harmless.

-- dns server proc: resolves hostnames via lib/dns.lua, riding on the
-- udp task's capability -- not a kernel-level exclusive task itself
-- (no raw efi access of its own), same shape as ninesrv/tcp9srv.
local _, dnssrv = sys.spawn(io.open("/lib/dns.lua"):read("a"),
    { name = "dns" })
local has_dns = has_udp and
    pcall(sys.send, dnssrv, { udp = { __right = caps_of.udp } })

if has_dns then
	print("dns resolver ready")
end
print("")

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
	_G.stats = magic.stats
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
			local nsmod = require("ns")
			local espfs = require("espfs")
			local launcher = require("dos")
			local N = nsmod.new()

			N:mount("/", espfs.new("/"), "espfs", { root = "/" })
			N:mount("/proc", require("procfs").new(), "procfs")
			launcher.start({ ns = N, cons = consh },
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
	local pid, worker = sys.spawn(repl_worker_src, { name = "repl" })

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
