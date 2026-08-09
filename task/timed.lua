-- timed: asks a server what time it is, and tells init.

-- It cannot set the clock: sys.settime is boot-only. This proposes
-- {time=unix} to the port it was given and init decides, so only the
-- waiting moves out of the boot proc.

-- The server comes from the lease, asked of dhcpd rather than read
-- from /net, so this needs no namespace. Where the lease names none,
-- the pool.

local sys = require("los.sys")
local thread = require("los.thread")
local udpc = require("client.udp")
local ntp = require("ntp")

local a = ...
local udph = a.ip and a.ip.__right
local dhcpd = a.dhcpd and a.dhcpd.__right
local report = a.reply and a.reply.__right

-- re-synced rather than set once: the tsc drifts, and a board that is
-- up for a week is a board whose clock has wandered.
local EVERY_MS = tonumber(a.every_ms) or 3600 * 1000
local RETRY_MS = 30 * 1000
local TIMEOUT_MS = 2000
local TRIES = 3

local udp = udpc.new(udph)

local function quad(s)
	local w, x, y, z = tostring(s):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

	if not w then
		return nil
	end
	return { tonumber(w), tonumber(x), tonumber(y), tonumber(z) }
end

-- the lease's server, then the pool. The pool needs a resolver, so it
-- is only reachable once dns is up -- which is why the lease is tried
-- first even when both would work.
local function server()
	if dhcpd then
		local r = thread.rpc(dhcpd, { op = "get", name = "ntp" })
		local first = type(r) == "table" and r.data and
		    r.data:match("^%s*([%d%.]+)")
		local q = first and quad(first)

		if q then
			return q
		end
	end

	local dnsh = a.dns and a.dns.__right

	if dnsh then
		local rp, send = thread.replyport()

		sys.send(dnsh, { op = "resolve", name = "pool.ntp.org",
		    reply = { __right = send } })

		local ip = thread.recvtimeout(rp, 4000)

		return type(ip) == "string" and quad(ip) or nil
	end
	return nil
end

-- one exchange, on a port of its own. udp is lossy, so the wait has a
-- deadline and the abandoned recv is cancelled rather than left pending
-- in the ip task for good.
local function ask(conn, s)
	local rp = sys.newport("timed.rp")
	local right = sys.sendright(rp)

	local function done()
		sys.close(right)
		sys.close(rp)
	end

	sys.send(udph, { op = "recv", connid = conn, maxlen = 512,
	    reply = { __right = right } })

	if not udp.send(conn, s[1], s[2], s[3], s[4], ntp.PORT, ntp.request()) then
		sys.send(udph, { op = "cancel", connid = conn })
		thread.recv(rp)
		done()
		return nil
	end

	local m, timedout = thread.recvtimeout(rp, TIMEOUT_MS)

	if timedout == nil then
		done()
		if type(m) == "table" and m.data then
			local t = ntp.decode(m.data)

			return t and t.unix or nil
		end
		return nil
	end
	sys.send(udph, { op = "cancel", connid = conn })
	thread.recv(rp)
	done()
	return nil
end

local function sync()
	local s = server()

	if not s then
		return nil
	end

	local conn = udp.open(0)	-- 0: the stack picks an ephemeral port

	if not conn then
		return nil
	end

	local unix

	for _ = 1, TRIES do
		unix = ask(conn, s)
		if unix then
			break
		end
	end
	udp.close(conn)
	return unix
end

while true do
	local unix = sync()

	if unix and report then
		sys.send(report, { time = unix })
	end
	-- a failure is usually a lease that has not arrived yet, so try
	-- again soon rather than in an hour
	thread.sleep(unix and EVERY_MS or RETRY_MS)
end
