-- tcp on OpenBSD vmd, as the image's embedded payload.
--
-- vmd cannot be handed a payload: its fw_cfg serves a fixed list and
-- will not take a host file, so the embedded fallback is the only
-- program that can ever run there. Building an image with
-- -Dboot_payload=test/boot/vmd_tcp.lua puts this in that slot; nothing
-- is injected and nothing is typed.
--
-- Why bother, when the qemu suite already covers all of this: because
-- the far side is a different TCP. Every test so far has talked to
-- slirp, which is a userspace reimplementation, or to Linux through it.
-- Here the peer is OpenBSD's own stack, on a machine that also chose
-- our address, answers our ARP, and is running the nc on the other end
-- of both connections. Two implementations agreeing is worth more than
-- one implementation agreeing with itself, and this is the only place
-- in the tree where the peer is neither Linux nor qemu.
--
-- It runs both directions, because they fail differently: an outbound
-- dial exercises our SYN and our receive path, an inbound connection
-- exercises listen, accept, and our send path under a window somebody
-- else is managing.

local sys = require("los.sys")
local thread = require("los.thread")
local captcp = require("caps.tcp")
local ip4 = require("ip4")
local sha256 = require("crypto.sha256")

local DIAL_PORT = 7001
local LISTEN_PORT = 7777

local function say(s)
	print("vmdtcp: " .. s)
end

local function hex(s)
	return (s:gsub(".", function(ch)
		return string.format("%02x", ch:byte())
	end))
end

local granted = sys.granted()

if not granted.tcp or not granted.ip then
	say("no tcp/ip capability; nothing to test")
	return
end

-- vmd's -L gives the guest a local interface with vmd's own dhcp server
-- behind it: the host takes 100.64.N.2 and hands us 100.64.N.3, so the
-- gateway is the machine running the test.
local cfg
local deadline = sys.uptime_ms() + 20000

repeat
	cfg = thread.rpc(granted.ip, { op = "config" })
	if cfg and cfg.ip and cfg.ip ~= ip4.ANY then
		break
	end
	thread.sleep(200)
until sys.uptime_ms() > deadline

if not cfg or not cfg.ip or cfg.ip == ip4.ANY then
	say("no address after 20s -- dhcp did not answer")
	return
end

say(string.format("address %s mask %s gw %s", ip4.str(cfg.ip),
    ip4.str(cfg.mask or ip4.ANY), ip4.str(cfg.gw or ip4.ANY)))

local net = captcp.new(granted.tcp)
local gw = cfg.gw

if not gw or gw == ip4.ANY then
	say("no gateway, so nothing to dial")
	return
end

local ga, gb, gc, gd = gw:byte(1, 4)

-- ---- outbound: read from the host ----

say("dialling " .. ip4.str(gw) .. ":" .. DIAL_PORT)

local conn = net.dial(ga, gb, gc, gd, DIAL_PORT)

if not conn then
	say("dial FAILED")
else
	local h = sha256.new()
	local got = 0
	local t0 = sys.uptime_ms()

	while true do
		local data = net.recv(conn, 16384)

		if not data then
			break
		end
		got = got + #data
		h:update(data)
	end

	local ms = sys.uptime_ms() - t0

	net.close(conn)
	say(string.format("received %d bytes in %d ms (%.0f KB/s)", got, ms,
	    ms > 0 and got / ms or 0))
	say("received sha256 " .. hex(h:final()))
end

-- ---- inbound: the host connects to us ----

local l = net.listen(LISTEN_PORT)

if not l then
	say("listen FAILED")
else
	say("listening on " .. LISTEN_PORT .. " -- connect now")

	local c = net.accept(l)

	if not c then
		say("accept FAILED")
	else
		local h = sha256.new()
		local got = 0
		local t0 = sys.uptime_ms()

		while true do
			local data = net.recv(c, 16384)

			if not data then
				break
			end
			got = got + #data
			h:update(data)
		end

		local ms = sys.uptime_ms() - t0

		say(string.format("accepted %d bytes in %d ms (%.0f KB/s)",
		    got, ms, ms > 0 and got / ms or 0))
		say("accepted sha256 " .. hex(h:final()))
		net.close(c)
	end
	net.close(l)
end

local s = thread.rpc(granted.tcp, { op = "stats" })

if s then
	say(string.format(
	    "seg_in=%d seg_out=%d seg_bad=%d no_conn=%d reset_sent=%d",
	    s.seg_in, s.seg_out, s.seg_bad, s.no_conn, s.reset_sent))
end

local ips = thread.rpc(granted.ip, { op = "stats" })

if ips then
	say(string.format("frames_in=%d raw_in=%d raw_dropped=%d out_fail=%d",
	    ips.frames_in, ips.raw_in, ips.raw_dropped, ips.frames_out_fail))
end

say("done")
