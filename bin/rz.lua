-- rz: receive files over ZMODEM, onto the console this was started on.
--
-- The name is the interface. A ZMODEM sender writes "rz\r" at the far
-- end before its first header, so a launcher that finds this in /bin
-- completes the handshake with nothing typed here: picocom's send-file
-- and lrzsz's sz need no argument and no cooperation.

local sys = require("los.sys")
local prog = require("prog")
local zmodem = require("zmodem")

local tty = prog.tty()

if not tty then
	io.stderr:write("rz: not a terminal\n")
	os.exit(1)
end

local N = prog.ns()
local dir = arg[1]

-- the name comes from the far end, so it is a basename and nothing
-- else. A sender that offers "../etc/services.lua" is asking to write
-- outside the directory it was pointed at, and there is no reason to
-- let it.
local function basename(s)
	return (tostring(s or ""):gsub(".*/", ""))
end

-- how much to hold before writing. A subpacket is 1024 bytes and a
-- flash erase block is 4096, so writing each one as it lands costs the
-- filesystem a read, edit and write of the whole block four times over.
local WBUF = 4096

local got = {}
-- the file being written, if any. The receiver closes a sink it
-- finished and says nothing about one it abandoned, so an aborted
-- transfer leaves the descriptor here for the exit path to take.
local open = nil

-- a sink, not a data field: the receiver never rewinds, so bytes go to
-- the file as they arrive and no whole file is ever resident. That is
-- what makes the size of a transfer independent of free memory.
local function sink(info)
	local name = basename(info.name)

	if name == "" then
		error("rz: the sender offered no name", 0)
	end

	local path = dir and (dir .. "/" .. name) or name
	-- create first, open second: a file arriving from the far end
	-- usually does not exist yet, and open only walks to one that
	-- does. The order also makes the common case one round trip.
	local fd, cerr = N:create(path, "w")
	local oerr

	if not fd then
		fd, oerr = N:open(path, "w")
	end
	if not fd then
		-- both reasons, because they differ: a create refused by a
		-- read-only mount and an open of a name that is not there
		-- are the same nil to a caller and not the same fault.
		error("rz: " .. path .. ": create: " .. tostring(cerr) ..
		    ", open: " .. tostring(oerr), 0)
	end

	local wrote = 0
	local buf, buflen = {}, 0

	local function flush()
		if buflen == 0 then
			return
		end
		fd:write(table.concat(buf))
		buf, buflen = {}, 0
	end

	open = fd
	return {
		-- in order and no gaps, which the receiver promises. Checked
		-- rather than trusted: a silent seek would write a file that
		-- is the right length and wrong throughout.
		write = function(off, s)
			if off ~= wrote then
				error("rz: out of order at " .. off, 0)
			end

			buf[#buf + 1] = s
			buflen = buflen + #s
			wrote = wrote + #s
			if buflen >= WBUF then
				flush()
			end
		end,
		close = function(ok)
			flush()
			fd:close()
			open = nil
			if ok then
				got[#got + 1] = { name = path, size = wrote }
			end
		end,
	}
end

local line = {
	now = sys.uptime_ms,
	write = function(d)
		tty.write(d)
	end,
	-- one round trip for the whole of what is queued. A byte at a
	-- time through getch measures about 1KB/s on a 115200 line, slow
	-- enough that the sender gives up mid-transfer and the failure
	-- reads as a protocol fault rather than as the cost of asking.
	read = function(ms)
		local d = tty.readraw(4096, ms and math.max(ms, 1) or 1000)

		if d == "" then
			return nil
		end
		return d
	end,
}

-- raw, because the console rewrites bytes otherwise: esp32's turns \n
-- into \r\n, which corrupts every data frame, and a console still
-- watching for the interrupt character would kill the transfer with
-- the transfer's own traffic.
tty.rawon()

-- yieldwrite: the sink parks on the file server, so the writes happen
-- outside the receiver's coroutine. See lib/zmodem.lua's Mach:sinkcall.
-- What this receiver can really do, which is not what the default
-- says. A write parks this proc and nothing reads the line meanwhile,
-- so it cannot take bytes during disk io: overlap = false says so, and
-- the window bounds what may arrive before we ack. Our own sz honours
-- both. lrzsz honours neither and streams regardless -- see docs.
local WINDOW = 8192

-- a sender that was killed says nothing more, and the console is raw
-- until this returns: without a bound the board needs a reset to type
-- at again. Long enough that a slow write is never mistaken for it.
local IDLE = 15000

local m = zmodem.receiver({ sink = sink, yieldwrite = true,
    window = WINDOW, overlap = false, idle = IDLE })
-- pcall, because a sink that fails leaves by raising: the console must
-- get cooked mode back either way, or the shell returns with no line
-- editing and nothing on screen to say why.
local ok, res, err = pcall(zmodem.drive, m, line)

-- the far end says "OO" after the session ends, and it arrives once we
-- have stopped reading. Left on the line it reaches the shell that
-- started us, which answers that OO is not a command.
tty.readraw(64, 200)
tty.rawoff()

if open then
	open:close()
end

if not ok then
	res, err = nil, tostring(res)
end

for _, f in ipairs(got) do
	io.write(("rz: %s %d bytes\n"):format(f.name, f.size))
end

-- why anything was asked for twice, counted apart because the two
-- reasons call for opposite fixes: "crc" is bytes that arrived wrong,
-- which on a line means bytes lost, and "timeout" is bytes that did
-- not arrive at all.
if m.rejects then
	local out = {}

	for why, n in pairs(m.rejects) do
		out[#out + 1] = ("%s %d"):format(tostring(why), n)
	end
	table.sort(out)
	io.stderr:write("rz: retried: " .. table.concat(out, ", ") .. "\n")
end

if not res then
	io.stderr:write("rz: " .. tostring(err) .. "\n")
	os.exit(1)
end
