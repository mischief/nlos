-- fetch-mcp boot payload: a standalone MCP server exposing one tool,
-- "fetch", that retrieves a caller-supplied url. runs as its own boot
-- payload (replacing init.lua entirely, via fw_cfg -- see
-- scripts/fetch-mcp.sh), so unlike a tool spawned under init.lua's
-- supervisor, it has to spawn its own dns task itself; nothing else
-- is running to hand it one.

local sys = require("los.sys")
local dnsc = require("client.dns")
local tcpc = require("client.tcp")
local udpc = require("client.udp")
local http = require("http")
local mcp = require("mcp")
local caps_of = sys.granted()

local MCP_PORT = 8090

if not caps_of.tcp then
	print("NO TCP")
	return
end

-- spawn our own dns task (init.lua's supervisor isn't running -- this
-- payload replaced it), same pattern init.lua itself uses.
local _, dnssrv = sys.spawn(io.open("/task/dns.lua"):read("a"),
    { name = "dns" })
local has_udp = caps_of.udp ~= nil and
    pcall(sys.send, dnssrv, { udp = { __right = caps_of.udp } })

if not has_udp then
	print("NO UDP/DNS")
	return
end

local tcp = tcpc.new(caps_of.tcp)

-- this payload REPLACES init.lua, so it does not inherit init's dhcp
-- client -- and without one, the listen below waits for the FIRMWARE's,
-- which sits on an offer it already holds for four seconds. see
-- lib/dhcp.lua for why, and why it cannot be hurried from outside.
--
-- one-shot rather than lib/dhcpd.lua as a proc: this payload does not
-- live long enough to need the lease renewed. anything long-lived should
-- spawn dhcpd instead -- test/boot/srvweb.lua is the example.
local dhcp = require("dhcp")

if caps_of.udp then
	local mac = tcp.hwaddr()
	local lease = mac and
	    dhcp.acquire(udpc.new(caps_of.udp), caps_of.udp, { mac = mac })

	if lease then
		dhcp.install(tcp, lease)
	end
end
local dns = dnsc.new(dnssrv)	-- dnssrv is already a handle, see sys.spawn

mcp.serve(tcp, MCP_PORT, {
	{
		name = "fetch",
		description = "fetch a url and return its body",
		inputSchema = { type = "object",
		    properties = { url = { type = "string",
		        description = "url to fetch, eg http://example.com/" } },
		    required = { "url" } },
		handler = function(args)
			if not args.url then
				error("url is required")
			end
			local r, err = http.get(tcp, dns, args.url)

			if not r then
				return "fetch failed: " .. tostring(err)
			end
			return "HTTP " .. r.status .. "\n\n" .. r.body
		end,
	},
}, function()
	print("fetch-mcp: listening on tcp/" .. MCP_PORT)
end)
