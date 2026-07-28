-- fetch-mcp boot payload: a standalone MCP server exposing one tool,
-- "fetch", that retrieves a caller-supplied url. runs as its own boot
-- payload (replacing init.lua entirely, via fw_cfg -- see
-- scripts/fetch-mcp.sh), so unlike a tool spawned under init.lua's
-- supervisor, it has to spawn its own dns task itself; nothing else
-- is running to hand it one.

local sys = require("los.sys")
local caps = require("caps")
local http = require("http")
local mcp = require("mcp")

local MCP_PORT = 8090

if not sys.TCP then
	print("NO TCP")
	return
end

-- spawn our own dns task (init.lua's supervisor isn't running -- this
-- payload replaced it), same pattern init.lua itself uses.
local _, dnssrv = sys.spawn(io.open("/lib/dns.lua"):read("a"),
    { name = "dns" })
local has_udp = sys.UDP ~= nil and
    pcall(sys.send, dnssrv, { udp = { __right = sys.UDP } })

if not has_udp then
	print("NO UDP/DNS")
	return
end

local tcp = caps.tcp(sys.TCP)
local dns = caps.dns(dnssrv)	-- dnssrv is already a handle, see sys.spawn

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
