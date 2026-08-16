#!/usr/bin/env lua5.4
-- lib/ble/hci.lua against BlueZ's own virtual controller.
--
-- btvirt implements the specification independently, so its answers
-- check our encoding rather than echo it -- the reason the zmodem
-- tests run against real lrzsz. The codec is sans-io, so the first
-- half drives it with strings and no controller at all.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. scriptdir .. "/?.lua;" ..
    package.path

local hci = require("ble.hci")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
	io.flush()
end

local function hex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- ---- the codec alone ----

local RESET = hci.opcode(hci.OGF_HOST_CTL, 0x0003)

ok(RESET == 0x0c03, "opcode(3, 3) is 0x0c03")
ok(hci.opcode(hci.OGF_INFO, 0x0001) == 0x1001, "read local version is 0x1001")
ok(hci.opcode(hci.OGF_LE, 0x000a) == 0x200a, "le set advertise enable is 0x200a")

local h = hci.new()

h:command(RESET)
local out = h:pull()

ok(hex(out) == "01030c00", "reset on the wire is 01 03 0c 00")
ok(h:pull() == nil, "one credit, so nothing follows it")
ok(h:cmdcredits() == 0, "the credit was spent")

h:command(0x1001)
ok(h:pull() == nil, "a command with no credit waits")
ok(h:pending(), "and is still pending")

-- the controller answering restores the credit.
h:feed("\4\14\4\1\3\12\0")

local ev = h:next()

ok(ev and ev.kind == "complete", "command complete decoded")
ok(ev and ev.opcode == RESET, "carrying the opcode it answers")
ok(ev and ev.status == 0, "with status 0")
ok(h:cmdcredits() == 1, "and a credit back")
ok(hex(h:pull() or "") == "01011000", "which lets the queued one go")

-- a packet split across feeds must still frame by length.
local h2 = hci.new()

h2:feed("\4\14")
ok(h2:next() == nil, "half a header is not an event")
h2:feed("\4\1\3\12")
ok(h2:next() == nil, "still short by its last byte")
h2:feed("\0")
ok((h2:next() or {}).kind == "complete", "and completes on the last byte")

-- two packets in one feed.
local h3 = hci.new()

h3:feed("\4\14\4\1\3\12\0" .. "\4\14\4\1\1\16\0")
ok((h3:next() or {}).opcode == 0x0c03, "first of two in one read")
ok((h3:next() or {}).opcode == 0x1001, "and the second")

-- command status carries its credits in a different place.
local h4 = hci.new()

h4:command(0x2006)
h4:pull()
h4:feed("\4\15\4\0\2\6\32")
local st = h4:next()

ok(st and st.kind == "status" and st.opcode == 0x2006,
    "command status decoded")
ok(h4:cmdcredits() == 2, "with the credits it reported")

-- an LE meta event is handed up by subevent.
local h5 = hci.new()

h5:feed("\4\62\3\2\1\2")
local le = h5:next()

ok(le and le.kind == "le" and le.subevent == 2, "le meta by subevent")

-- acl in and out, and the buffer accounting that paces it.
local h6 = hci.new()

h6:aclbuffers(2)
h6:acl(0x0040, "hello")
ok(hex(h6:pull() or "") == "0240200500" .. hex("hello"),
    "acl framing: handle, pb flag, length")
h6:acl(0x0040, "x")
h6:acl(0x0040, "y")
ok(h6:pull() ~= nil, "a second fits in two buffers")
ok(h6:pull() == nil, "a third waits for one to come back")
h6:feed("\4\19\5\1\64\0\1\0")
ok((h6:next() or {}).kind == "complete_packets", "number of completed packets")
ok(h6:pull() ~= nil, "and the held packet goes")

local h7 = hci.new()

h7:feed("\4\2\9\1\2\3\4\5\6\7\8\9")
local raw = h7:next()

ok(raw and raw.kind == "event" and raw.code == 0x02,
    "an event we do not read is handed up whole")

-- ---- the trace format ----

local btsnoop = require("ble.btsnoop")

ok(hex(btsnoop.header()) == "6274736e6f6f700000000001000003ea",
    "btsnoop header: id, version 1, datalink 1002")

local rec = btsnoop.packet("\1\3\12\0", btsnoop.SENT, 1000000)

