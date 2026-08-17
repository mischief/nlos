-- wifisrv: the radio's control plane, as files.
--
--	/net/wifi/status	what it is associated to
--	/net/wifi/scan		what is in range; reading one runs one
--	/net/wifi/known		the networks saved, in order of preference
--	/net/wifi/ctl		join, forget, leave, scan -- one field a line
--
-- Which network to be on is decided here and nowhere else: this proc
-- holds the nic and keeps /config/wifi/networks.lua. A program writes ctl.
--
-- task/eth.lua owns the device and holds los.platform.wifi. Handing a
-- program that right to pick a network would carry the whole NIC with
-- it, raw frames included. This proc holds the NIC and serves the
-- control plane alone, so an app needs a namespace with /net/wifi in
-- it rather than a device -- and a session that should not retune the
-- radio is given one without it.

local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local srv = require("srv")

local a = ...
local ethh = sys.granted().eth or (a and a.eth and a.eth.__right)

if not ethh then
	print("wifisrv: no eth capability")
	return
end

-- one exchange with the nic. The reply port is the calling thread's, so
-- two readers do not serialise -- see lib/mnt.lua for the pattern.
local function ask(m)
	local reply, send = thread.replyport()

	m.op = "wifi"
	m.reply = { __right = send }

	local ok = pcall(sys.send, ethh, m)

	if not ok then
		return nil
	end
	return thread.recvtimeout(reply, 5000)
end

-- An interface with nothing to associate is every platform but esp32,
-- and eth says so. Nothing is served there: a /net/wifi whose every
-- file answers "no radio" is worse than no mount, because a program
-- tests the mount to decide whether this machine has one.
local probe = ask({ how = "status" })

if not probe or probe.err or type(probe.ok) ~= "table" then
	return
end

-- ---- the scan ----
--
-- A scan takes seconds, so reading /net/wifi/scan starts one and waits
-- for it here rather than returning something stale. The result is kept
-- so a second reader a moment later is answered from it: a panel that
-- redraws should not retune the radio on every frame.
local SCANWAIT = 6000
local FRESH = 15 * 1000
local last, lastat = nil, nil

-- The radio runs one scan at a time, and this proc has several threads
-- that want one: a panel reading the file, and the loop below keeping
-- the link up. A second caller waits for the one in flight and takes
-- its result rather than asking the radio for a scan it will refuse.
local scanning = false

local function scan()
	local now = sys.uptime_ms()

	if last and lastat and now - lastat < FRESH then
		return last
	end
	if scanning then
		local wait = now + SCANWAIT

		while scanning and sys.uptime_ms() < wait do
			thread.sleep(100)
		end
		if last then
			return last
		end
		return nil, "a scan was already running"
	end

	scanning = true

	local r = ask({ how = "scan_begin" })

	if not r or not r.ok then
		scanning = false
		return nil, dev.Eio
	end

	local deadline = now + SCANWAIT

	while sys.uptime_ms() < deadline do
		-- the radio answers when it answers; polling it is what
		-- keeps this proc's other readers running meanwhile.
		thread.sleep(250)

		local t = ask({ how = "scan_take" })

		if t and t.aps then
			last, lastat = t.aps, sys.uptime_ms()
			scanning = false
			return last
		end
	end
	scanning = false
	return nil, "scan timed out"
end

local function scantext()
	local aps, err = scan()

	if not aps then
		return "-- " .. tostring(err or "no scan") .. "\n"
	end

	local out = {}

	table.sort(aps, function(x, y)
		return (x.rssi or -127) > (y.rssi or -127)
	end)
	for _, ap in ipairs(aps) do
		-- ssid last: it is the one field that may hold a space,
		-- so a reader splits the first two off and keeps the rest.
		out[#out + 1] = ("%d %s %s"):format(ap.rssi or -127,
		    ap.open and "open" or "psk", ap.ssid or "")
	end
	return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
end

-- ---- the networks this machine knows ----

local wificfg = require("wificfg")
local ns = require("ns")
local CFG = "/config/wifi/networks.lua"
local FALLBACK = "/etc/wifi.lua"

local function known()
	local N = ns.current()

	if not N then
		return {}
	end
	return wificfg.parse(N:readfile(CFG) or N:readfile(FALLBACK))
end

-- /config is the writable one; /etc rides on the image and is where a
-- board that was flashed with a network but never told one comes from.
local function save(list)
	local N = ns.current()

	if not N then
		return nil, dev.Eio
	end
	-- /config is empty on a freshly reamed partition
	if not N:stat("/config/wifi") then
		local d = N:create("/config/wifi", "rw", true)

		if d then
			d:close()
		end
	end
	if not N:writefile(CFG, wificfg.format(list)) then
		return nil, dev.Eio
	end
	return true
end

local function knowntext()
	local out = {}

	for _, n in ipairs(known()) do
		out[#out + 1] = ("%s %s"):format(n.psk and "psk" or "open",
		    n.ssid)
	end
	return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
end

local function statustext()
	local r = ask({ how = "status" })
	local st = r and r.ok

	if type(st) ~= "table" then
		return "state unknown\n"
	end
	return ("state %s\nssid %s\nreason %d\nup %d\n"):format(
	    st.state or "unknown", st.ssid or "", st.reason or 0,
	    st.up and 1 or 0)
end

-- ---- ctl ----

