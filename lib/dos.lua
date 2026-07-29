-- dos: the launcher. DOS-shaped on purpose, and taken literally.
--
-- COMMAND.COM was not a special layer that approximated a program
-- launcher -- it WAS a program, and so was everything it ran. so this is
-- deliberately small: prompt, split a line, find a program, spawn it
-- with the ABI, wait, report status. no job control, no subshells, no
-- $(...), no globbing.
--
-- that is not a stepping stone to a "real" shell. sh.lua, when it
-- exists, is a PROGRAM you run from here -- and so is vi.lua, and so is
-- gfx.lua. posix semantics stop being a property of the platform and
-- become a property of one program, which is why nothing here needs to
-- grow subshell state inheritance or signals.
--
-- see lib/prog.lua for the ABI and docs/shell-namespace-draft.md for how
-- this fits together.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")

local M = {}

-- ---- a pipe IS a port ----
--
-- one writer sends {op="write", data=} into it, one reader takes them
-- off, and sys.hungup tells the reader when nobody else holds a right,
-- which is eof. no server sits in the middle: the port queue is the
-- buffer and the kernel reports the hangup.
--
-- there WAS a server here -- a coroutine relaying between two ports --
-- and it was wrong twice over. it cost 3 messages and 2 proc switches
-- per chunk where a bare port costs 1 and 1, because it lived in the
-- launcher, a third proc between the two ends. and it needed a
-- two-signal shutdown protocol, {op="close"} then {op="stop"}, purely to
-- synthesise an eof the kernel could not report. plan 9 puts pipes in
-- the kernel for exactly this reason: devpipe hands out Chans, but the
-- bytes go through Queues in kernel memory, never through a server
-- process.
--
-- the launcher must drop its own right to a pipe once both ends are
-- handed out, or it stays a holder and the reader never sees eof.

