-- mesh: the meshtastic network, from a shell.
--
--	mesh status | nodes | announce
--	mesh watch [SECONDS]
--	mesh send TEXT

local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")

local h = prog.mesh()

if not h then
	io.stderr:write("mesh: no mesh service here\n")
	os.exit(1)
end

local reply = sys.newport("mesh.reply")
local right = sys.sendright(reply)

local function ask(m, secs)
	m.reply = { __right = right }
	if not sys.send(h, m) then
		io.stderr:write("mesh: the service is not answering\n")
		os.exit(1)
	end
	return thread.recvtimeout(reply, (secs or 5) * 1000)
end

-- a line for whatever arrived, since one port carries them all
local function show(m)
	local who = m.long or m.short or m.id
	local sig = ("%.0f/%.1f"):format(m.rssi or 0, m.snr or 0)

	if m.port == 1 then
		print(("%-14s %-11s %s"):format(who, sig, m.text or ""))
	elseif m.port == 4 then
		print(("%-14s %-11s is %s"):format(who, sig,
		    m.long or m.short or "?"))
	elseif m.port == 3 and m.lat then
		print(("%-14s %-11s at %.5f,%.5f"):format(who, sig, m.lat,
		    m.lon or 0))
	else
		print(("%-14s %-11s %s"):format(who, sig, m.portname or "?"))
	end
end

local cmd = arg[1] or "status"

if cmd == "status" then
	local s = ask({ op = "status" })

	s = s and s.ok
	if not s then
		print("mesh: no answer")
		os.exit(1)
	end
	print(("%s (%s) channel %02x, %d waiting"):format(s.me, s.name,
	    s.channel, s.waiting))
	print(("rx %d  tx %d  dup %d  undecoded %d"):format(s.counters.rx,
	    s.counters.tx, s.counters.dup, s.counters.undecoded))
elseif cmd == "nodes" then
	local r = ask({ op = "nodes" })
	local list = r and r.ok or {}

	table.sort(list, function(a, b)
		return (a.heard or 0) > (b.heard or 0)
	end)
	if #list == 0 then
		print("nobody heard yet")
	end
	for _, n in ipairs(list) do
		print(("%-10s %-16s %5.0fdBm %5.1fdB %4ds ago%s"):format(n.id,
		    n.long or n.short or "", n.rssi or 0, n.snr or 0,
		    (sys.uptime_ms() - (n.heard or 0)) // 1000,
		    n.lat and (" %.4f,%.4f"):format(n.lat, n.lon or 0) or ""))
	end
elseif cmd == "send" then
	local text = table.concat({ table.unpack(arg, 2) }, " ")

	if text == "" then
		io.stderr:write("usage: mesh send TEXT\n")
		os.exit(1)
	end

	local r = ask({ op = "send", text = text }, 40)

	print(r and r.ok and "sent" or "not sent")
elseif cmd == "announce" then
	local r = ask({ op = "announce" }, 40)

	print(r and r.ok and "announced" or "not announced")
elseif cmd == "watch" then
	local secs = tonumber(arg[2]) or 300
	local until_ = sys.uptime_ms() + secs * 1000

	print(("watching for %ds"):format(secs))
	while sys.uptime_ms() < until_ do
		local r = ask({ op = "recv" })

		if r and r.ok then
			show(r.ok)
		else
			thread.sleep(200)
		end
	end
else
	io.stderr:write("usage: mesh status|nodes|watch|send|announce\n")
	os.exit(1)
end
