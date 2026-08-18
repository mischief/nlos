#!/usr/bin/env lua5.4
-- 9p protocol test, host-driven: boots lua-os with the srv9p payload,
-- speaks real 9P2000 over the com2 unix socket, emits TAP.
--
-- deliberately hand-rolls its own wire encode/decode rather than
-- require("ninep") -- the guest side (test/boot/srv9p.lua) already
-- requires("ninep") itself, so reusing it here would make this test
-- blind to a real bug in lib/ninep.lua's codec: client and server
-- would be using the exact same (possibly wrong) code. see the
-- similar note in hosthttp.lua.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. package.path
local qemuarch = require("qemuarch")
local hostutil = qemuarch.hostutil

local spack, sunpack = string.pack, string.unpack

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

local function s9(s)
	return spack("<I2", #s) .. s
end

-- ---- 9p client ----

local Client = {}
Client.__index = Client

function Client.new(path)
	local fd, err = hostutil.connect_unix(path)
	if not fd then
		error("connect_unix: " .. tostring(err))
	end
	return setmetatable({ fd = fd, buf = "" }, Client)
end

function Client:readmsg()
	while true do
		if #self.buf >= 4 then
			local size = sunpack("<I4", self.buf)
			if #self.buf >= size then
				local m = self.buf:sub(1, size)
				self.buf = self.buf:sub(size + 1)
				return m
			end
		end
		local d, err = hostutil.recv(self.fd, 4096, 20)
		if not d then
			error("recv: " .. tostring(err))
		end
		if d == "" then
			error("EOF")
		end
		self.buf = self.buf .. d
	end
end

function Client:rpc(t, tag, body)
	local msg = spack("<I4BI2", 7 + #body, t, tag) .. body
	local sok, serr = hostutil.send(self.fd, msg)
	if not sok then
		error("send: " .. tostring(serr))
	end
	local m = self:readmsg()
	local typ, rtag, off = sunpack("<BI2", m, 5)

	if typ == 107 then
		local elen, eoff = sunpack("<I2", m, off)
		error("Rerror: " .. m:sub(eoff, eoff + elen - 1))
	end
	if typ ~= t + 1 or rtag ~= tag then
		error(string.format("bad reply type=%d tag=%d", typ, rtag))
	end
	return m:sub(off)
end

-- ---- main ----

local tmp = assert(io.popen("mktemp -d")):read("l")
local sock_path = tmp .. "/9p.sock"
local vars_path = tmp .. "/vars.fd"
local serial_log = tmp .. "/serial.log"

os.execute("cp " .. quote(qemuarch.FW_VARS) .. " " .. quote(vars_path))

local argv = {}
local function extend(more)
	for _, v in ipairs(more) do
		argv[#argv + 1] = v
	end
end

extend(qemuarch.qemu())
extend(qemuarch.machine())
extend(qemuarch.rng())
extend({ "-display", "none", "-net", "none", "-monitor", "none" })
extend({ "-no-reboot", "-snapshot" })
extend({ "-serial", "file:" .. serial_log })
extend(qemuarch.wire(sock_path))
extend({ "-fw_cfg", "name=opt/org.luaos.test,file=" .. payload })
extend({ "-drive", "if=pflash,format=raw,readonly=on,file=" .. qemuarch.FW_CODE })
extend({ "-drive", "if=pflash,format=raw,file=" .. vars_path })
extend(qemuarch.disk(img))

local qemu_pid = hostutil.spawn(argv)

local function cleanup()
	hostutil.kill(qemu_pid)
	hostutil.wait(qemu_pid)
	os.execute("rm -rf " .. quote(tmp))
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

print("1..8")

local function main()
	local deadline = os.time() + 30
	local c

	while os.time() < deadline do
		local content = readfile(serial_log)
		if content and content:find("9p test server ready", 1, true) then
			c = Client.new(sock_path)
			break
		end
		hostutil.sleep(0.05)
	end
	if not ok(c ~= nil, "guest 9p server came up") then
		return 1
	end

	-- version
	local r = c:rpc(100, 0xFFFF, spack("<I4", 8192) .. s9("9P2000"))
	local ms, vl, voff = sunpack("<I4I2", r)
	ok(r:sub(voff, voff + vl - 1) == "9P2000", "version negotiation")

	-- attach
	r = c:rpc(104, 1, spack("<I4I4", 0, 0xFFFFFFFF) .. s9("host") .. s9(""))
	ok(r:byte(1) == 0x80, "attach returns directory qid")

	-- walk + open + read README
	c:rpc(110, 2, spack("<I4I4I2", 0, 1, 1) .. s9("README"))
	c:rpc(112, 3, spack("<I4B", 1, 0))
	r = c:rpc(116, 4, spack("<I4I8I4", 1, 0, 4096))
	local n = sunpack("<I4", r)
	ok(r:sub(5, 4 + n):find("mounted over 9p", 1, true) ~= nil,
	    "read README content")
	c:rpc(120, 5, spack("<I4", 1))

	-- list root
	c:rpc(110, 6, spack("<I4I4I2", 0, 2, 0))
	c:rpc(112, 7, spack("<I4B", 2, 0))
	r = c:rpc(116, 8, spack("<I4I8I4", 2, 0, 4096))
	n = sunpack("<I4", r)
	local data = r:sub(5, 4 + n)
	local names, off = {}, 1
	while off <= #data do
		local sz, entoff = sunpack("<I2", data, off)
		local ent = data:sub(entoff, entoff + sz - 1)
		local nl = sunpack("<I2", ent, 40)
		names[#names + 1] = ent:sub(42, 41 + nl)
		off = entoff + sz
	end
	table.sort(names)
	local want = { "README", "echo", "proc", "ticks", "uname" }
	local match = #names == #want
	if match then
		for i = 1, #want do
			if names[i] ~= want[i] then
				match = false
			end
		end
	end
	ok(match, "root directory listing")

	-- nested walk: proc/list
	c:rpc(110, 9, spack("<I4I4I2", 0, 3, 2) .. s9("proc") .. s9("list"))
	c:rpc(112, 10, spack("<I4B", 3, 0))
	r = c:rpc(116, 11, spack("<I4I8I4", 3, 0, 4096))
	n = sunpack("<I4", r)
	local pidstr = r:sub(5, 4 + n)
	local pids = {}
	for p in pidstr:gmatch("%S+") do
		pids[#pids + 1] = p
	end
	local pidsok = #pids >= 1
	for _, p in ipairs(pids) do
		if not p:match("^%d+$") then
			pidsok = false
		end
	end
	ok(pidsok, "proc/list dynamic read")

	-- walk to a nonexistent file errors
	local wok, werr = pcall(function()
		c:rpc(110, 12, spack("<I4I4I2", 0, 4, 1) .. s9("nope"))
	end)
	ok((not wok) and tostring(werr):find("not found", 1, true) ~= nil,
	    "walk to missing file errors")

	-- write to the echo file (Twrite path)
	c:rpc(110, 13, spack("<I4I4I2", 0, 5, 1) .. s9("echo"))
	c:rpc(112, 14, spack("<I4B", 5, 1))
	r = c:rpc(118, 15, spack("<I4I8I4", 5, 0, 5) .. "hello")
	ok(sunpack("<I4", r) == 5, "write accepted")

	return 0
end

local runok, runerr = pcall(main)
local rc = 0

if not runok then
	diag("exception: " .. tostring(runerr))
	local log = readfile(serial_log)
	if log then
		diag(log)
	end
	count = count + 1
	print("not ok " .. count .. " - unhandled exception")
	rc = 1
else
	rc = runerr
	if failed > 0 then
		rc = 1
	end
end

cleanup()
os.exit(rc)
