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

-- started either way: the launcher hands the job to the chunk as its
-- argument; started by hand from the repl, it arrives in a message.
local job = ... or recv()

-- rights arrive wrapped, as task/gefssrv.lua unwraps its blk: what
-- travels in a message is {__right = h}, not the handle.
local cons, fb = job.cons.__right, job.fb.__right

-- one reply port per server: rows are fetched while the transfer runs,
-- so fb and cons both have replies in flight and a single port would
-- hand a reader whichever landed first. task/9pexport.lua keeps a
-- replyport for the same reason.
local fbport = sys.newport("shot.fbport")
local consport = sys.newport("shot.consport")
-- send only for the far end: {__right=} copies the recv flag, so the
-- ports as created would let fb and cons receive our own answers
local fbright = sys.sendright(fbport)
local consright = sys.sendright(consport)
local sendright = { [fbport] = fbright, [consport] = consright }

-- A full queue drops a bare send, and what is dropped here is the
-- request this then waits forever for an answer to.
local function rpc(h, port, msg)
	msg.reply = { __right = sendright[port] }

	local ok, why = sys.send(h, msg)

	while not ok and why == "full" do
		sys.sendblock(h)
		ok, why = sys.send(h, msg)
	end
	if not ok then
		error("send: " .. tostring(why), 0)
	end
	return recv(port)
end

-- ask the panel rather than assume it: the size differs from board to
-- board, and a wrong width silently shears the image instead of
-- failing.
local mode = rpc(fb, fbport, { op = "mode" }).ok
local W = mode.w
local H = math.min(job.rows or mode.h, mode.h)
local stride = W * 3
local header = ("P6\n%d %d\n255\n"):format(W, H)
local size = #header + H * stride

-- the screen as it is now, held by the fb task for the length of the
-- transfer. A band is fetched when the bytes going on the wire fall in
-- it, which spans seconds: read from the glass, each band comes from a
-- different moment and a screen that moves comes back as a composite.
local snap = rpc(fb, fbport, { op = "snap" }).ok
local snapid = snap and snap.id

-- the image is never built. read() takes an offset so that a body can
-- be larger than memory: a row is fetched when the bytes about to go on
-- the wire fall in it, and only the current one is kept. ZRPOS can
-- rewind, which a plain generator could not serve -- but a row is
-- always recomputable from the snapshot.
--
-- unload hands back real colors where the driver keeps a color copy, or
-- black and white where the shadow is one bit per pixel.
--
-- fmt="rgb" asks for the three bytes PPM wants, which task/fb.lua
-- promises: the driver leaves the pad off where it knows how, and the
-- fb task narrows the answer where it does not. Doing it here instead
-- was a string.char per pixel -- 2.7 seconds for a 320x240 screen, a
-- third of the transfer, for bytes the driver already had.
-- ---- what each part of a transfer costs ----
--
-- Kept in the program rather than added when something looks wrong: a
-- screenshot is sometimes four times slower than usual and the only way
-- to tell a slow guest from a slow host is a split taken at the time.
-- sys.log stays out of a raw console, so this costs the ring alone.
local began = sys.uptime_ms()
local twrite, nwrite = 0, 0
local tread, nread, slowread = 0, 0, 0
local tband, nband = 0, 0

-- A band rather than a row: 240 fetches of one row cost 2.0s of a 3.3s
-- transfer, and sixteen at a time is 15 of them. The transfer walks
-- rows in order, so one band in hand serves the next sixteen.
local BAND = 16
local cached, cachedat, cachedn = nil, -1, 0

local function band(y)
	if y < cachedat or y >= cachedat + cachedn then
		local t0 = sys.uptime_ms()
		local n = math.min(BAND, H - y)
		local r = rpc(fb, fbport, { op = "unload", fmt = "rgb",
		    id = snapid, r = { x = 0, y = y, w = W, h = n } })

		if not (r and r.ok) then
			error("unload rows " .. y .. "+" .. n .. ": " ..
			    tostring(r and r.err), 0)
		end
		cached, cachedat, cachedn = r.ok, y, n
		tband = tband + (sys.uptime_ms() - t0)
		nband = nband + 1
	end
	return cached, cachedat
