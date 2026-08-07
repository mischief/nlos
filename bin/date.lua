-- date: what time it is, asked of a server.
--
--   > date
--   > date 162.159.200.1        ask that server instead
--   > date -u                   seconds since the epoch, for a script
--
-- The machine has no real-time clock. microvm's launchers pass rtc=off
-- and a vmd guest has no battery-backed anything either, so the only
-- notion of time here is a cycle counter since boot. That makes the
-- wall clock something the machine can only be told, and SNTP is the
-- telling -- forty-eight bytes out, forty-eight back (lib/ntp.lua).
--
-- Which server comes from /net/ntp, from the lease, the same way
-- bin/host.lua reads /net/dns. A machine whose dhcp server offered no
-- ntp option has to be told one.
--
-- This prints the time; it does not set anything. There is nothing to
-- set: no proc owns a wall clock for the rest of the machine to read.

local unistd = require("posix.unistd")
local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")
local ntp = require("ntp")

local function die(s)
	unistd.write(2, "date: " .. s .. "\n")
	os.exit(1)
end

local server
local raw = false

for _, a in ipairs(arg) do
	if a == "-u" then
		raw = true
	elseif a:sub(1, 1) == "-" and #a > 1 then
		die("usage: date [-u] [server]")
	elseif not server then
		server = a
	else
		die("usage: date [-u] [server]")
	end
end

local function quad(s)
	local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

	if not a then
		return nil
	end
	return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

local udp = prog.udp()

if not udp then
	die("no udp capability: this shell was lent none")
end

if not server then
	local N = prog.ns and prog.ns()
	local txt = N and N:readfile("/net/ntp")

	server = txt and txt:match("^%s*([%d%.]+)")
	if not server then
		die("no ntp server: /net/ntp is empty or unreadable, " ..
		    "and none was named")
	end
end

local sa, sb, sc, sd = quad(server)

if not sa then
	die("not an address: " .. server .. " (no resolver here; try host)")
end

local conn = udp.open(20000 + (os.time() % 10000))

if not conn then
	die("cannot open a udp port")
end

-- the same three steps task/dns.lua and bin/host.lua take, for the same
-- reason: caps.udp's recv has no deadline, so the wait is posted by
-- hand and timed, and the abandoned recv is cancelled rather than left
-- pending in the ip task for good.
local TIMEOUT_MS = 2000
local TRIES = 3
local reply, why

for _ = 1, TRIES do
	local replyport = sys.newport("date.replyport")

	sys.send(udp.handle, { op = "recv", connid = conn, maxlen = 512,
	    reply = { __right = replyport } })

	if not udp.send(conn, sa, sb, sc, sd, ntp.PORT, ntp.request()) then
		sys.send(udp.handle, { op = "cancel", connid = conn })
		thread.recv(replyport)
		sys.close(replyport)
		why = "send failed"
		break
	end

	local m, timedout = thread.recvtimeout(replyport, TIMEOUT_MS)

	if timedout == nil then
		sys.close(replyport)
		if type(m) == "table" and m.data then
			local t, err = ntp.decode(m.data)

			if t then
				reply = t
				break
			end
			why = err
		end
	else
		sys.send(udp.handle, { op = "cancel", connid = conn })
		thread.recv(replyport)
		sys.close(replyport)
		why = why or "no reply"
	end
end

udp.close(conn)

if not reply then
	die(server .. ": " .. tostring(why or "no reply"))
end

if raw then
	unistd.write(1, tostring(reply.unix) .. "\n")
else
	unistd.write(1, ntp.utc(reply.unix) .. " UTC\n")
end
