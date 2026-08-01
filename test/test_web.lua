#!/usr/bin/env lua5.4
-- web terminal test, host-driven: boots lua-os with a payload that
-- serves the browser shell on guest tcp/7777, forwards that to a host
-- port, and drives it as the page's javascript would. emits TAP.
--
-- what this actually covers is the whole capability chain -- http
-- handler -> session port -> spawned unprivileged dos proc -> its
-- namespace -> back out as text -- which no in-guest test can reach,
-- since qemu's usermode network does not hairpin.

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

local function ok(cond, name)
	count = count + 1
	if not cond then
		failed = failed + 1
	end
	print((cond and "ok" or "not ok") .. " " .. count .. " - " .. name)
	return cond
end

local function diag(s)
	for line in (tostring(s) .. "\n"):gmatch("([^\n]*)\n") do
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

print("1..22")

local function main()
	local deadline = os.time() + 60
	local up = false

	while os.time() < deadline do
		local content = readfile(serial_log)
		if content and content:find("web terminal ready", 1, true) then
			up = true
			break
		end
		if hostutil.poll(qemu_pid) ~= nil then
			reaped = true
			break
		end
		os.execute("sleep 0.5")
	end
	if not ok(up, "guest web terminal came up") then
		return 1
	end

	local function req(method, path, body)
		return assert(http.request(hostutil, "127.0.0.1", port, method,
		    path, body, nil, 30))
	end

	-- POST helper: parses the body as JSON, falling back to
	-- {_raw=body} on a parse failure -- same fallback test_web.py's
	-- post() used.
	local function post(path, body)
		local r = req("POST", path, body)
		local parsed = json.decode(r.body)
		if parsed == nil then
			parsed = { _raw = r.body }
		end
		return r, parsed
	end

	local r = req("GET", "/")
	ok(r.status == 200 and r.body:find('<pre id="scr">', 1, true) ~= nil,
	    string.format("GET / serves the page (%d, %d bytes)", r.status, #r.body))

	-- a session is a real proc: the banner and the first prompt come
	-- back with it, because the shell asks for a line before there is
	-- anything to answer with.
	local r2, j = post("/session", nil)
	if not ok(r2.status == 200 and j.id ~= nil,
	    "POST /session creates one (" .. r2.status .. ")") then
		diag(json.encode(j))
		return 1
	end
	local sid = j.id
	ok((j.out or ""):sub(-2) == "> ",
	    "banner arrives ending at a prompt: " .. tostring(j.out))

	local function line(text)
		local rr, jj = post("/session/" .. sid, text)
		return rr, jj.out or ""
	end

	-- a builtin: no proc spawned, pure launcher state.
	local rr, out = line("pwd")
	ok(rr.status == 200 and out:sub(1, 1) == "/" and out:sub(2, 2) == "\n",
	    "pwd -> " .. out)

	-- a real program: dos spawns it, prog.lua gives it the ABI, and its
	-- stdout is the same session port the shell writes to.
	rr, out = line("seq 1 5")
	ok(out:find("1\n2\n3\n4\n5\n", 1, true) ~= nil, "seq 1 5 -> " .. out)

	-- the namespace: this content exists only as a lua table in the
	-- server's payload, and reached the visitor as nsdesc.
	rr, out = line("cat /notes/hello")
	ok(out:find("one lua table", 1, true) ~= nil,
	    "cat through the namespace -> " .. out)

	rr, out = line("ls /bin")
	ok(out:find("seq.lua", 1, true) ~= nil and out:find("cat.lua", 1, true) ~= nil,
	    "ls /bin -> " .. out)

	-- discoverability: programs are files, so `ls /bin` always found
	-- them -- but the builtins live in a lua table in the launcher and
	-- had no listing anywhere, so `exit` could only be guessed. help
	-- ENUMERATES both, so adding a builtin cannot leave it out.
	rr, out = line("help")
	ok(out:find("exit", 1, true) ~= nil and out:find("cd", 1, true) ~= nil and
	    out:find("seq", 1, true) ~= nil, "help lists builtins and programs -> " .. out)

	-- and the moment a lost user actually needs it
	rr, out = line("nosuchthing")
	ok(out:find("help", 1, true) ~= nil,
	    "an unknown command points at help -> " .. out)

	-- THE sandbox assertion. a visitor's program must not be able to
	-- reach the disk behind its namespace. proc_new nils io.open /
	-- loadfile / dofile for every proc but PRIV_BOOT, and prog.lua adds
	-- back only io.write -- so this is checking the property the whole
	-- public-shell idea rests on, in the one place a visitor can
	-- actually run code.
	rr, out = line("probe")
	ok(out:find("io.open=false", 1, true) ~= nil and
	    out:find("loadfile=false", 1, true) ~= nil and
	    out:find("dofile=false", 1, true) ~= nil,
	    "a visitor's program has no ambient file access -> " .. out)

	-- a session is ONE proc: programs run as coroutines beside the
	-- shell (dos coro=true), so two runs report the same pid. under the
	-- spawn path each would be a proc of its own and they would differ.
	-- this is what takes MAXPROCS off the visitor ceiling.
	local first = out:match("pid=(%d+)")
	local out2
	rr, out2 = line("probe")
	local second = out2:match("pid=(%d+)")
	ok(first and second and first == second,
	    "programs share the session's proc (" .. tostring(first) .. " == " ..
	    tostring(second) .. ")")

	-- and a pipeline still works when both stages are coroutines in
	-- that one proc, joined by a Channel rather than a port
	rr, out = line("seq 3 | cat")
	ok(out:find("1\n2\n3\n", 1, true) ~= nil,
	    "seq 3 | cat as coroutines -> " .. out)

	-- writes land in the visitor's private copy of the tree
	rr, out = line("seq 1 3 > /tmp/x")
	rr, out = line("cat /tmp/x")
	ok(out:find("1\n2\n3\n", 1, true) ~= nil, "write then read back -> " .. out)

	-- a nonexistent session must not be a 500 or a hang
	local jr
	rr, jr = post("/session/nope-1", nil)
	ok(rr.status == 404, "unknown session -> " .. rr.status)

	-- `exit` ends the shell while the request handler is parked in
	-- pump() on that session's port. the janitor hears the exit notice
	-- and must NOT close the port underneath it: thread.run passes
	-- every parked port to altblock in one call, so a right vanishing
	-- there raises from the scheduler and kills the whole server proc.
	-- this took the server down the first time it was tried by hand.
	rr, jr = post("/session/" .. sid, "exit")
	ok(rr.status == 200 and jr.ended == true,
	    "exit reports the session ended (" .. rr.status .. ")")

	-- the session is gone...
	rr, jr = post("/session/" .. sid, "pwd")
	ok(rr.status == 404, "the ended session is really gone -> " .. rr.status)

	-- ...and, the point of the test, the SERVER is still alive and
	-- still able to hand out new ones.
	rr, jr = post("/session", nil)
	local alive = rr.status == 200 and jr.id ~= nil
	if alive then
		local rr2, jr2 = post("/session/" .. jr.id, "pwd")
		alive = rr2.status == 200 and (jr2.out or ""):sub(1, 2) == "/\n"
	end
	if not ok(alive, "server survives a session exiting and serves a new one") then
		return 1
	end
	sid = jr.id

	-- pump's deadline. `drip` paces its output (see srvweb.lua): slow
	-- enough never to fill MAXQUEUE, steady enough to keep the drain
	-- loop fed indefinitely. the drain path used to consult the timer
	-- case ONLY when the queue came up empty, so this request never
	-- returned -- alt picks the first ready case in array order, so no
	-- ordering of the cases could have fixed it either.
	local t0 = os.time()
	rr, jr = post("/session/" .. sid, "drip")
	local elapsed = os.time() - t0
	ok(rr.status == 200 and jr.running == true and elapsed < 20,
	    string.format("paced output returns at the deadline (%ds, running=%s)",
	        elapsed, tostring(jr.running)))
	ok((jr.out or ""):find("drip 1\n", 1, true) ~= nil,
	    "...with the output so far: " .. tostring((jr.out or ""):sub(1, 40)))

	-- and the rest is still collectable: nothing was lost, the program
	-- just outlived one request.
	rr, jr = post("/session/" .. sid, "")
	ok(rr.status == 200 and (jr.out or ""):find("drip", 1, true) ~= nil,
	    "a follow-up request collects more of the same program's output")

	-- backpressure. a program writing flat out used to die at ~1600
	-- line-writes with "port queue full" -- MAXQUEUE is 64KB of
	-- SERIALIZED bytes, and {op="write", data="N\n"} costs ~40 of them
	-- to carry ~5. now a full pipe parks the writer until the reader
	-- drains, so this completes however long it takes.
	rr, jr = post("/session", nil)
	local bp = rr.status == 200 and jr.id ~= nil

	if bp then
		local bsid = jr.id
		local seen, guard = "", 0
		local k

		rr, k = post("/session/" .. bsid, "seq 1 20000")
		seen = seen .. (k.out or "")
		while k.running and guard < 40 do
			guard = guard + 1
			rr, k = post("/session/" .. bsid, "")
			seen = seen .. (k.out or "")
		end
		bp = seen:find("port queue full", 1, true) == nil and
		    seen:find("20000\n", 1, true) ~= nil
	end
	ok(bp, "a flat-out writer gets backpressure, not a full-queue error")

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
