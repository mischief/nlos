-- mcp server payload for test/test_mcp.py: two tools, one that works
-- and one that always raises, so the host can check both the normal
-- result shape and the isError shape. no dns/network fetching here --
-- this is about the json-rpc layer, not about http.get.
local sys = require("los.sys")
local caps = require("caps")
local mcp = require("mcp")

local tcp = caps.tcp(sys.TCP)

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
