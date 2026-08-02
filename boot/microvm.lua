-- the microvm boot payload of last resort: what proc 0 runs when no
-- fw_cfg payload was injected (src/platform/microvm/main.c). It is
-- embedded in the image at build time, so a machine with no fw_cfg file
-- service at all still boots to something usable.
--
-- OpenBSD vmd is the reason it exists, and the reason it is a repl
-- rather than a smoke test. vmd's fw_cfg (usr.sbin/vmd/fw_cfg.c) serves
-- a fixed set -- an e820 map and a bootorder string -- and has no way to
-- name a host file from vm.conf, so the mechanism every microvm test
-- uses to start code is simply not available there. This payload is the
-- only thing that can run, which means it had better be the thing you
-- want: a console.
--
-- It asks for nothing but the console. No virtio, no network, no mount:
-- those are the parts a new machine has not earned yet, and a payload
-- that blocks in a driver waiting for a device that is not there says
-- nothing on the serial line about why.

local sys = require("los.sys")
local thread = require("los.thread")

local caps = sys.granted()

require("stdout").set(caps.cons)

-- com1 is the keyboard and the 9p wire both, and a byte is delivered
-- once. Saying so is this payload's job, not the cons task's: a boot
-- whose serial line is carrying 9p wants the wire to keep it, so the
-- default stays the wire and an interactive payload asks. See
-- lib/cons.lua and src/platform/microvm/drivers.c.
sys.send(caps.cons, { op = "claim_input" })

local magic = require("ps")

_G.sys = sys
_G.thread = thread
_G.ps = magic.ps
_G.stats = magic.stats
_G.ports = magic.ports
_G.stack = function(pid)
	return magic.stack(pid or sys.self())
end
if caps.power then
	_G.halt = magic.halt(caps.power)
end

print(_VERSION .. " on microvm")
print("mach-lite kernel + plan9 furniture. ps, stats, stack(pid)" ..
    (caps.power and ", halt()" or ""))
print("")

-- the same two-step the efi repl does: try the line as an expression
-- first so a bare `ps` prints something, then as a statement.
local function evaluate(line)
	local chunk, err = load("return " .. line, "=repl")

	if not chunk then
		chunk, err = load(line, "=repl")
	end
	return chunk, err
end

-- no supervisor loop around this, unlike init.lua's repl: there is no
-- second proc to respawn from here and nothing to hand a fresh worker.
-- A session that ends ends the machine, which on a one-payload boot is
-- the honest behaviour.
while true do
	local line = thread.readline(caps.cons, "> ")

	if line == nil then
		break
	end

	if #line > 0 then
		local chunk, err = evaluate(line)

		if chunk then
			-- xpcall's handler runs while the stack is still live,
			-- unlike a plain pcall -- that is what lets
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

print("")
print("-- session ended --")
