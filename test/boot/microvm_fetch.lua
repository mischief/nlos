-- fetch a real file over the lua tcp stack, and check it arrived.
--
-- Not a suite test: it wants a route to a machine on somebody's LAN,
-- which qemu's user networking cannot give and which no test should
-- depend on. tools/lanfetch.sh runs it, bridged.
--
-- What it is for is the question the suite cannot answer. Every test so
-- far moves a few kilobytes between two things on the same host. This
-- moves a real file off a real nginx, through a window that closes and
-- reopens thousands of times, over a link with a real round trip and
-- real loss -- and then says whether the bytes are the bytes, by
-- hashing them.
--
-- The body is never held: it is counted and hashed as it arrives and
-- then dropped. A 232MB download in a 256MB guest is not a buffering
-- problem to be solved with a bigger buffer.

local sys = require("los.sys")
local thread = require("los.thread")
local caps = require("caps")
local ip4 = require("ip4")

-- rewritten by tools/lanfetch.sh
local HOST = "@@HOST@@"
local PORT = tonumber("@@PORT@@")
local PATH = "@@PATH@@"
local RANGE = "@@RANGE@@"
local WANT_HASH = ("@@HASH@@" == "yes")

local granted = sys.granted()

if not granted.tcp then
	print("fetch: no tcp capability")
	return
end

-- wait for the machine's own dhcp client. On this link that is a real
-- server on somebody's LAN, not slirp answering instantly.
local cfg
local deadline = sys.uptime_ms() + 20000

repeat
	cfg = granted.ip and thread.rpc(granted.ip, { op = "config" })
	if cfg and cfg.ip and cfg.ip ~= ip4.ANY then
		break
	end
	thread.sleep(200)
until sys.uptime_ms() > deadline

if not cfg or not cfg.ip or cfg.ip == ip4.ANY then
	print("fetch: no address after 20s")
	return
end

print(string.format("fetch: %s/%s gw %s", ip4.str(cfg.ip),
    ip4.str(cfg.mask or ip4.ANY), ip4.str(cfg.gw or ip4.ANY)))

local a, b, c, d = HOST:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
local tcp = caps.tcp(granted.tcp)
local conn = tcp.dial(tonumber(a), tonumber(b), tonumber(c), tonumber(d), PORT)

if not conn then
	print("fetch: dial failed")
	return
end

local req = {
	"GET " .. PATH .. " HTTP/1.1",
	"Host: " .. HOST,
	"User-Agent: lua-os",
	"Connection: close",
}

if RANGE ~= "" then
	req[#req + 1] = "Range: bytes=" .. RANGE
end
req[#req + 1] = ""
req[#req + 1] = ""

if not tcp.send(conn, table.concat(req, "\r\n")) then
	print("fetch: send failed")
	return
end

-- ---- read ----
--
-- 16KB a call rather than 4KB: every recv is a message round trip to
-- the tcp task, and at 4KB a 232MB download is sixty thousand of them.
-- Not 64KB, because MAXMSG is 64KB and the reply has to fit inside one
-- with room for the table around it.
local CHUNK = 16384

local hash
local hasher

if WANT_HASH then
	hasher = require("crypto.sha256").new()
end

local head = ""
local body = 0
local first
local t0 = sys.uptime_ms()

while true do
	local data = tcp.recv(conn, CHUNK)

	if not data then
		break
	end
	first = first or sys.uptime_ms()

	if head then
		-- the header is short and arrives in the first segment or
		-- two; split it off, then stop looking.
		head = head .. data

		local cut = head:find("\r\n\r\n", 1, true)

		if cut then
			local rest = head:sub(cut + 4)

			head = head:sub(1, cut - 1)
			print("fetch: " .. (head:match("^[^\r\n]*") or "?"))
			for line in head:gmatch("[\r\n]+([^\r\n]+)") do
				if line:lower():match("^content%-length:") or
				    line:lower():match("^content%-range:") then
					print("fetch: " .. line)
				end
			end
			data = rest
			head = nil
		else
			data = nil
		end
	end

	if data and #data > 0 then
		body = body + #data
		if hasher then
			hasher:update(data)
		end
	end
end

local t1 = sys.uptime_ms()
local ms = t1 - (first or t0)

tcp.close(conn)

print(string.format("fetch: %d bytes in %d ms", body, ms))
if ms > 0 then
	print(string.format("fetch: %.2f KB/s (%.2f Mbit/s)",
	    body / ms, (body * 8) / (ms * 1000)))
end
if hasher then
	hash = hasher:final()
	print("fetch: sha256 " .. (hash:gsub(".", function(ch)
		return string.format("%02x", ch:byte())
	end)))
end

local s = thread.rpc(granted.tcp, { op = "stats" })

if s then
	print(string.format(
	    "fetch: seg_in=%d seg_out=%d seg_bad=%d no_conn=%d reset=%d",
	    s.seg_in, s.seg_out, s.seg_bad, s.no_conn, s.reset_sent))
end

local ips = thread.rpc(granted.ip, { op = "stats" })

if ips then
	print(string.format(
	    "fetch: frames_in=%d raw_in=%d raw_dropped=%d out_fail=%d",
	    ips.frames_in, ips.raw_in, ips.raw_dropped, ips.frames_out_fail))
end

print("fetch: done")

-- Power off, so a run costs its transfer rather than the harness
-- timeout. mode = "shutdown" is the part that matters: a bare reset
-- leaves qemu running and the script then ends only when timeout kills
-- it -- 30 seconds of wall clock for a 315ms transfer, which is how a
-- fast download came to look like a hang.
if granted.power then
	sys.send(granted.power, { op = "reset", mode = "shutdown" })
	thread.sleep(5000)
else
	print("fetch: no power capability; cannot power off")
end
