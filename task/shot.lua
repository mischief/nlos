-- shot: send the framebuffer to the host over ZMODEM, then exit.
--
-- A proc of its own because that is the only way it fits. lib/zmodem.lua
-- costs about 30KB resident and the image is another 4KB, and the repl
-- that would otherwise host both is already 63KB on a board with ~120KB
-- free. Spawning means the cost is paid for the length of a transfer
-- and handed back at exit, rather than kept for the life of the shell.
--
-- No los.thread either, for the same reason task/power.lua has none:
-- this is one loop with no concurrency, and thread.recv on a proc with
-- no threads is exactly the tryrecv/block below -- for which it costs
-- another 24KB. sys.SELF serves as the reply port because nothing else
-- is talking to us.
--
-- Spawned with a message carrying its rights and the job:
--	{ cons = {__right=}, fb = {__right=}, name = , rows = }

local sys = require("los.sys")

local function recv()
	while true do
		local ok, m = sys.tryrecv(sys.SELF)

		if ok then
			return m
		end
		sys.block(sys.SELF)
	end
end

local job = recv()

-- rights arrive wrapped, as task/gefssrv.lua unwraps its blk: what
-- travels in a message is {__right = h}, not the handle.
local cons, fb = job.cons.__right, job.fb.__right

local function rpc(h, msg)
	msg.reply = { __right = sys.SELF }
	sys.send(h, msg)
	return recv()
end

-- ask the panel rather than assume it: this runs on a 240x135
-- Cardputer and a 320x240 T-Deck, and a wrong width silently shears
-- the image instead of failing.
local mode = rpc(fb, { op = "mode" }).ok
local W = mode.w
local H = math.min(job.rows or mode.h, mode.h)

-- unload1 hands back the shadow's own bits, already packed the way PBM
-- wants them. unload would give 960 bytes per row for us to turn into
-- 30, and that garbage is what would not fit.
local parts = { ("P4\n%d %d\n"):format(W, H) }

for y = 0, H - 1 do
	local r = rpc(fb, { op = "unload1", r = { x = 0, y = y, w = W, h = 1 } })

	if not (r and r.ok) then
		sys.send(cons, { op = "write", data = "shot: unload1 row " ..
		    y .. ": " .. tostring(r and r.err) .. "\n" })
		return
	end
	parts[#parts + 1] = r.ok

	-- every row is a fresh reply table and a fresh string, and the
	-- collector left to its own pacing runs behind that on a board
	-- with no headroom. Stepping here keeps the garbage from being
	-- live at the same time as the image it is being built into.
	if y % 16 == 15 then
		collectgarbage("step")
	end
end

-- PBM says 1 is BLACK; the shadow says 1 is lit. Inverting here rather
-- than in unload1, which hands back the bit plane as the device holds
-- it and should not know what a netpbm file is.
local inv = {}

for i = 0, 255 do
	inv[string.char(i)] = string.char(~i & 0xff)
end

for i = 2, #parts do
	parts[i] = parts[i]:gsub(".", inv)
end

local pbm = table.concat(parts)

parts = nil
collectgarbage()

local zmodem = require("zmodem")

sys.send(cons, { op = "rawon" })

local nin, nout = 0, 0
local line = {
	now = sys.uptime_ms,
	write = function(d)
		nout = nout + #d
		sys.send(cons, { op = "write", data = d })
	end,
	-- one round trip for the whole of what is queued. Draining with
	-- getch instead costs a message each way per byte, which measured
	-- about 1KB/s on a 115200 line -- slow enough that the receiver
	-- gave up mid-transfer, so it read as a protocol fault rather
	-- than as the cost of asking.
	read = function(ms)
		local d = rpc(cons, { op = "readraw", n = 2048,
		    timeout = ms and math.max(ms, 1) or 1000 })

		if type(d) ~= "string" or d == "" then
			return nil
		end
		nin = nin + #d
		return d
	end,
}
local m = zmodem.sender({ { name = job.name or "screen.pbm", data = pbm } })
local res, err = zmodem.drive(m, line)

sys.send(cons, { op = "rawoff" })
sys.send(cons, { op = "write", data = ("shot: %s %s %d bytes\n"):format(
    res and "ok" or "failed", res and "" or tostring(err), #pbm) })
sys.send(cons, { op = "write", data = ("shot: out=%d in=%d\n"):format(
    nout, nin) })

-- tell the parent we are done. It has been holding off its readline all
-- this time on purpose: two procs asking cons for input means the shell
-- eats the receiver's headers, which is precisely what "unexpected
-- symbol near '*'" was.
if job.done then
	sys.send(job.done.__right, { ok = res ~= nil, err = tostring(err) })
end
