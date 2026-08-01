#!/usr/bin/env lua5.4
-- mcp server test, host-driven: boots lua-os with an mcp payload on
-- guest tcp/7777, forwards it to a host port, and speaks real
-- JSON-RPC 2.0 over HTTP POST. emits TAP.
--
-- covers the whole stack at once -- tcp, http, json, mcp -- which is
-- the point: each layer is tested on its own elsewhere, this checks
-- they compose. lib/json.lua is reused as-is here (unlike
-- hosthttp.lua's deliberate independence from lib/http.lua): json
-- codec correctness isn't what this test is verifying, mcp/JSON-RPC
-- semantics are, so there's no independent-verification property to
-- protect by reimplementing it.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. scriptdir .. "/../lib/?.lua;" ..
    package.path
local qemuarch = require("qemuarch")
local http = require("hosthttp")
local json = require("json")
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

print("1..8")

local function main()
	local deadline = os.time() + 60
	local up = false

	while os.time() < deadline do
		local content = readfile(serial_log)
		if content and content:find("mcp test server ready", 1, true) then
			up = true
			break
		end
		if hostutil.poll(qemu_pid) ~= nil then
			reaped = true
			break
		end
		os.execute("sleep 0.5")
	end
	if not ok(up, "guest mcp server came up") then
		return 1
	end

	local function rpc(method, params, rid)
		local body = { jsonrpc = "2.0", id = rid or 1, method = method }
		if params ~= nil then
			body.params = params
		end
		local r = assert(http.post(hostutil, "127.0.0.1", port, "/",
		    json.encode(body), { ["Content-Type"] = "application/json" }, 20))
		local parsed = #r.body > 0 and json.decode(r.body) or nil
		return r.status, parsed
	end

	local st, r = rpc("initialize")
	ok(st == 200 and r.result and r.result.protocolVersion,
	    "initialize -> " .. tostring(r and r.result and r.result.protocolVersion))
	ok(r.result.serverInfo.name == "lua-os", "serverInfo identifies the server")

	st, r = rpc("tools/list")
	local names = {}
	for _, t in ipairs(r.result.tools) do
		names[#names + 1] = t.name
	end
	table.sort(names)
	ok(names[1] == "boom" and names[2] == "echo" and #names == 2,
	    "tools/list -> " .. table.concat(names, ","))

	st, r = rpc("tools/call", { name = "echo", arguments = { text = "hi" } })
	ok(r.result.content[1].text == "echo: hi",
	    "tools/call returns the tool result")

	-- a raising tool is an MCP-level isError result, not a dead
	-- connection and not a transport error.
	st, r = rpc("tools/call", { name = "boom", arguments = {} })
	ok(st == 200 and r.result.isError == true,
	    "a raising tool becomes isError, not a crash")

	st, r = rpc("tools/call", { name = "nope", arguments = {} })
	ok(r.error and r.error.code == -32602,
	    "unknown tool is a json-rpc error")

	st, r = rpc("no/such/method")
	ok(r.error and r.error.code == -32601,
	    "unknown method is a json-rpc error, server still alive")

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
