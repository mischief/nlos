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

-- Everything below parks. Nothing here runs inside zmodem's coroutine:
-- the row fetch is a request the driver answers from outside it
-- (opts.yieldread), so sys.block reaches the kernel as it should.
local function recv(h)
	h = h or sys.SELF
	while true do
		local ok, m = sys.tryrecv(h)

		if ok then
			return m
		end
		sys.block(h)
	end
end

local job = recv()

-- rights arrive wrapped, as task/gefssrv.lua unwraps its blk: what
-- travels in a message is {__right = h}, not the handle.
local cons, fb = job.cons.__right, job.fb.__right

-- one reply port per server: rows are fetched while the transfer runs,
-- so fb and cons both have replies in flight and a single port would
-- hand a reader whichever landed first. task/9pexport.lua keeps a
-- replyport for the same reason.
local fbport = sys.newport()
local consport = sys.newport()

local function rpc(h, port, msg)
	msg.reply = { __right = port }
	sys.send(h, msg)
	return recv(port)
end

-- ask the panel rather than assume it: this runs on a 240x135
-- Cardputer and a 320x240 T-Deck, and a wrong width silently shears
-- the image instead of failing.
local mode = rpc(fb, fbport, { op = "mode" }).ok
local W = mode.w
local H = math.min(job.rows or mode.h, mode.h)
local stride = (W + 7) // 8
local header = ("P4\n%d %d\n"):format(W, H)
local size = #header + H * stride

-- PBM says 1 is BLACK, the shadow says 1 is lit. Inverted here rather
-- than in unload1, which hands back the plane as the device holds it.
local inv = {}

for i = 0, 255 do
	inv[string.char(i)] = string.char(~i & 0xff)
end

-- the image is never built. read() takes an offset so that a body can
-- be larger than memory: a row is fetched when the bytes about to go on
-- the wire fall in it, and only the current one is kept. ZRPOS can
-- rewind, which a plain generator could not serve -- but a row is
-- always recomputable from the panel.
local cached, cachedy = nil, -1

local function row(y)
	if y ~= cachedy then
		local r = rpc(fb, fbport,
		    { op = "unload1", r = { x = 0, y = y, w = W, h = 1 } })

		if not (r and r.ok) then
			error("unload1 row " .. y .. ": " ..
			    tostring(r and r.err), 0)
		end
		cached = (r.ok:gsub(".", inv))
		cachedy = y
	end
	return cached
end

local function readat(off, n)
	local out = {}
	local got = 0

	while got < n and off + got < size do
		local at = off + got

		if at < #header then
			local take = math.min(n - got, #header - at)

			out[#out + 1] = header:sub(at + 1, at + take)
			got = got + take
		else
			local b = at - #header
			local y = b // stride
			local within = b % stride
			local take = math.min(n - got, stride - within)

			out[#out + 1] = row(y):sub(within + 1, within + take)
			got = got + take
		end
	end
	return table.concat(out)
end

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
		local d = rpc(cons, consport, { op = "readraw", n = 512,
		    timeout = ms and math.max(ms, 1) or 1000 })

		if type(d) ~= "string" or d == "" then
			return nil
		end
		nin = nin + #d
		return d
	end,
}
-- yieldread: readat parks on fb for a row, so the read must happen
-- outside the sender's coroutine. See lib/zmodem.lua's Mach:want.
local m = zmodem.sender({ { name = job.name or "screen.pbm",
    size = size, read = readat } }, { yieldread = true })
local res, err = zmodem.drive(m, line)

sys.send(cons, { op = "rawoff" })
sys.send(cons, { op = "write", data = ("shot: %s %s %d bytes\n"):format(
    res and "ok" or "failed", res and "" or tostring(err), size) })
sys.send(cons, { op = "write", data = ("shot: out=%d in=%d\n"):format(
    nout, nin) })

-- tell the parent we are done. It has been holding off its readline all
-- this time on purpose: two procs asking cons for input means the shell
-- eats the receiver's headers, which is precisely what "unexpected
-- symbol near '*'" was.
if job.done then
	sys.send(job.done.__right, { ok = res ~= nil, err = tostring(err) })
end
