-- ZMODEM between two procs, in both directions, over real ports.
--
-- lib/zmodem.lua is sans-io and test/host_zmodem.lua already drives it
-- against itself with string buffers, which is where the awkward cases
-- live. What that cannot reach is this machine: a line that is a port
-- rather than a variable, a peer that is a separate Lua state with its
-- own heap and its own scheduler slice, messages bounded by MAXMSG, and
-- a clock that is the real one. Those are what turn a protocol that
-- terminates in a loop into one that terminates on hardware.
--
-- Both roles run here and neither end ever holds the file: the payload
-- is generated per block from its offset and checked per block against
-- the same function, so a 512KiB transfer costs one block of memory and
-- an offset. That is also the only way the guest can afford to check
-- it -- a proc's heap is not the place for a copy of both sides.

local sys = require("los.sys")
local thread = require("los.thread")
local proc = require("proc")
local zmodem = require("zmodem")
local tap = require("tap")

tap.plan(9)

-- src/crc.c is what a proc gets here and the Lua loops are what the
-- host test measures, so this is the one place the two are asked the
-- same question. A wrong table would otherwise show up as a transfer
-- that never completes.
tap.is(zmodem.crc16("123456789"), 0x31c3, "crc16 check vector")
tap.is(zmodem.crc32("123456789"), 0xcbf43926, "crc32 check vector")

local SIZE = 512 * 1024
local BLOCK = 4096

-- ---- the line ----
--
-- Writes are chunked and blocked against MAXQUEUE rather than fired at
-- it: a send that reports "full" and is ignored drops the message
-- silently, which on a byte stream is not a lost frame but a corrupt
-- one. sendblock is told the size, or it parks on "the queue is not
-- full" while this message still does not fit.
local LINE = [[
local function line(inport, outport)
	local sys = require("los.sys")
	local thread = require("los.thread")

	return {
		now = sys.uptime_ms,
		read = function(ms)
			return thread.recvtimeout(inport, ms)
		end,
		write = function(s)
			local i = 1

			while i <= #s do
				local c = s:sub(i, i + 8191)

				while not sys.send(outport, c) do
					sys.sendblock(outport, #c + 64)
				end
				i = i + #c
			end
		end,
	}
end
]]

-- the file: every byte determined by its offset, so a reader can seek
-- and a sink can check without either keeping any of it
local GEN = [[
local function gen(off, n)
	local b = {}

	for i = 1, n do
		b[i] = string.char(((off + i) * 37 + 11) & 0xff)
	end
	return table.concat(b)
end
]]

-- both helpers are source rather than functions because the child needs
-- the same two, and a function cannot travel in a message. This end
-- loads what it sends.
local line = load(LINE .. "return line")()
local gen = load(GEN .. "return gen")()

local function checker()
	local st = { bytes = 0 }

	st.sink = function()
		return {
			write = function(off, s)
				if off ~= st.bytes then
					st.bad = st.bad or "out of order"
				elseif s ~= gen(off, #s) then
					st.bad = st.bad or ("wrong bytes at " ..
					    off)
				end
				st.bytes = st.bytes + #s
			end,
		}
	end
	return st
end

-- ---- the child: sender first, then receiver ----

local up = sys.newport()	-- child -> parent
local down = sys.newport()	-- parent -> child
local report = sys.newport()

proc.spawn(LINE .. GEN .. [[
	local sys = require("los.sys")
	local zmodem = require("zmodem")
	local a = ...
	local l = line(a.rx.__right, a.tx.__right)
	local SIZE, BLOCK = a.size, a.block

	local tx = zmodem.sender({ name = "guest.bin", size = SIZE,
	    read = gen }, { blocksize = BLOCK, outmax = 16384 })
	local sent, serr = zmodem.drive(tx, l)

	local bytes, bad = 0, nil
	local rx = zmodem.receiver({ blocksize = BLOCK, outmax = 16384,
	    sink = function()
		return { write = function(off, s)
			if off ~= bytes then
				bad = bad or "out of order"
			elseif s ~= gen(off, #s) then
				bad = bad or ("wrong bytes at " .. off)
			end
			bytes = bytes + #s
		end }
	end })
	local got, rerr = zmodem.drive(rx, l)

	sys.send(a.report.__right, {
		sent = sent ~= nil, senterr = serr,
		got = got ~= nil and #got or 0, recverr = rerr,
		bytes = bytes, bad = bad,
		name = got and got[1] and got[1].name or "",
	})
]], {
	name = "zmodem",
	arg = {
		rx = { __right = down },	-- the child receives here
		tx = { __right = sys.sendright(up) },
		report = { __right = sys.sendright(report) },
		size = SIZE, block = BLOCK,
	},
})

-- ---- round one: the child sends, we receive ----

local mine = line(up, down)
local check = checker()
local rx = zmodem.receiver({ sink = check.sink, outmax = 16384 })
local t0 = sys.uptime_ms()
local files, err = zmodem.drive(rx, mine)
local ms = sys.uptime_ms() - t0

if tap.ok(files ~= nil, "received a transfer from another proc") then
	tap.is(#files, 1, "one file in the session")
	tap.is(files[1].name, "guest.bin", "with the name the sender gave")
	tap.is(check.bytes, SIZE, SIZE .. " bytes arrived")
	tap.ok(check.bad == nil, "and every block was right: " ..
	    tostring(check.bad))
else
	tap.diag(tostring(err))
	tap.ok(false, "one file in the session")
	tap.ok(false, "with the name the sender gave")
	tap.ok(false, "bytes arrived")
	tap.ok(false, "every block was right")
end
tap.diag(("%d bytes in %dms, %d KiB/s"):format(check.bytes, ms,
    ms > 0 and (check.bytes // ms) or 0))

-- ---- round two: we send, the child receives and checks ----

local tx = zmodem.sender({ name = "host.bin", size = SIZE, read = gen },
    { blocksize = BLOCK, outmax = 16384 })

t0 = sys.uptime_ms()

local sent, serr = zmodem.drive(tx, mine)

ms = sys.uptime_ms() - t0

tap.ok(sent ~= nil, "sent a transfer to another proc: " .. tostring(serr))

local r = thread.recvtimeout(report, 30000)

if r then
	tap.ok(r.got == 1 and r.bytes == SIZE and r.bad == nil and
	    r.name == "host.bin",
	    "and the other proc got all of it, unaltered")
	tap.diag(("child: got=%s bytes=%d bad=%s err=%s"):format(
	    tostring(r.got), r.bytes, tostring(r.bad), tostring(r.recverr)))
	tap.diag(("%d bytes in %dms, %d KiB/s"):format(SIZE, ms,
	    ms > 0 and (SIZE // ms) or 0))
else
	tap.ok(false, "the other proc got all of it, unaltered")
end

tap.done()
