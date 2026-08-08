-- mcp server payload for test/test_mcp.py: two tools, one that works
-- and one that always raises, so the host can check both the normal
-- result shape and the isError shape. no dns/network fetching here --
-- this is about the json-rpc layer, not about http.get.
local sys = require("los.sys")
local captcp = require("caps.tcp")
local capudp = require("caps.udp")
local mcp = require("mcp")
local caps_of = sys.granted()

local tcp = captcp.new(caps_of.tcp)

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
	    dhcp.acquire(capudp.new(caps_of.udp), caps_of.udp, { mac = mac })

	if lease then
		dhcp.install(tcp, lease)
	end
end

mcp.serve(tcp, 7777, {
	{
		name = "echo",
		description = "return the text you were given",
		inputSchema = { type = "object",
		    properties = { text = { type = "string" } },
		    required = { "text" } },
		handler = function(args)
			if not args.text then
				error("text is required")
			end
			return "echo: " .. args.text
		end,
	},
	{
		name = "boom",
		description = "always fails",
		handler = function()
			error("deliberate tool explosion")
		end,
	},
}, function()
	print("mcp test server ready")
end)
