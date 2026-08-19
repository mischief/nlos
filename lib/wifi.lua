-- wifi: the radio as task/wifisrv.lua serves it, parsed once.
--
-- /net/wifi is four files: status, scan, known, and ctl to write. Both
-- faces read the same bytes, so the parsing lives here and neither one
-- keeps its own copy of the format.

local M = {}

local Wifi = {}

Wifi.__index = Wifi

-- new(N) -> wifi, or nil where the namespace has no radio. A session
-- that should not retune it is given no /net/wifi, so absence is an
-- answer rather than a fault.
function M.new(N)
	if not N or not N:stat("/net/wifi/ctl") then
		return nil
	end
	return setmetatable({ ns = N, dir = "/net/wifi" }, Wifi)
end

function Wifi:read(name)
	return self.ns:readfile(self.dir .. "/" .. name) or ""
end

-- state, and the network it names. "joined" is the one worth testing
-- for; the rest are the radio's own words.
function Wifi:status()
	local txt = self:read("status")

	return {
		state = txt:match("state (%S+)") or "unknown",
		ssid = txt:match("ssid ([^\n]*)") or "",
		reason = txt:match("reason (%S+)") or "0",
	}
end

-- what is in range, strongest first, or nil and why.
--
-- The radio scans one at a time, and a scan that could not run answers
-- with a reason as a comment line. A reader that drops comments shows
-- an empty list instead, which reads as "nothing is out there".
function Wifi:scan()
	local aps = {}

	for line in self:read("scan"):gmatch("[^\n]+") do
		local why = line:match("^%-%-%s*(.*)$")

		if why then
			return nil, why
		end

		local rssi, auth, ssid = line:match("^(-?%d+) (%S+) (.*)$")

		if rssi and ssid ~= "" then
			aps[#aps + 1] = { rssi = tonumber(rssi),
			    open = auth == "open", ssid = ssid }
		end
	end
	return aps
end

-- what wifisrv has saved, best first. Read rather than kept: it owns
-- that list, and joining is what reorders it.
function Wifi:known()
	local nets = {}

	for line in self:read("known"):gmatch("[^\n]+") do
		local auth, ssid = line:match("^(%S+) (.*)$")

		if ssid and ssid ~= "" then
			nets[#nets + 1] = { ssid = ssid, open = auth == "open" }
		end
	end
	return nets
end

-- one field a line: an ssid and a passphrase both hold spaces in
-- practice, and neither holds a newline.
function Wifi:ctl(...)
	return self.ns:writefile(self.dir .. "/ctl",
	    table.concat({ ... }, "\n") .. "\n")
end

function Wifi:join(ssid, psk)
	return self:ctl("join", ssid, (psk and psk ~= "") and psk or "")
end

function Wifi:forget(ssid)
	return self:ctl("forget", ssid)
end

return M
