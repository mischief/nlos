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
