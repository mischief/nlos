-- nettime: where the time goes reaching a host.
--
--   > nettime wttr.in            https, every phase
--   > nettime -p 80 example.com  plain http, so tls shows as its absence

-- Each phase timed on its own, because "the network is slow" is four
-- different faults: a resolver that waits, a handshake that computes,
-- a peer that is far away, or a body that is large.

local unistd = require("posix.unistd")
local sys = require("los.sys")
local prog = require("prog")

local function die(s)
	unistd.write(2, "nettime: " .. s .. "\n")
	os.exit(1)
end

local host, port, path = nil, 443, "/"

do
	local want = nil

	for _, a in ipairs(arg) do
		if want == "p" then
			port = tonumber(a) or die("not a port: " .. a)
			want = nil
		elseif a == "-p" then
			want = "p"
		elseif a:sub(1, 1) == "/" then
			path = a
		else
			host = host or a
		end
	end
end

if not host then
	unistd.write(2, "usage: nettime [-p port] host [/path]\n")
	os.exit(2)
end

local net = prog.net() or die("no network capability")
local ms = sys.uptime_ms
local function say(what, t)
	unistd.write(1, ("  %-12s %5d ms\n"):format(what, t))
end

-- What the program costs before it does anything. The tls stack is
-- lua, and requiring it reads and compiles the crypto under it, in
-- this proc, every run. Reading dominates: measured 3021ms to read
-- 73KB against 125ms to compile it.
if port == 443 then
	local t = ms()

	require("tlstcp")
	say("load tls", ms() - t)
end

-- ---- the name ----

local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

if not a then
	local dns = prog.dns() or die("no resolver, and " .. host ..
	    " is not an address")
	local t0 = ms()
	local ip = dns.resolve(host)

	say("resolve", ms() - t0)
	if not ip then
		die("cannot resolve " .. host)
	end
	a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then
		die("the resolver answered " .. tostring(ip))
	end
end
a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)

-- ---- the connection, and the handshake inside it ----

local tcp = net
local tls = port == 443

if tls then
	tcp = require("tlstcp").new(net, {
		rand = prog.rand() or die("no entropy, and tls needs some"),
		verify = require("tlstcp").tofu(host),
	})
end

local t1 = ms()
local conn, cerr = tcp.dial(a, b, c, d, port, tls and host or nil)

say(tls and "dial+tls" or "dial", ms() - t1)
if not conn then
	die("connect: " .. tostring(cerr))
end

-- ---- the request, and the first byte back ----

local t2 = ms()

if not tcp.send(conn, ("GET %s HTTP/1.1\r\nHost: %s\r\n"):format(path, host)
    .. "User-Agent: lua-os\r\nConnection: close\r\n\r\n") then
	die("send failed")
end

local first = tcp.recv(conn, 4096)

say("first byte", ms() - t2)
if not first then
	die("the peer closed without answering")
end

local t3 = ms()
local n = #first

while true do
	local more = tcp.recv(conn, 4096)

	if not more then
		break
	end
	n = n + #more
end
say("rest", ms() - t3)
tcp.close(conn)

unistd.write(1, ("  %-12s %5d bytes\n"):format("body", n))
