-- the gps stack on the host, off a recording: the replay driver, the
-- parser above it, and task/gpsd.lua serving both to a client.
--
-- LUAOS_GPS names the fixture and the test harness sets it. Asked
-- through gpsd rather than the raw module, because only gpsd holds
-- PRIV_GPS: proc 0 has PRIV_BOOT and nothing else.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(12)

-- What the kernel hands proc 0: a rights table read by name, not a
-- message waiting on the mailbox. A payload replaces init, so this is
-- the same call init makes on its first line.
local gps = sys.granted().gps

tap.ok(gps ~= nil, "the machine has a receiver, and proc 0 a right to it")
if not gps then
	tap.done()
	return
end

local reply = sys.newport("gps.reply")
local right = sys.sendright(reply)

local function ask(msg, ms)
	msg.reply = { __right = right }
	if not sys.send(gps, msg) then
		return nil
	end
	return thread.recvtimeout(reply, ms or 2000)
end

-- gpsd tries each rate before it serves anything, so the first request
-- can wait nine seconds on a machine whose receiver says nothing.
-- Retried on stats, which changes nothing: a subscribe retried would
-- leave a listener registered for every attempt that was only slow.
local up

for _ = 1, 30 do
	up = ask({ op = "stats" }, 1000)
	if up then
		break
	end
end

tap.ok(up ~= nil, "gpsd finishes probing and answers")

-- ---- the sentences, as a client sees them ----
--
-- Listening before reading the counters, because the recording plays
-- at the rate it was taken: a subscriber that waits until they look
-- good has missed what it was going to be sent.
local raw = sys.newport("gps.raw")
local sub = ask({ op = "raw", port = { __right = sys.sendright(raw) } })

tap.ok(sub and sub.ok, "a client may listen for sentences")

local heard, kinds = 0, {}

for _ = 1, 40 do
	local msg = thread.recvtimeout(raw, 500)
	local s = type(msg) == "table" and msg.line or nil

	if type(s) == "table" and s.talker then
		heard = heard + 1
		kinds[s.kind or "?"] = true
	end
	if heard >= 5 then
		break
	end
end

tap.ok(heard > 0, ("sentences arrive on the port: %d"):format(heard))
tap.ok(next(kinds) ~= nil, "and each says what kind it is")

-- ---- what the receiver is doing ----
--
-- Waits for sentences rather than assuming they have arrived: a fixed
-- sleep either flakes or is longer than it needs to be.
local st

for _ = 1, 200 do
	st = ask({ op = "stats" })
	if st and (st.sentences or 0) >= 150 then
		break
	end
	thread.sleep(100)
end

tap.ok(st ~= nil, "gpsd answers a stats request")
tap.diag(("%d bytes, %d sentences, %d good, %d bad, %d baud"):format(
    st and st.rx or 0, st and st.sentences or 0, st and st.good or 0,
    st and st.bad or 0, st and st.baud or 0))

tap.ok((st.rx or 0) > 0, ("bytes came off the recording: %d"):format(
    st.rx or 0))
tap.ok((st.sentences or 0) >= 150, ("and parsed as sentences: %d"):format(
    st.sentences or 0))

-- every sentence in the fixture carries a checksum, so one that fails
-- means the parser and not the recording
tap.ok((st.bad or 0) == 0, ("every one checks out: %d bad"):format(
    st.bad or 0))
tap.ok((st.overrun or 0) == 0, ("nothing was dropped: %d overrun"):format(
    st.overrun or 0))

-- ---- where it thinks it is ----

local fix = ask({ op = "fix" })

tap.ok(type(fix) == "table", "gpsd answers a fix request")
tap.diag(("has=%s heard=%s time=%s date=%s"):format(tostring(fix and fix.has),
    tostring(fix and fix.heard), tostring(fix and fix.time),
    tostring(fix and fix.date)))

-- A cold start: the recording is a receiver that has just been
-- switched on, so it reports the time from the almanac long before it
-- has enough satellites to say where it is. A fixture taken with a fix
-- would assert this the other way.
tap.ok(fix.time ~= nil or fix.date ~= nil or fix.has == false,
    "it knows the time, or says plainly that it has no fix")

tap.done()
