-- kat: keep-alive timing, and what a tls client costs to hold.
--
--	> kat https://mirror.offblast.org/
--
-- Two requests down one connection. The second is what keep-alive is
-- for, and the memory is per-proc live bytes either side of each step.

local unistd = require("posix.unistd")
local sys = require("los.sys")
local prog = require("prog")
local http = require("http")

local url = arg[1] or "https://mirror.offblast.org/"
local net = prog.net() or error("no network capability")
-- verified, not insecure: checking the certificate is part of what a
-- handshake costs, and a number measured without it is not the number.
local host = url:match("^https?://([^:/]+)")
local opts = { rand = prog.rand() or error("no entropy"),
    verify = require("tlstcp").tofu(host) }

local function say(s)
	unistd.write(1, s .. "\n")
end

local function kb(n)
	return string.format("%dK", n // 1024)
end

local m0 = (sys.meminfo())
local t0 = sys.uptime_ms()
local conn, cerr = http.connect(net, prog.dns(), url, opts)

if not conn then
	say("connect: " .. tostring(cerr))
	os.exit(1)
end

local t1 = sys.uptime_ms()
local m1 = (sys.meminfo())
local r1, e1 = conn:request({ path = "/" })
local t2 = sys.uptime_ms()
local m2 = (sys.meminfo())
local r2, e2 = conn:request({ path = "/" })
local t3 = sys.uptime_ms()
local m3 = (sys.meminfo())

say(string.format("connect+tls %dms", t1 - t0))
say(string.format("request 1   %dms  %s  %d bytes", t2 - t1,
    tostring(r1 and r1.status or e1), r1 and #r1.body or 0))
say(string.format("request 2   %dms  %s  %d bytes", t3 - t2,
    tostring(r2 and r2.status or e2), r2 and #r2.body or 0))
say(string.format("alive after both: %s", tostring(conn:alive())))
say(string.format("mem: base %s  +tls/conn %s  +req1 %s  +req2 %s",
    kb(m0), kb(m1 - m0), kb(m2 - m1), kb(m3 - m2)))

conn:close()
