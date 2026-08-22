-- lora: talk to the radio task.
--
--	lora status
--	lora listen [SECONDS]
--	lora send TEXT
--	lora set freq=906875000 sf=11 bw=250 cr=5 power=22 sync=18

local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")

local h = prog.lora()

if not h then
	io.stderr:write("lora: no radio on this machine\n")
	os.exit(1)
end

local reply = sys.newport("lora.reply")
local right = sys.sendright(reply)

local function ask(m, secs)
	m.reply = { __right = right }

	local ok, why = sys.send(h, m)

	if not ok then
		io.stderr:write("lora: " .. tostring(why) .. "\n")
		os.exit(1)
	end
	return thread.recvtimeout(reply, (secs or 5) * 1000)
end

local cmd = arg[1] or "status"

if cmd == "status" then
	local r = ask({ op = "status" })
	local s = r and r.ok

	if not s then
		print("lora: no answer")
		os.exit(1)
	end
	print(("mode %d, %d waiting"):format(s.mode or -1, s.waiting or 0))
	print(("%.3f MHz sf%d bw%d cr4/%d %ddBm sync %02x"):format(
	    s.conf.freq / 1e6, s.conf.sf, s.conf.bw, s.conf.cr,
	    s.conf.power, s.conf.sync))
elseif cmd == "send" then
	local text = table.concat({ table.unpack(arg, 2) }, " ")

	if text == "" then
		io.stderr:write("usage: lora send TEXT\n")
		os.exit(1)
	end

	local r = ask({ op = "send", data = text }, 30)

	print(r and r.ok and ("sent " .. #text .. " bytes") or
	    ("send failed: " .. tostring(r and r.err)))
elseif cmd == "listen" then
	local secs = tonumber(arg[2]) or 60
	local until_ = sys.uptime_ms() + secs * 1000

	ask({ op = "listen" })
	print(("listening for %ds"):format(secs))
	while sys.uptime_ms() < until_ do
		local r = ask({ op = "recv" })
		local got = r and r.ok

		if got then
			print(("%8.3fs  %3d bytes  rssi %.0f snr %.1f  %s")
			    :format(sys.uptime_ms() / 1000, #got.data,
			    got.rssi or 0, got.snr or 0,
			    (got.data:gsub("[^\32-\126]", "."))))
		else
			thread.sleep(100)
		end
	end
elseif cmd == "set" then
	local m = { op = "config" }

	for i = 2, #arg do
		local k, v = arg[i]:match("^(%a+)=(%d+)$")

		if not k then
			io.stderr:write("lora: not a setting: " .. arg[i] .. "\n")
			os.exit(1)
		end
		m[k] = tonumber(v)
	end

	local r = ask({ op = "config", freq = m.freq, sf = m.sf, bw = m.bw,
	    cr = m.cr, power = m.power, sync = m.sync,
	    preamble = m.preamble }, 15)

	print(r and r.ok and "configured" or "the radio would not configure")
else
	io.stderr:write("usage: lora status|listen|send|set\n")
	os.exit(1)
end
