-- sz: send files to a ZMODEM receiver on the far end of the console.
--
-- The counterpart of bin/rz.lua. A host runs lrz, or a terminal
-- program's receive-file, and this puts the bytes on the line.

local sys = require("los.sys")
local prog = require("prog")
local zmodem = require("zmodem")

local tty = prog.tty()

if not tty then
	io.stderr:write("sz: not a terminal\n")
	os.exit(1)
end

if #arg == 0 then
	io.stderr:write("usage: sz FILE...\n")
	os.exit(1)
end

-- a name and not a path, which is what the far end expects: a receiver
-- that honours a path writes wherever the sender says, and a sender has
-- no business steering it.
local function basename(s)
	return (tostring(s):gsub(".*/", ""))
end

local N = prog.ns()
local files, total = {}, 0

for _, path in ipairs(arg) do
	local c, err = N:open(path, "r")

	if not c then
		io.stderr:write("sz: " .. path .. ": " .. tostring(err) .. "\n")
		os.exit(1)
	end

	local st = c:stat()

	if not st or not st.size then
		io.stderr:write("sz: " .. path .. ": no size\n")
		os.exit(1)
	end
	total = total + st.size

	-- the reader takes an offset because ZRPOS rewinds, so the file is
	-- seeked rather than held: what is resident is one read, whatever
	-- the size of the file.
	files[#files + 1] = {
		name = basename(path),
		size = st.size,
		read = function(off, n)
			c:seek("set", off)
			return c:read(n) or ""
		end,
	}
end

-- A receiver that goes away cannot be noticed any other way: with the
-- window open a sender emits data frames back to back and reads
-- nothing until the file is behind it, so there is no ack to miss.
-- Abandoning matters because the console is the only way in -- a
-- sender still pushing bytes into it owns that line until a reset.
local BUDGET_MS = 30000 + total * 2
local started = sys.uptime_ms()
local GAVEUP = "sz: gave up: the receiver stopped answering"

local function overbudget()
	return sys.uptime_ms() - started > BUDGET_MS
end

local line = {
	now = sys.uptime_ms,
	-- raised from inside zmodem's callbacks, which is the only way out
	-- of its loop early. Caught below, so the console still gets
	-- cooked mode back.
	write = function(d)
		if overbudget() then
			error(GAVEUP, 0)
		end
		tty.write(d)
	end,
	read = function(ms)
		if overbudget() then
			error(GAVEUP, 0)
		end

		local d = tty.readraw(512, ms and math.max(ms, 1) or 1000)

		if d == "" then
			return nil
		end
		return d
	end,
}

-- raw, because the console rewrites bytes otherwise: a backend that
-- turns \n into \r\n corrupts every data frame, and one still watching
-- for the interrupt character would kill the transfer with the
-- transfer's own traffic.
tty.rawon()

-- yieldread: the reader parks on the file server, so the read must
-- happen outside the sender's coroutine. See lib/zmodem.lua's Mach:want.
-- the same bound the receiver keeps: a peer that went away must not
-- hold this console raw. See lib/zmodem.lua's M.drive.
local m = zmodem.sender(files, { yieldread = true, idle = 15000 })
local ok, res, err = pcall(zmodem.drive, m, line)

-- the receiver says "OO" after the session ends, and it arrives once we
-- have stopped reading. Left on the line it reaches the shell that
-- started us, which answers that OO is not a command.
tty.readraw(64, 200)
tty.rawoff()

if not ok then
	res, err = nil, tostring(res)
end

if not res then
	io.stderr:write("sz: " .. tostring(err) .. "\n")
	os.exit(1)
end