end

-- one row out of whichever band holds it
local function row(y)
	local b, at = band(y)

	return b:sub((y - at) * stride + 1, (y - at + 1) * stride)
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

-- ---- how long a transfer may take before it is abandoned ----
--
-- A receiver that goes away cannot be noticed any other way. ZMODEM
-- streams: with the window open the sender emits data frames back to
-- back and reads nothing until the file is behind it, so there is no
-- ack to miss and a cancel from the host is not read until far too
-- late. What is left is the clock.
--
-- Abandoning matters more here than the transfer does. The console is
-- the only way in, and a sender still pushing pixels into it owns that
-- line: every command typed at the repl lands in the middle of a
-- screen, and the only way out is a reset. A screenshot is worth less
-- than the machine.
--
-- A whole T-Deck screen measured about 7 seconds at 37KB/s, so this is
-- room for a busy machine rather than for a slow one.
local BUDGET_MS = 30000
local started = sys.uptime_ms()

local function overbudget()
	return sys.uptime_ms() - started > BUDGET_MS
end

-- raised from inside zmodem's callbacks, which is the only way to leave
-- its loop early. Caught below, so the console still gets its raw mode
-- back and the parent still hears.
local GAVEUP = "shot: gave up: the receiver stopped answering"

local nin, nout = 0, 0
local line = {
	now = sys.uptime_ms,
	write = function(d)
		if overbudget() then
			error(GAVEUP, 0)
		end
		nout = nout + #d

		local t0 = sys.uptime_ms()

		sys.send(cons, { op = "write", data = d })
		twrite = twrite + (sys.uptime_ms() - t0)
		nwrite = nwrite + 1
	end,
	-- one round trip for the whole of what is queued. Draining with
	-- getch instead costs a message each way per byte, which measured
	-- about 1KB/s on a 115200 line -- slow enough that the receiver
	-- gave up mid-transfer, so it read as a protocol fault rather
	-- than as the cost of asking.
	read = function(ms)
		if overbudget() then
			error(GAVEUP, 0)
		end

		local t0 = sys.uptime_ms()
		local d = rpc(cons, consport, { op = "readraw", n = 512,
		    timeout = ms and math.max(ms, 1) or 1000 })
		local took = sys.uptime_ms() - t0

		tread = tread + took
		nread = nread + 1
		if took > slowread then
			slowread = took
		end
		-- where in the stream a wait happened, which is what says
		-- whether it is the handshake, the window or the end.
		if took > 1000 then
			sys.log("shot: read waited %dms for %s, asked %s, " ..
			    "%d bytes sent", took,
			    type(d) == "string" and (#d .. "B") or "nothing",
			    tostring(ms), nout)
		end

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
-- pcall, because the budget above leaves by raising: a failure to send
-- must still put the console back into cooked mode and still answer the
-- parent, or the repl comes back with no line editing and nothing
-- waiting for it says why.
local ready = sys.uptime_ms()
local ok, res, err = pcall(zmodem.drive, m, line)

if not ok then
	res, err = nil, tostring(res)
end

local drove = sys.uptime_ms()

-- Four points and three totals, in one line: setup is everything before
-- the first frame, drive is the transfer, and the rest says which of the
-- three things a transfer does was slow. A run whose numbers are ordinary
-- while the host saw a long one puts the delay outside this proc.
sys.log("shot: setup %dms drive %dms | write %dms/%d read %dms/%d " ..
    "worst %dms | bands %dms/%d | %d bytes, window %s flags %s",
    ready - began, drove - ready, twrite, nwrite, tread, nread,
    slowread, tband, nband, nout, tostring(m.rxbufsize),
    tostring(m.rxflags))

if snapid then
	rpc(fb, fbport, { op = "free", id = snapid })
end

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