-- ---- word splitting and redirection ----
--
-- quotes are handled because paths and echo arguments need them; that is
-- the extent of the parsing ambition.
local function split(line)
	local words = {}
	local cur, inq = nil, nil

	local function flush()
		if cur then
			words[#words + 1] = cur
			cur = nil
		end
	end

	for i = 1, #line do
		local c = line:sub(i, i)

		if inq then
			if c == inq then
				inq = nil
			else
				cur = (cur or "") .. c
			end
		elseif c == '"' or c == "'" then
			inq = c
			cur = cur or ""
		elseif c:match("%s") then
			flush()
		else
			cur = (cur or "") .. c
		end
	end
	flush()
	return words
end

M.split = split

-- pull redirections out of a word list, returning the remaining argv
local function redirs(words)
	local argv, r = {}, {}
	local i = 1

	while i <= #words do
		local w = words[i]

		if w == ">" or w == ">>" or w == "<" then
			i = i + 1
			if not words[i] then
				return nil, "missing filename after " .. w
			end
			if w == "<" then
				r.stdin = words[i]
			else
				r.stdout = words[i]
				r.append = (w == ">>")
			end
		else
			argv[#argv + 1] = w
		end
		i = i + 1
	end
	return argv, r
end

-- ---- the shell object ----

local Sh = {}

Sh.__index = Sh

-- caps: { cons = <handle>, ns = <namespace>, path = "/bin" }
function M.new(caps)
	return setmetatable({
		ns = caps.ns,
		cons = caps.cons,
		env = caps.env or { PATH = caps.path or "/bin", HOME = "/" },
		cwd = "/",
		status = 0,
	}, Sh)
end

function Sh:print(s)
	sys.send(self.cons, { op = "write", data = s })
end

-- find a program by name along PATH, or by path if it has a slash
function Sh:find(name)
	if name:find("/") then
		local p = (name:sub(1, 1) == "/") and name or
		    ns.clean(self.cwd .. "/" .. name)

		return self.ns:stat(p) and p or nil
	end
	for dir in (self.env.PATH or "/bin"):gmatch("[^:]+") do
		for _, cand in ipairs({ dir .. "/" .. name .. ".lua",
		    dir .. "/" .. name }) do
			if self.ns:stat(cand) then
				return cand
			end
		end
	end
	return nil
end

-- ---- builtins ----
--
-- only the ones that CANNOT be programs, because they change the
-- launcher's own state. everything else belongs in /bin, which is the
-- DOS point: cd must be a builtin, ls must not be.
local builtins = {}

builtins["cd"] = function(sh, argv)
	local target = argv[2] or self and "/" or "/"

	target = argv[2] or "/"
	local p = target:sub(1, 1) == "/" and ns.clean(target) or
	    ns.clean(sh.cwd .. "/" .. target)
	local st = sh.ns:stat(p)

	if not st then
		sh:print("cd: " .. p .. ": no such directory\n")
		return 1
	end
	if not st.dir then
		sh:print("cd: " .. p .. ": not a directory\n")
		return 1
	end
	sh.cwd = p
	return 0
end

builtins["pwd"] = function(sh)
	sh:print(sh.cwd .. "\n")
	return 0
end

builtins["exit"] = function(sh, argv)
	sh.done = true
	return tonumber(argv[2]) or 0
end

builtins["set"] = function(sh, argv)
	if not argv[2] then
		local keys = {}

		for k in pairs(sh.env) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			sh:print(k .. "=" .. sh.env[k] .. "\n")
		end
		return 0
	end
	local k, v = argv[2]:match("^([^=]+)=(.*)$")

	if not k then
		sh:print("usage: set NAME=VALUE\n")
		return 1
	end
	sh.env[k] = v
	return 0
end

-- help has to be a builtin for the same reason cd does, not as a
-- convenience: the builtins table lives in the LAUNCHER's proc, and a
-- program is a separate lua_State that cannot see it. so a /bin/help
-- could list programs and would have no way to know `exit` exists.
--
-- and it enumerates rather than reciting. a hardcoded list here would
-- be prose restating code, which is the one thing AGENTS.md says never
-- to write -- it would drift the first time a builtin was added, and
-- silently, because nothing tests a help string.
--
-- programs were always discoverable (they are files -- `ls /bin`), so
-- this exists for the half that was not: the builtins had no listing
-- anywhere, and the only way to learn `exit` was to guess it.
builtins["help"] = function(sh)
	local names = {}

	for name in pairs(builtins) do
		names[#names + 1] = name
	end
	table.sort(names)
	sh:print("builtins: " .. table.concat(names, " ") .. "\n")

	for dir in (sh.env.PATH or "/bin"):gmatch("[^:]+") do
		local ents = sh.ns:readdir(dir)

		if ents then
			local progs = {}

			for _, e in ipairs(ents) do
				if not e.dir then
					-- programs are found as either
					-- name.lua or name (see Sh:find), and
					-- the name is what you type
					progs[#progs + 1] =
					    (e.name:gsub("%.lua$", ""))
				end
			end
			table.sort(progs)
			sh:print(dir .. ": " ..
			    table.concat(progs, " ") .. "\n")
		end
	end
	return 0
end

M.builtins = builtins

-- ---- running one command ----
--
-- spawns the program and hands it the ABI message: argv, env, cwd, the
-- namespace description, and whichever streams it was given. this is
-- posix_spawn with file_actions, delivered as a capability handoff.
function Sh:spawn1(path, argv, streams)
	local pid, h = sys.spawn('require("prog").main()',
	    { name = argv[1] })

	if not pid then
		return nil, "spawn failed"
	end

	local msg = {
		path = path,
		name = argv[1],
		args = argv,
		env = self.env,
		cwd = self.cwd,
		nsdesc = self.ns:describe(),
	}

	for _, k in ipairs({ "stdin", "stdout", "stderr" }) do
		if streams[k] then
			msg[k] = { __right = streams[k] }
		end
	end
	if msg.stdin and streams.stdinpull then
		msg.stdin.pull = true
	end
	sys.send(h, msg)
	sys.close(h)
	return pid
end

-- run a pipeline of one or more commands. returns the last command's
-- status, plus its exit message if it left one.
--
-- MUST be called from inside a thread.run() loop: the pipe and file
-- servers are coroutines, so nothing moves if nothing is driving them.
function Sh:run(line)
	local stages = {}

	for part in (line .. "|"):gmatch("([^|]*)|") do
		stages[#stages + 1] = part
	end

	-- a single builtin runs in-process; a builtin in a pipeline is not
	-- supported and says so rather than silently doing nothing
	if #stages == 1 then
		local words = split(stages[1])

		if #words == 0 then
			return 0
		end
		if builtins[words[1]] then
			return builtins[words[1]](self, words)
		end
	end

	local pids = {}
	local toclose = {}	-- our own rights to drop once handed out
	local servers = {}	-- file servers, which still need stopping
	local prev = nil	-- the pipe the next stage reads from

	for i, part in ipairs(stages) do
		local words = split(part)
		local argv, r = redirs(words)

		if not argv then
			self:print("dos: " .. r .. "\n")
			return 1
		end
		if #argv == 0 then
			self:print("dos: empty command in pipeline\n")
			return 1
		end
		if builtins[argv[1]] then
			self:print("dos: " .. argv[1] ..
			    " is a builtin and cannot be piped\n")
			return 1
		end

		local path = self:find(argv[1])

		if not path then
			-- the hint goes HERE because this is where a lost
			-- user actually is: they typed something that does
			-- not exist, which is the moment they need to be
			-- told where the list lives.
			self:print(argv[1] ..
			    ": not found (try 'help')\n")
			return 127
		end

		local streams = { stderr = self.cons }

		-- stdin: the previous stage's pipe, a redirect, or nothing
		if prev then
			streams.stdin = prev
			prev = nil
		elseif r.stdin then
			local f = self.ns:open(
			    ns.clean(self.cwd .. "/" .. r.stdin), "r")

			if not f then
				self:print("dos: cannot open " .. r.stdin .. "\n")
				return 1
			end
			local rp = sys.newport()

			thread.spawn(M.filereader(f, rp))
			servers[#servers + 1] = rp
			streams.stdin = rp
			streams.stdinpull = true
		end

		-- stdout: a pipe to the next stage, a redirect, or the console
		if i < #stages then
			local pipe = sys.newport()

			streams.stdout = pipe
			prev = pipe
			-- both ends are the same port; we hand a right to the
			-- writer now and to the reader next lap, then drop our
			-- own so the reader can ever see eof
			toclose[#toclose + 1] = pipe
		elseif r.stdout then
			local f = self.ns:create(
			    ns.clean(self.cwd .. "/" .. r.stdout), "w")

			if not f then
				self:print("dos: cannot create " ..
				    r.stdout .. "\n")
				return 1
			end
			local wp = sys.newport()

			thread.spawn(M.filewriter(f, wp))
			servers[#servers + 1] = wp
			streams.stdout = wp
		else
			streams.stdout = self.cons
		end

		local pid, err = self:spawn1(path, argv, streams)

		if not pid then
			self:print("dos: " .. tostring(err) .. "\n")
			return 1
		end
		pids[#pids + 1] = pid
		sys.monitor(pid)
	end

	-- every end is handed out, so drop ours. until this happens the
	-- launcher is still a holder and sys.hungup stays false for the
	-- reader, which would hang the pipeline exactly as the old server
	-- did when its close signal went missing.
	for _, port in ipairs(toclose) do
		sys.close(port)
	end

	local last = pids[#pids]
	local mine = {}

	for _, pid in ipairs(pids) do
		mine[pid] = true
	end

	local left, status, exitmsg = #pids, 0, nil

	while left > 0 do
		local m = thread.recv(sys.SELF)

		-- only OUR stages count. sys.SELF is a general mailbox and may
		-- hold an unrelated monitor notification; counting one of those
		-- made this return early, which meant the {op="close"} below was
		-- never sent, and back when a pipe had a server that meant the
		-- server looped forever and hung thread.run().
		if m and m.exit and mine[m.exit] then
			left = left - 1
			mine[m.exit] = nil
			if m.exit == last then
				if m.normal then
					status = m.status or 0
					exitmsg = m.exitmsg
				else
					status = 1
					exitmsg = m.reason
				end
			end
		end
	end

	-- file servers are still coroutines and still need stopping; pipes
	-- do not, having never had a server.
	for _, port in ipairs(servers) do
		sys.send(port, { op = "stop" })
	end
	return status, exitmsg
end

-- serve an ns File to a program as a readable stream port
-- keeps answering eof after the file runs out: the reader may ask again,
-- and only {op="stop"} means nobody will. files still need this because
-- they are pull-style; pipes do not, having no server at all.
function M.filereader(f, port)
	return function()
		while true do
			local m = thread.recv(port)

			if not m or m.op == "stop" then
				break
			end
			if m.op == "read" then
				local data = f:read(4096)
				local reply = m.reply and m.reply.__right

				if reply then
					sys.send(reply,
					    (data ~= "") and data or nil)
					sys.close(reply)
				end
			end
		end
		f:close()
	end
end

-- serve an ns File to a program as a writable stream port
function M.filewriter(f, port)
	return function()
		while true do
			local m = thread.recv(port)

			if not m or m.op == "stop" then
				break
			end
			if m.op == "write" then
				f:write(m.data)
			end
		end
		f:close()
	end
end

-- ---- the loop ----

-- the launcher is itself a reactor: the repl is a coroutine, and so are
-- the pipe and file servers it spawns, all driven by one thread.run().
-- this is the only correct way to enter it -- calling sh:run() from a
-- bare chunk spawns servers that never get scheduled and hangs.
function M.start(caps, banner)
	local sh = M.new(caps)

	thread.spawn(function()
		sh:repl(banner)
	end)
	thread.run()
	return sh
end

-- run a single line to completion under its own thread.run(), which is
-- what a test or a script wants: same driving requirement as M.start.
function M.once(sh, line)
	local status, msg

	thread.spawn(function()
		status, msg = sh:run(line)
	end)
	thread.run()
	return status, msg
end

function Sh:repl(banner)
	if banner then
		self:print(banner)
	end
	while not self.done do
		local line = thread.readline(self.cons,
		    self.cwd == "/" and "> " or (self.cwd .. "> "))

		if line == nil then
			break
		end
		if #line > 0 then
			local st, msg = self:run(line)

			self.status = st or 0
			if msg then
				self:print("[" .. tostring(msg) .. "]\n")
			end
		end
	end
end

return M
