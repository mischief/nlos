-- wificfg: the networks this machine knows, as a file.
--
-- Read by init to join at boot, by task/wifisrv.lua to stay joined, and
-- written by bin/wifiui.lua when somebody picks one. Sans-io: a string
-- in, a string out, and choosing is a function of a scan.

local M = {}

-- Order is preference. The first entry that is in range wins, so a
-- machine sitting between its own network and a phone stays on the one
-- named first rather than on whichever is loudest this second.
--
-- Legacy: a table with a bare ssid is one network, which is what every
-- config written before this held.
function M.parse(src)
	if type(src) ~= "string" then
		return {}
	end

	local chunk = load(src, "=wifi.lua", "t", {})

	if not chunk then
		return {}
	end

	local ok, t = pcall(chunk)

	if not ok or type(t) ~= "table" then
		return {}
	end

	local out = {}

	for _, n in ipairs(t.networks or {}) do
		if type(n) == "table" and type(n.ssid) == "string" and
		    n.ssid ~= "" then
			out[#out + 1] = { ssid = n.ssid, psk = n.psk }
		end
	end
	if #out == 0 and type(t.ssid) == "string" and t.ssid ~= "" then
		out[1] = { ssid = t.ssid, psk = t.psk }
	end
	return out
end

local function quote(s)
	return '"' .. tostring(s):gsub('[\\"]', "\\%0") .. '"'
end

-- back to a chunk, in the shape the parser above reads. Written whole:
-- the file is small and a partial rewrite of a config is how a machine
-- ends up with no network at all.
function M.format(list)
	local out = { "-- the networks this machine knows, in order of",
	    "-- preference. Written by bin/wifiui.lua.", "return {",
	    "\tnetworks = {" }

	for _, n in ipairs(list) do
		out[#out + 1] = ("\t\t{ ssid = %s, psk = %s },"):format(
		    quote(n.ssid), n.psk and quote(n.psk) or "nil")
	end
	out[#out + 1] = "\t},"
	out[#out + 1] = "}"
	return table.concat(out, "\n") .. "\n"
end

-- the known network to join, given what a scan saw. Config order, not
-- signal: the strongest is not the wanted one when a phone is on the
-- desk. `seen` is a list of { ssid =, rssi = }.
function M.pick(list, seen)
	local inrange = {}

	for _, ap in ipairs(seen or {}) do
		local at = inrange[ap.ssid]

		if ap.ssid and (not at or (ap.rssi or -127) > at) then
			inrange[ap.ssid] = ap.rssi or -127
		end
	end
	for _, n in ipairs(list) do
		if inrange[n.ssid] then
			return n, inrange[n.ssid]
		end
	end
	return nil
end

-- what the app does when somebody joins one: first, because choosing it
-- is what saying "prefer this" looks like. The same ssid is not listed
-- twice, so a rejoin moves it rather than growing the file.
function M.remember(list, ssid, psk)
	local out = { { ssid = ssid, psk = psk } }

	for _, n in ipairs(list) do
		if n.ssid ~= ssid then
			out[#out + 1] = n
		end
	end
	return out
end

function M.forget(list, ssid)
	local out = {}

	for _, n in ipairs(list) do
		if n.ssid ~= ssid then
			out[#out + 1] = n
		end
	end
	return out
end

return M
