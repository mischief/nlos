-- serial receive, from the guest end.
--
-- The console and the 9p wire are the same port here, so this payload
-- both reads input and reports on it over one connection. It echoes
-- what it receives with a marker the harness can find, rather than
-- emitting TAP itself -- the assertions live in test/microvm_serial.lua,
-- which is what knows what it sent.
--
-- Written because the absence of this test cost a lot. Serial receive
-- worked the whole time it was believed broken; what was broken was a
-- throwaway payload that looked for msg.data on a message lib/wire.lua
-- delivers as a bare string. A false negative is indistinguishable from
-- a dead driver unless something exercises the real path.

local sys = require("los.sys")
local thread = require("los.thread")
local stdout = require("stdout")

stdout.set(sys.granted().cons)

local wire = sys.granted().wire

if not wire then
	print("SERIALRX nowire")
	sys.send(sys.granted().power, { op = "reset" })
	return
end

print("SERIALRX ready")

local rp = sys.newport("microvm_serialr")
local deadline = sys.uptime_ms() + 15000
local got = {}

-- one outstanding read at a time: lib/wire.lua holds a single pending
-- reply right and closes any earlier one, so asking twice without
-- waiting loses the first.
sys.send(wire, { op = "read", reply = { __right = sys.sendright(rp) } })

while sys.uptime_ms() < deadline do
	local ok, m = sys.tryrecv(rp)

	if ok then
		-- a bare string, not a table. This is the shape the whole
		-- investigation got wrong.
		got[#got + 1] = tostring(m)
		print("SERIALRX got:" .. tostring(m))

		if #table.concat(got) >= 5 then
			break
		end
		sys.send(wire, { op = "read",
		    reply = { __right = sys.sendright(rp) } })
	else
		thread.sleep(20)
	end
end

print("SERIALRX done:" .. table.concat(got))
sys.send(sys.granted().power, { op = "reset" })
