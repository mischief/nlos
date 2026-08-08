-- an http server on the lua tcp stack, for test/microvm_http.lua.
--
-- The point of this payload is that there is nothing in it about which
-- stack it is running on. It is the same shape as test/boot/srvhttp.lua,
-- which serves the identical handler through the UEFI firmware's
-- EFI_TCP4 -- lib/caps.lua's tcp wrapper, lib/http.lua's serve, listen
-- and accept and recv and send. Underneath, one of them is firmware and
-- the other is lib/tcb.lua.
--
-- No dhcp client here, unlike srvhttp.lua: on microvm the ip stack and
-- the dhcp client are tasks kernel.c starts before init, so the machine
-- configures itself and this only has to wait for it.

local sys = require("los.sys")
local thread = require("los.thread")
local tcpc = require("client.tcp")
local http = require("http")
local ns = require("ns")
local dev = require("dev")
local ip4 = require("ip4")

local granted = sys.granted()

if not granted.tcp then
	print("httpd: no tcp capability")
	return
end

-- Wait for an address before listening. A listener does not need one --
-- it takes its local address from whatever the incoming packet was
-- addressed to -- but nothing can reach us until we can answer an ARP
-- request, so announcing readiness first would be announcing a lie.
local deadline = sys.uptime_ms() + 10000

while sys.uptime_ms() < deadline do
	local cfg = granted.ip and thread.rpc(granted.ip, { op = "config" })

	if cfg and cfg.ip and cfg.ip ~= ip4.ANY then
		print("httpd: address " .. ip4.str(cfg.ip))
		break
	end
	thread.sleep(200)
end

local tcp = tcpc.new(granted.tcp)

-- the same in-memory tree srvhttp.lua serves, for the same reasons:
-- static's root is /files and "secret" sits outside it, so a request for
-- /files/../secret checks that traversal is contained, and big.bin
-- crosses a write chunk boundary.
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
	-- a body well over MAXMSG, which one tcp.send cannot carry: the
	-- response writer has to break it up, and every one of those
	-- pieces has to cross the stack in order.
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
