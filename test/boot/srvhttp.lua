-- http server payload for test/test_http.py: serve on tcp/7777 and
-- announce readiness on com1 so the host knows dhcp has landed and
-- the listener is actually accepting.
local sys = require("los.sys")
local captcp = require("caps.tcp")
local capudp = require("caps.udp")
local http = require("http")
local ns = require("ns")
local dev = require("dev")
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

-- an in-memory tree exercises M.static without needing a real ESP path.
-- static's root is "/files", and "secret" sits OUTSIDE it, so a request
-- for /files/../secret checks that traversal is contained. big.bin is
-- larger than one WRITECHUNK, so streaming has to cross a boundary.
local N = ns.new()

N:mount("/", dev.mem({
	files = {
		["hello.txt"] = "static file contents\n",
		["big.bin"] = string.rep("x", 200000),
	},
	secret = "should not be reachable\n",
}))

local static = http.static(N, "/files")

http.serve(tcp, 7777, function(req)
	if req.path == "/boom" then
		error("deliberate handler explosion")
	end
	-- a body well over MAXMSG (64KB), which one tcp.send cannot carry:
	-- write_response has to break it up or the client gets nothing.
	if req.path == "/big" then
		return { status = 200, body = string.rep("x", 200000) }
	end
	if req.path == "/echolen" then
		return { status = 200, body = tostring(#req.body) }
	end
	local sub = req.path:match("^/files(/.*)$")

	if sub then
		return static({ method = req.method, path = sub,
		    headers = req.headers, body = req.body })
	end
	return { status = 200, body = "you asked for " .. req.path }
end, function()
	print("http test server ready")
end)
