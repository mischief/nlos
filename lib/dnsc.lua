-- DNS over the Lua stack: one question, one answer.
--
-- lib/dns.lua is the wire format and task/dns.lua is the service that
-- serves it over the firmware's udp4; this is the third piece, the same
-- codec driven over lib/inet.lua for a machine with no firmware to ask.
-- The split is the point: a fix to the parser reaches both transports,
-- and neither can quietly disagree with the other about the protocol.
--
-- No cache and no search list. A cache belongs in whatever task ends up
-- owning resolution for the machine, where it can be shared and aged; a
-- search list is policy that has to come from somewhere, and on this
-- platform nothing configures one yet. Both would be guesses here.
--
-- udp is lossy in a way tcp is not: a query or its reply can simply
-- vanish, and the only evidence is silence. So this retries, and the
-- id is what makes an answer ours -- without checking it, a late reply
-- to the previous question answers this one.

local ip4 = require("ip4")
local dns = require("dns")

local dnsc = {}

dnsc.TIMEOUT_MS = 1000
dnsc.TRIES = 3

-- a source port that is not 53, and varies. Using the same one every
-- time makes a reply easier for anything watching to forge; this is not
-- a defence, but it costs nothing not to hand the number over.
local nextport = 20000

local nextid = 1

-- resolve(host, name, server) -> "a.b.c.d", or nil and why.
--
-- server defaults to the host's gateway, which is right on a link where
-- the router resolves -- true of every network this has been run on,
-- and wrong in general, so a caller with a lease should pass what DHCP
-- gave it.
function dnsc.resolve(host, name, server)
	server = server or host.gw

	if not server then
		return nil, "no resolver"
	end

	local err

	for _ = 1, dnsc.TRIES do
		local id = nextid

		nextid = (nextid % 0xffff) + 1
		nextport = 20000 + ((nextport + 1) % 20000)

		local reply

		reply, err = host:udp_rpc(server, nextport, dns.PORT,
		    dns.build_query(name, id), dnsc.TIMEOUT_MS)

		if reply then
			local addr, why = dns.parse(reply, id)

			if addr then
				return ip4.parse(addr), addr
			end
			err = why
		end
	end

	return nil, tostring(err)
end

return dnsc
