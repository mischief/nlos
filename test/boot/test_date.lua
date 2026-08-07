-- date, against an ntp server served by this test over loopback.
--
-- No internet and no clock to compare against: the test IS the server,
-- so the answer is a constant chosen here and the assertion is that the
-- program prints that instant. A test that asked a real server could
-- only check the format.
--
-- 127.0.0.1 because it needs no link, no arp and no lease -- see
-- test/boot/microvm_loopback.lua, which is where that is established.
local sys = require("los.sys")
local dos = require("dos")
local ns = require("ns")
local thread = require("los.thread")
local caps = require("caps")
local ntp = require("ntp")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(7)

-- the ip task exists only where the machine has a NIC, so this test
-- runs in the NET group. Bailing rather than crashing matters anyway:
-- caps.udp(nil) faults inside the capability wrapper, which reports a
-- bad argument to sys.call and says nothing about the missing task.
if not tap.ok(caps_of.ip ~= nil, "the ip task is running") then
	tap.done()
	return
end

local N = ns.new()

N:mount("/", require("mnt").new(caps_of.esp), "mnt",
    { port = { __right = caps_of.esp } })

-- 2026-08-07 05:45:37 UTC, as unix seconds, and the same in the NTP
-- epoch. Written both ways on purpose: the offset between them is the
-- thing lib/ntp.lua gets right or wrong, and a test that computed it
-- the same way the code does would agree with a wrong answer.
local WHEN_UNIX = 1786081537
local WHEN_NTP = WHEN_UNIX + 2208988800
local WHEN_TEXT = "2026-08-07 05:45:37 UTC"

-- a server reply: mode 4 (server), stratum 2, and the transmit
-- timestamp at offset 41, which is the only field ntp.decode reads for
-- the time.
local function reply()
	local p = { string.char(0x24), string.char(2), string.char(0),
	    string.char(0xec) }

	for _ = 5, 40 do
		p[#p + 1] = "\0"
	end
	p[#p + 1] = string.pack(">I4I4", WHEN_NTP, 0)
	return table.concat(p)
end

local udp = caps.udp(caps_of.ip)
local conn = udp.open(ntp.PORT)

tap.ok(conn ~= nil, "bound udp/123 to answer as the server")

-- serve exactly one query, then stop: the program asks once and gets an
-- answer, so a server that looped would never let thread.run return.
local served = false

local function serve()
	local m = udp.recv(conn)

	if type(m) == "table" and m.data and #m.data >= ntp.PKTLEN then
		served = true
		udp.send(conn, m.a, m.b, m.c, m.d, m.port, reply())
	end
end

local function collector()
	local port = sys.newport("test_date")
	local out = {}

	return sys.sendright(port), function()
		while true do
			local ok, m = sys.tryrecv(port)

			if not ok then
				local s = table.concat(out)

				for i = #out, 1, -1 do
					out[i] = nil
				end
				return s
			end
			if m and m.op == "write" then
				out[#out + 1] = m.data
			end
		end
	end
end

local cons, drain = collector()
local sh = dos.new({ ns = N, cons = cons, udp = caps_of.ip })

local status

thread.spawn(serve)
thread.spawn(function()
	status = sh:run("date 127.0.0.1")
end)
thread.run()

tap.ok(served, "the program sent a query")
tap.is(status, 0, "and exited 0")
tap.is(drain(), WHEN_TEXT .. "\n", "and printed the instant we served")

-- ---- no server to be found ----
--
-- /net is not in this namespace, so there is nothing to read: the
-- failure names what is missing rather than asking an address made up
-- here.
tap.is(dos.once(sh, "date"), 1, "with no server named, date fails")
tap.ok(drain():find("no ntp server"), "and says so")

tap.done()
