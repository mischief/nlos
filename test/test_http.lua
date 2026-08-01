#!/usr/bin/env lua5.4
-- http server test, host-driven: boots lua-os with a payload that
-- serves http on guest tcp/7777, forwards that to a host port, and
-- drives it with real HTTP/1.1 requests. emits TAP.
--
-- this is the only test that exercises the tcp path end to end --
-- listen, accept, recv, send, close -- against a client that isn't
-- itself. the guest cannot test this alone: qemu's usermode network
-- does not hairpin, so a guest dialing its own address just times out.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. package.path
local qemuarch = require("qemuarch")
local http = require("hosthttp")
local hostutil = qemuarch.hostutil

local img = arg[1]
local payload = arg[2]

local count, failed = 0, 0

-- a TAP description is one line by construction, so guest text quoted
-- into one has to be escaped rather than passed through. the python
-- these tests came from got that free from %r; without it a terminal
-- session's carriage returns reach the harness raw, and since meson
-- breaks lines on \r as well as \n every segment after the first
-- arrives unprefixed and fails the whole run on "Unknown TAP output"
-- -- even when every assertion passed.
local function oneline(s)
	return (tostring(s):gsub("%c", function(c)
		if c == "\n" then return "\\n" end
		if c == "\r" then return "\\r" end
		if c == "\t" then return "\\t" end
		return string.format("\\%03d", c:byte())
	end))
end

local function ok(cond, name)
	count = count + 1
	if not cond then
		failed = failed + 1
	end
	print((cond and "ok" or "not ok") .. " " .. count .. " - " ..
	    oneline(name))
	return cond
end

-- the normalisation scripts/boottest.lua applies to a serial log, for
-- the same reason: strip ansi and fold carriage returns into newlines
-- so that every line of a guest dump carries its own "# ".
local function diag(s)
	local t = tostring(s):gsub("\27%[[%d;=]*%a", ""):gsub("\r\n", "\n")

	t = t:gsub("\r", "\n")
	for line in (t .. "\n"):gmatch("([^\n]*)\n") do
		print("# " .. line)
	end
end

local function quote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function readfile(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local d = f:read("a")
	f:close()
	return d
end

local tmp = assert(io.popen("mktemp -d")):read("l")
local vars_path = tmp .. "/vars.fd"
local serial_log = tmp .. "/serial.log"

os.execute("cp " .. quote(qemuarch.FW_VARS) .. " " .. quote(vars_path))

local port = hostutil.free_port()

local argv = {}
local function extend(more)
	for _, v in ipairs(more) do
		argv[#argv + 1] = v
	end
end

extend(qemuarch.qemu())
extend(qemuarch.machine())
extend({ "-display", "none", "-monitor", "none" })
extend({ "-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:" .. port .. "-:7777" })
extend({ "-device", "virtio-net-pci,netdev=n0" })
extend({ "-no-reboot", "-snapshot" })
extend({ "-serial", "file:" .. serial_log })
extend(qemuarch.wire())
extend({ "-fw_cfg", "name=opt/org.luaos.test,file=" .. payload })
extend({ "-drive", "if=pflash,format=raw,readonly=on,file=" .. qemuarch.FW_CODE })
extend({ "-drive", "if=pflash,format=raw,file=" .. vars_path })
extend(qemuarch.disk(img))

local qemu_pid = hostutil.spawn(argv)
local reaped = false

local function cleanup()
	if not reaped then
		hostutil.kill(qemu_pid)
		hostutil.wait(qemu_pid)
	end
	if failed > 0 then
		local log = readfile(serial_log)
		if log then
			diag("guest serial log:")
			diag(log)
		end
	end
	os.execute("rm -rf " .. quote(tmp))
end

print("1..13")

local function main()
	-- the guest prints this once listen() finally succeeds, which is
	-- only after dhcp has handed it a lease.
	local deadline = os.time() + 60
	local up = false

	while os.time() < deadline do
		local content = readfile(serial_log)
		if content and content:find("http test server ready", 1, true) then
			up = true
			break
		end
		if hostutil.poll(qemu_pid) ~= nil then
			reaped = true
			break
		end
		os.execute("sleep 0.5")
	end
	if not ok(up, "guest http server came up") then
		return 1
	end

	local function get(path)
		return assert(http.get(hostutil, "127.0.0.1", port, path, 20))
	end
	local function post(path, body, headers)
		return assert(http.post(hostutil, "127.0.0.1", port, path, body, headers, 20))
	end

	local r = get("/hello")
	ok(r.status == 200, "GET /hello -> " .. r.status)
	ok(r.body == "you asked for /hello", "echoed path: " .. r.body)
	ok(r.headers["content-length"] == tostring(#r.body),
	    "Content-Length matches body")

	-- a handler that raises must become a 500, with the server still
	-- alive for the next request afterwards.
	r = get("/boom")
	local boom_ok = r.status == 500
	local r2 = get("/after")
	ok(boom_ok and r2.status == 200 and r2.body == "you asked for /after",
	    "handler error is a 500 and the server survives it")

	-- a body over MAXMSG (64KB) cannot go out as one message to the tcp
	-- task -- the serializer refuses it, which killed the connection
	-- and returned NOTHING rather than truncating.
	r = get("/big")
	ok(r.status == 200 and #r.body == 200000,
	    "a 200KB body survives the 64KB message ceiling (" .. #r.body .. " B)")

	-- a body the server WILL accept, to prove the cap is a ceiling and
	-- not a blanket refusal
	r = post("/echolen", string.rep("z", 1000))
	ok(r.status == 200 and r.body == "1000", "a normal POST body -> " .. r.body)

	-- ...and the attack: an enormous declared length must be refused on
	-- the Content-Length alone, without reading it. this loop runs in
	-- the server proc, and a boot payload has no mem_limit, so an
	-- unbounded read here exhausts the kernel heap for EVERY session
	-- rather than just the rude one.
	r = post("/echolen", string.rep("z", 100),
	    { ["Content-Length"] = tostring(1024 * 1024 * 1024) })
	ok(r.status == 413, "a 1GB Content-Length is refused unread -> " .. r.status)

	-- and the server is still alive afterwards, which is the point
	r = get("/alive")
	ok(r.status == 200 and r.body == "you asked for /alive",
	    "server survives the oversized request")

	r = get("/files/hello.txt")
	ok(r.status == 200 and r.body == "static file contents\n",
	    "static GET /files/hello.txt -> " .. r.status .. " " .. r.body)
	ok(r.headers["content-type"] == "text/plain",
	    "static Content-Type guessed from extension")

	r = get("/files/big.bin")
	ok(r.status == 200 and r.body == string.rep("x", 200000),
	    "static streaming body crosses more than one chunk intact")

	r = get("/files/../secret")
	ok(r.status == 404,
	    "static traversal contained, not leaked -> " .. r.status .. " " .. r.body)

	return 0
end

local runok, runerr = pcall(main)
local rc = 0

if not runok then
	diag("exception: " .. tostring(runerr))
	rc = 1
else
	rc = runerr
end
if failed > 0 then
	rc = 1
end

cleanup()
os.exit(rc)