ok(#rec == 24 + 4, "a record is its 24-byte header and the packet")
ok(hex(rec:sub(1, 16)) == "00000004000000040000000000000000",
    "lengths both given, sent, no drops")
ok(hex(rec:sub(25)) == "01030c00", "and the packet follows unchanged")

local recv = btsnoop.packet("\4\14\4\1\3\12\0", btsnoop.RECV, 1000000)

ok(recv:byte(12) == 1, "an incoming packet is flagged as received")
ok(rec:sub(17, 24) == recv:sub(17, 24), "the same clock reads the same")

-- btmon is the reader this format exists for, so let it say.
local btmon = os.getenv("BTMON")

if btmon and btmon ~= "" then
	local path = os.tmpname()
	local f = assert(io.open(path, "wb"))

	f:write(btsnoop.header())
	f:write(btsnoop.packet("\1\3\12\0", btsnoop.SENT, 1000000))
	f:write(btsnoop.packet("\4\14\4\1\3\12\0", btsnoop.RECV, 1002000))
	f:close()

	local p = io.popen(btmon .. " -r " .. path .. " 2>&1")
	local said = p:read("a") or ""

	p:close()
	os.remove(path)
	ok(said:find("HCI Command: Reset", 1, true) ~= nil,
	    "btmon reads our trace and names the command")
	ok(said:find("Status: Success", 1, true) ~= nil,
	    "and decodes the event that answered it")
end

-- ---- against btvirt, where the build found one ----

local btvirt = os.getenv("BTVIRT")
local so = os.getenv("HOSTUTIL_SO")

if not btvirt or btvirt == "" or not so then
	io.write("# no btvirt: the codec ran, the controller did not\n")
	io.write("1.." .. count .. "\n")
	os.exit(failed == 0 and 0 or 1)
end

local hu = assert(package.loadlib(so, "luaopen_hostutil"))()

-- tcp on a port of our own, not the default unix socket: meson runs
-- tests in parallel and every btvirt would otherwise want the same
-- /tmp/bt-server-le. A long -s path is not the way out either -- it
-- overruns the controller's own sun_path buffer.
local port = hu.free_port()
local pid = hu.spawn({ btvirt, "-L", "-t" .. tostring(port) }, {})
local fd

for _ = 1, 50 do
	fd = hu.connect_tcp("127.0.0.1", port)
	if fd and fd >= 0 then
		break
	end
	os.execute("sleep 0.1")
end

ok(fd and fd >= 0, "connected to the virtual controller")
if not fd or fd < 0 then
	hu.kill(pid)
	hu.wait(pid)
	io.write("1.." .. count .. "\n")
	os.exit(1)
end

local c = hci.new()

-- one exchange: send whatever pull() gives, read whatever arrives, and
-- let the codec decide where a packet ends.
local function exchange(opcode, params, ms)
	c:command(opcode, params)

	local pkt = c:pull()

	assert(pkt, "no credit for " .. string.format("0x%04x", opcode))
	hu.send(fd, pkt)

	local deadline = hu.now() + (ms or 2000)

	while hu.now() < deadline do
		if hu.readable(fd, 0.2) then
			local got = hu.recv(fd, 4096)

			if not got or #got == 0 then
				return nil
			end
			c:feed(got)
		end
		local e = c:next()

		while e do
			if e.kind == "complete" and e.opcode == opcode then
				return e
			end
			e = c:next()
		end
	end
	return nil
end

local ev1 = exchange(RESET)

ok(ev1 and ev1.status == 0, "btvirt: reset answers status 0")

local ver = exchange(0x1001)

ok(ver and ver.status == 0, "btvirt: read local version answers")
ok(ver and #ver.params >= 8, "with the eight bytes the spec gives it")

local bufs = exchange(hci.opcode(hci.OGF_LE, 0x0002))

ok(bufs and bufs.status == 0, "btvirt: le read buffer size answers")

-- advertising, the exchange the board was proven with. Parameters are
-- refused while advertising is enabled, so this disables first.
exchange(hci.opcode(hci.OGF_LE, 0x000a), "\0")

local advp = exchange(hci.opcode(hci.OGF_LE, 0x0006),
    string.pack("<I2I2BBB", 0x00a0, 0x00f0, 0, 0, 0) ..
    string.rep("\0", 6) .. string.char(0x07, 0x00))

ok(advp and advp.status == 0, "btvirt: le set advertising parameters")

local name = "lua-os"
local ad = "\2\1\6" .. string.char(#name + 1, 0x09) .. name

local advd = exchange(hci.opcode(hci.OGF_LE, 0x0008),
    string.char(#ad) .. ad .. string.rep("\0", 31 - #ad))

ok(advd and advd.status == 0, "btvirt: le set advertising data")

local adve = exchange(hci.opcode(hci.OGF_LE, 0x000a), "\1")

ok(adve and adve.status == 0, "btvirt: advertising enabled")

hu.close(fd)
hu.kill(pid)
hu.wait(pid)

io.write("1.." .. count .. "\n")
os.exit(failed == 0 and 0 or 1)