-- One field a line:
--
--	join
--	<ssid>
--	<passphrase>		omitted for an open network
--
-- Both fields hold spaces in practice -- a passphrase is a sentence as
-- often as it is a word -- and neither can hold a newline, so the line
-- is the only separator that needs no quoting.
local function control(msg)
	local verb, ssid, psk = msg:match("^%s*(%S+)%s*\n?([^\n]*)\n?([^\n]*)")

	if verb == "leave" then
		ask({ how = "disconnect" })
		return true
	end
	if verb == "scan" then
		last, lastat = nil, nil	-- the next read runs a fresh one
		return true
	end
	if verb == "forget" then
		if not ssid or ssid == "" then
			return nil, "forget wants an ssid"
		end
		return save(wificfg.forget(known(), ssid))
	end
	if verb ~= "join" then
		return nil, "unknown control message"
	end
	if not ssid or ssid == "" then
		return nil, "join wants an ssid"
	end
	if psk == "" then
		psk = nil
	end

	-- saved before the radio is told, and first in the list: a join
	-- that is not written down is one the next boot has forgotten,
	-- and choosing a network is what saying "prefer this" looks like.
	save(wificfg.remember(known(), ssid, psk))

	local r = ask({ how = "connect", ssid = ssid, psk = psk })

	if not r or not r.ok then
		return nil, dev.Eio
	end
	return true
end

-- ---- the filesystem ----
--
-- Content is produced at open and kept in the handle, as procfs and
-- dhcpd do: a partial read cannot then see half of one snapshot and
-- half of the next.
local files = {
	status = statustext,
	scan = scantext,
	known = knowntext,
	ctl = function() return "" end,
}

local function backend()
	local B = {}

	local function h_of(name, data)
		return { name = name, data = data }
	end

	function B.attach()
		return h_of(nil, nil)
	end

	function B.walk(h, name)
		if h.name or not files[name] then
			dev.error(dev.Enonexist)
		end
		return h_of(name, nil)
	end

	function B.open(h, mode)
		if not h.name then
			dev.error(dev.Eperm)
		end
		if mode ~= "r" and h.name ~= "ctl" then
			dev.error(dev.Eperm)
		end
		return dev.closable(B, h_of(h.name, files[h.name]()))
	end

	function B.read(h, off, n)
		local data = h.data or ""

		if off >= #data then
			return ""
		end
		return data:sub(off + 1, off + n)
	end

	function B.write(h, off, data)
		if h.name ~= "ctl" then
			dev.error(dev.Eperm)
		end

		local ok, err = control(tostring(data))

		if not ok then
			dev.error(err or dev.Eio)
		end
		return #data
	end

	-- the tree is fixed, so this makes nothing: it is what a shell
	-- redirection lands on, and `> ctl` has to open the ctl that is
	-- already there rather than fail as a missing file.
	function B.create(h, name, mode)
		if h.name or not files[name] then
			dev.error(dev.Eperm)
		end
		return B.open(h_of(name), mode or "w")
	end

	function B.stat(h)
		if not h.name then
			return { name = "wifi", dir = true, size = 0 }
		end
		return { name = h.name, dir = false, size = #files[h.name]() }
	end

	function B.readdir(h)
		if h.name then
			dev.error(dev.Enotdir)
		end

		local out = {}

		for name in pairs(files) do
			-- the size a stat would report costs a scan for one
			-- of these, so it is not produced to list them
			out[#out + 1] = { name = name, dir = false, size = 0 }
		end
		table.sort(out, function(x, y) return x.name < y.name end)
		return out
	end

	function B.clunk() end

	return B
end

-- ---- staying joined ----
--
-- A link that is up is left alone. Moving to whatever is loudest would
-- put a machine on a phone in somebody's pocket the moment it walked
-- past, so only a link that is down is a reason to choose again.
local IDLE = 20 * 1000		-- between looks while the link is up
-- and while it is not. Longer than a scan is fresh for, so the loop
-- takes a new one rather than reading its own cached one forever, and
-- rare enough that somebody reading the file is not queued behind it.
local RETRY = 20 * 1000

local function joined()
	local r = ask({ how = "status" })
	local st = r and r.ok

	return type(st) == "table" and st.state == "joined", st
end

-- the first network, without waiting for a scan: association starts
-- seconds sooner, and the loop below picks another if it is not here.
local function first()
	local list = known()

	if list[1] then
		sys.log("wifi: joining %s, %d known", list[1].ssid, #list)
		ask({ how = "connect", ssid = list[1].ssid,
		    psk = list[1].psk })
	end
end

thread.spawn(function()
	first()

	local complained = false

	while true do
		local up, st = joined()

		if up then
			complained = false
			thread.sleep(IDLE)
			goto continue
		end
		if st and st.state == "joining" then
			thread.sleep(RETRY)
			goto continue
		end

		do
			local list = known()

			if #list == 0 then
				thread.sleep(IDLE)
				goto continue
			end

			-- whatever the last scan saw, its own or a reader's.
			-- Clearing it here would make every pass retune the
			-- radio and leave a panel reading the file empty
			-- handed.
			local pick, rssi = wificfg.pick(list, scan() or {})

			if not pick then
				-- once per outage, not every five seconds:
				-- this goes to the same console a transfer
				-- uses.
				if not complained then
					sys.log("wifi: none of %d known " ..
					    "networks in range", #list)
					complained = true
				end
				thread.sleep(RETRY)
				goto continue
			end

			sys.log("wifi: joining %s at %d dBm", pick.ssid, rssi)
			complained = false
			ask({ how = "connect", ssid = pick.ssid,
			    psk = pick.psk })
			thread.sleep(RETRY)
		end

		::continue::
	end
end)

srv.main(backend)
