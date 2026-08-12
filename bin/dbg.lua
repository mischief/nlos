-- dbg [pid | run PROG [args...]]: stop a proc, look at it, resume it.
-- `run` spawns the target and holds its right; a bare pid needs the dbg
-- capability the launcher lends, which reaches anything. `?` lists the
-- commands, and docs/debugging.md explains them.

local prog = require("prog")
local sys = require("los.sys")
local kdbg = require("los.dbg")
local dbglib = require("dbg")
local thread = require("los.thread")
local ns = require("ns")

local ctx = prog.ctx
local out = ctx and ctx.stdout
local stdin = ctx and ctx.stdin

local function say(s)
	if out then out:write(s .. "\n") end
end

local function die(s)
	say("dbg: " .. s)
	os.exit(1)
end

-- ---- what we are debugging, and by what right ----
local target, ctl, spawned

local a = { ... }
local argv = arg or a

-- the same search the shell does, so `dbg run echo` names the program
-- the way a user names it. Without it only the literal file path works,
-- and /bin/echo -- which is echo.lua -- is not one.
local function find(name)
	local N = ctx and ctx.ns

	if not N then return name end
	if name:find("/") then
		local p = name:sub(1, 1) == "/" and name or
		    ns.clean((ctx.cwd or "/") .. "/" .. name)

		return N:stat(p) and p or nil
	end
	for dir in ((ctx.env and ctx.env.PATH) or "/bin"):gmatch("[^:]+") do
		for _, cand in ipairs({ dir .. "/" .. name .. ".lua",
		    dir .. "/" .. name }) do
			if N:stat(cand) then return cand end
		end
	end
	return nil
end

if argv[1] == "run" then
	local name = argv[2]

	if not name then die("run wants a program") end

	local path = find(name)

	if not path then die(name .. ": not found") end

	-- argv, not the arguments alone: lib/prog shifts this by one, so
	-- the program's own name belongs at [1]. Getting it wrong is
	-- silent -- every argument arrives one place off.
	local args = { name }

	for i = 3, #argv do args[#args + 1] = argv[i] end

	local pid, h = require("proc").spawn('require("prog").main()',
	    { name = path:match("([^/]+)$") or path,
	      ns = ctx and ctx.nsdesc })

	if not pid then die("cannot spawn " .. path) end
	-- the ABI message the target is already blocked waiting for. Our
	-- own stdout is lent to it: the stream keeps the right it wraps,
	-- and a right is copied by being sent.
	local outh = out and out.h

	target, ctl, spawned = pid, h, {
		path = path, name = name, args = args,
		env = ctx and ctx.env, cwd = ctx and ctx.cwd,
		nsdesc = ctx and ctx.nsdesc,
		stdout = outh and { __right = outh } or nil,
		stderr = outh and { __right = outh } or nil,
	}
	-- the target is parked in prog.main's first recv, before its own
	-- first line, so breakpoints can be set before anything runs.
	say(("dbg: %s is proc %d, stopped before its first line"):format(
	    path, pid))
elseif tonumber(argv[1]) then
	target = tonumber(argv[1])
	if not ctx or not ctx.dbg then
		die("no debug capability: the launcher lent none")
	end
else
	die("usage: dbg PID | dbg run PROG [args...]")
end

local notice = sys.newport("dbg.notice")
local d = dbglib.new(target, notice)
local ok, err = pcall(d.attach, d)

if not ok then die(tostring(err)) end
sys.atexit(function() pcall(kdbg.detach, target) end)

-- Stopping is not dying: the target keeps every right it holds, so its
-- ports go on queueing and its clients go on waiting. Stopping a server
-- stops whoever is talking to it.
local nports = 0

for _, p in ipairs(sys.ports()) do
	if p.pid == target then nports = nports + 1 end
end
if nports > 1 then
	say(("dbg: warning -- proc %d holds %d ports; stopping it makes " ..
	    "its clients wait"):format(target, nports))
end

-- What it is, what state it is in, and the one thing to type next.
-- A prompt that says only "dbg>" leaves all three to be guessed at.
say(("attached to proc %d (%s), %s"):format(target,
    tostring(sys.name(target)), sys.wchan(target) == "stopped" and
    "stopped" or "running"))
if spawned then
	say("it is parked before its first line: set breakpoints, then c")
else
	say("it is running: `stop` to catch it, or `b FILE:LINE` and wait")
end
say("`help` lists the commands.")

-- ---- the commands ----
local quit = false
local last

local function bp(a1)
	local file, line = tostring(a1):match("^(.+):(%d+)$")

	if not file then return say("b wants FILE:LINE") end

	local id = kdbg.setbreak(target, file, tonumber(line))

	say(("breakpoint %d at %s:%s"):format(id, file, line))
end

local function resume(how)
	if spawned then
		-- the first continue is what releases the target: it has
		-- never been sent the message prog.main is waiting for.
		sys.send(ctl, spawned)
		spawned = nil
		return
	end
	-- said here rather than let through as the kernel's "proc is not
	-- stopped", which reads as a failure rather than as the answer.
	if sys.wchan(target) ~= "stopped" then
		return say("it is not stopped -- `stop` catches it, or set " ..
		    "a breakpoint with b FILE:LINE")
	end
	if how == "c" then return kdbg.cont(target) end
	return kdbg.step(target,
	    how == "n" and "over" or how == "fin" and "out" or "in")
