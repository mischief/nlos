-- resolv: a name to an address, over a udp capability.
--
-- lib/dns.lua is the wire format and lib/dnsc.lua drives it over raw
-- frames for code that holds a NIC. This is the third caller: a program
-- holding nothing but caps.udp, which is what a shell lends.
--
-- It exists because the retry is not a loop anyone should write twice.
-- caps.udp's recv has no deadline, so each attempt posts the wait by
-- hand against a port of its own, times it, and cancels the abandoned
-- recv -- and a program that skips the cancel leaves a pending entry in
-- the ip task for good. task/dns.lua does the same three things in the
-- same order for the same reasons.

local sys = require("los.sys")
local thread = require("los.thread")
local dns = require("dns")

local M = {}

M.TIMEOUT_MS = 1000
M.TRIES = 3

-- "1.2.3.4" -> 1, 2, 3, 4, or nil where it is a name and not an address.
function M.quad(s)
	if type(s) ~= "string" then
		return nil
	end

	local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

	if not a then
		return nil
	end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if a > 255 or b > 255 or c > 255 or d > 255 then
		return nil
	end
	return a, b, c, d
end

-- where to ask, from the lease: lib/dhcpd.lua serves /net/dns, one
-- address per line. No capability and nothing told to us at spawn --
-- the resolver is a file, which is the whole argument for the lease
-- being a filesystem.
function M.server(ns)
	local txt = ns and ns:readfile("/net/dns")

	return txt and txt:match("^%s*([%d%.]+)")
end

-- resolve(udp, name, server) -> "a.b.c.d", or nil and why.
--
-- `udp` is a caps.udp wrapper; `server` a dotted quad. A name that is
-- already an address is returned unchanged rather than asked about,
-- since the answer to that question is its own subject.
function M.resolve(udp, name, server)
	if M.quad(name) then
		return name
	end
	if not udp then
		return nil, "no udp capability"
	end
	if not server then
		return nil, "no resolver"
	end

	local sa, sb, sc, sd = M.quad(server)

	if not sa then
		return nil, "resolver is not an address: " .. tostring(server)
	end

	-- a source port that is not 53 and varies, for the reason
	-- lib/dnsc.lua gives: it costs nothing not to hand the number to
	-- whatever is watching.
	local conn = udp.open(20000 + (sys.uptime_ms() % 10000))

	if not conn then
		return nil, "cannot open a udp port"
	end

	-- udp is lossy in a way tcp is not: a query or its reply can
	-- vanish and the only evidence is silence. So ask more than once,
	-- and let the id decide whether an answer is ours -- a late reply
	-- to the previous question is otherwise an answer to this one.
	local id = 1 + (sys.uptime_ms() % 65534)
	local query = dns.build_query(name, id)
	local answer, why

	for _ = 1, M.TRIES do
		local replyport = sys.newport("resolv.replypor")

		sys.send(udp.handle, { op = "recv", connid = conn,
		    maxlen = 512, reply = { __right = replyport } })

		if not udp.send(conn, sa, sb, sc, sd, dns.PORT, query) then
			sys.send(udp.handle, { op = "cancel", connid = conn })
			thread.recv(replyport)
			sys.close(replyport)
			why = "send failed"
			break
		end

		local m, timedout = thread.recvtimeout(replyport, M.TIMEOUT_MS)

		if timedout == nil then
			sys.close(replyport)
			if type(m) == "table" and m.data then
				local ip, err = dns.parse(m.data, id)

				if ip then
					answer = ip
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
	return answer, answer == nil and (why or "no reply") or nil
end

return M
