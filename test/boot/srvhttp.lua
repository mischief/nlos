-- http server payload for test/test_http.py: serve on tcp/7777 and
-- announce readiness on com1 so the host knows dhcp has landed and
-- the listener is actually accepting.
local sys = require("los.sys")
local caps = require("caps")
local http = require("http")

local tcp = caps.tcp(sys.TCP)

http.serve(tcp, 7777, function(req)
	if req.path == "/boom" then
		error("deliberate handler explosion")
	end
	return { status = 200, body = "you asked for " .. req.path }
end, function()
	print("http test server ready")
end)
