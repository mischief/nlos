-- lib/ssh/client.lua against a real OpenSSH server, which the harness
-- runs on the host and the guest reaches at 10.0.2.2. The key, port and
-- user are substituted in by tools/sshclienttest.lua.

-- It is also the only test receiving more than one segment from
-- outside: a KEXINIT is 1656 bytes against a 1460 mss, and a receive
-- buffer one frame too small drops exactly that, silently.
local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local tcpc = require("client.tcp")
local drbg = require("crypto.drbg")
local client = require("ssh.client")
local keys = require("ssh.keys")

tap.plan(6)

local KEY = [==[
@@KEY@@]==]

-- quoted, so this file is valid lua before the harness fills it in
local PORT = tonumber("@@PORT@@")
local USER = "@@USER@@"

local seed, pk = keys.parse_private(KEY)

tap.ok(seed ~= nil and #seed == 32, "the openssh private key parses")
if not seed then
	tap.diag(tostring(pk))
	tap.done()
	return
end

local g = sys.granted()

tap.ok(g.tcp ~= nil, "the guest has a tcp capability")

-- dhcpd binds a few seconds in, and a dial before that has no source
-- address: it shows as a dial that never answers rather than one that
-- fails.
thread.sleep(5000)

local net = tcpc.new(g.tcp)
local rng = drbg.new((tostring(sys.uptime_ms()) ..
    "-lua-os-ssh-client-test-seed"):rep(4):sub(1, 48))
local connid = net.dial(10, 0, 2, 2, PORT)

tap.ok(connid ~= nil and connid ~= false, "dialled the host's sshd")
if not connid or connid == false then
	tap.done()
	return
end

local inbuf = ""
local conn = {
	rand = rng.bytes,

	read = function(n)
		while #inbuf < n do
			local d = net.recv(connid, 4096)

			if d == nil or d == false then
				return nil, "closed"
			end
			inbuf = inbuf .. d
		end

		local s = inbuf:sub(1, n)

		inbuf = inbuf:sub(n + 1)
		return s
	end,

	readline = function()
		while true do
			local at = inbuf:find("\n", 1, true)

			if at then
				local l = inbuf:sub(1, at - 1)

				inbuf = inbuf:sub(at + 1)
				return l
			end

			local d = net.recv(connid, 4096)

			if d == nil or d == false then
				return nil, "closed"
			end
			inbuf = inbuf .. d
		end
	end,

	write = function(s) return net.send(connid, s) end,
}

local C = client.new(conn)
local out = {}

-- Every step in order, so a failure names the one that broke rather
-- than reporting "it did not work".
local function run()
	local ok, err = C:banner()

	if not ok then return "banner: " .. tostring(err) end
	ok, err = C:kex()
	if not ok then return "kex: " .. tostring(err) end
	ok, err = C:service("ssh-userauth")
	if not ok then return "service: " .. tostring(err) end
	ok, err = C:auth_publickey(USER, seed, pk)
	if not ok then return "auth: " .. tostring(err) end

	local ch

	ch, err = C:session()
	if not ch then return "session: " .. tostring(err) end
	-- and 64KB of it, which is what makes the far end send full-size
	-- segments. Under one is the only size a receive buffer a frame
	-- too small still delivers, so a small command passes either way.
	ok, err = C:exec(ch, "echo hello-from-lua-os; echo to-stderr >&2; " ..
	    "dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr '\\0' 'x'")
	if not ok then return "exec: " .. tostring(err) end

	local status

	status, err = C:pump(ch, function(data)
		out[#out + 1] = data
	end)
	if not status then return "pump: " .. tostring(err) end
	return nil
end

local why = run()

tap.ok(why == nil, "banner, kex, auth, session and exec" ..
    (why and (": " .. why) or ""))

local text = table.concat(out)

tap.ok(text:find("hello-from-lua-os", 1, true) ~= nil and
    text:find("to-stderr", 1, true) ~= nil,
    "both output streams came back")

tap.ok(#text >= 65536, ("all 64KB arrived, in full-size frames: %d bytes")
    :format(#text))

net.close(connid)
tap.done()