end

-- name -> function. `help` below names them again with what they do,
-- in the order someone meets them rather than alphabetically.
local cmds = {}

function cmds.b(a1) bp(a1) end
function cmds.d(a1) kdbg.clearbreak(target, tonumber(a1) or 0) end

function cmds.bp()
	local list = kdbg.breaks(target)

	if #list == 0 then return say("no breakpoints") end
	for _, b in ipairs(list) do
		say(("%d  %s:%d  %d hits"):format(b.id, b.file, b.line,
		    b.hits))
	end
end

function cmds.stop() kdbg.stop(target) end
function cmds.c() resume("c") end
function cmds.s() resume("s") end
function cmds.n() resume("n") end
function cmds.fin() resume("fin") end

function cmds.bt()
	for _, l in ipairs(d:backtrace()) do say(l) end
end

function cmds.co(a1)
	if a1 then
		d.co = tonumber(a1) or d.co
		d.level = 0
		return
	end
	for _, c in ipairs(kdbg.coros(target)) do
		say(("%s%d  %s%s"):format(c.i == d.co and "* " or "  ",
		    c.i, c.label, c.stopped and "  <- stopped here" or ""))
	end
end

function cmds.f(a1)
	d.level = tonumber(a1) or 0
	say(("frame %d"):format(d.level))
end

function cmds.l()
	for _, l in ipairs(d:slots("local")) do say(l) end
end

function cmds.u()
	for _, l in ipairs(d:slots("up")) do say(l) end
end

function cmds.p(a1)
	local s, e = d:print(a1 or "")

	say(s or ("dbg: " .. tostring(e)))
end

function cmds.w() say(d:wheretext()) end

function cmds.k()
	if ctl then sys.kill(ctl) else say("no right to kill it") end
end

function cmds.q()
	pcall(d.detach, d)
	quit = true
end

local helptext = {
	{ "where it is" },
	{ "w", "", "where it stopped, and why" },
	{ "bt", "", "backtrace of the selected coroutine" },
	{ "co", "[N]", "list coroutines, or select one" },
	{ "f", "N", "select a frame, 0 being the innermost" },

	{ "what it holds" },
	{ "l", "", "locals of the selected frame" },
	{ "u", "", "its upvalues" },
	{ "p", "PATH", "print a value: p cfg, p cfg.net.mtu, p t[2]" },

	{ "breakpoints" },
	{ "b", "FILE:LINE", "break there, e.g. b fatsrv:210" },
	{ "bp", "", "list them, with hit counts" },
	{ "d", "[ID]", "delete one, or all of them" },

	{ "running it" },
	{ "stop", "", "stop at the next line it runs" },
	{ "c", "", "continue" },
	{ "s", "", "step into the next line" },
	{ "n", "", "step over it" },
	{ "fin", "", "run to the end of this frame" },

	{ "leaving" },
	{ "k", "", "kill the target" },
	{ "q", "", "detach and quit; the target runs on" },
}

function cmds.help()
	say(d:wheretext())
	for _, h in ipairs(helptext) do
		if #h == 1 then
			say("")
			say(h[1])
		else
			say(("  %-4s %-10s %s"):format(h[1], h[2], h[3]))
		end
	end
	say("")
	say("an empty line repeats the last command, which is what makes " ..
	    "s and n bearable")
end

cmds["?"] = cmds.help
cmds.h = cmds.help

-- Two threads: a stop arrives while the reader is blocked on stdin,
-- and has to print then rather than after the next command.
thread.spawn(function()
	while not quit do
		local m = thread.recvtimeout(notice, 250)

		if m and d:onstop(m) then
			say("")
			say(d:wheretext())
			if m.exit then quit = true end
		end
	end
end)

thread.spawn(function()
	local buf = ""

	if out then out:write("dbg> ") end
	while not quit do
		local chunk = stdin and stdin:read() or nil

		if not chunk or chunk == "" then
			if not stdin then break end
			thread.sleep(20)
			goto continue
		end
		buf = buf .. chunk
		while true do
			local line, rest = buf:match("^([^\n]*)\n(.*)$")

			if not line then break end
			buf = rest

			local cmd, a1 = line:match("^%s*(%S+)%s*(.-)%s*$")

			-- an empty line repeats: stepping is a key at a
			-- time, and typing `n` each time is the difference
			-- between using this and not.
			if not cmd and last then
				cmd, a1 = last[1], last[2]
			end
			if cmd then
				local f = cmds[cmd]

				if f then
					last = { cmd, a1 }

					local okc, e = pcall(f,
					    a1 ~= "" and a1 or nil)

					if not okc then
						say("dbg: " .. tostring(e))
					end
				else
					say(("dbg: no command %q -- type " ..
					    "help"):format(cmd))
				end
			end
			if not quit and out then out:write("dbg> ") end
		end
		::continue::
	end
	quit = true
end)

thread.run()
sys.close(notice)
