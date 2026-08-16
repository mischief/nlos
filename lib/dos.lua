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
--
-- Note there is no capability here for mounting. The mount builtin
-- spends what it finds in the namespace -- reading /srv/name yields a
-- right, because srvfs resolves it in this proc. So what decides
-- whether a shell can mount is whether its namespace has /srv, which
-- is inherited like any other mount rather than granted separately.
--
-- coro=true runs programs as coroutines in this proc rather than as
-- procs of their own -- see Sh:pipecoro for what that trades away. off
-- by default, because the default caller is the boot console, where
-- isolation between the shell and whatever it runs is worth a proc.
function M.new(caps)
	return setmetatable({
		ns = caps.ns,
		cons = caps.cons,
		-- the screen, lent to every program this shell spawns (see
		-- Sh:spawn1). a shell given none hands out none, so what
		-- decides whether programs here can draw is one grant, one
		-- level up -- exactly like `cons`.
		fb = caps.fb,
		-- the pointer, on the screen's terms: lent to every program
		-- this shell starts, and a shell given none hands out none.
		-- What spends it is a program that takes the machine whole.
		ptr = caps.ptr,
		-- the machine's keyboard as a device, where the shell was
		-- lent one. What spends it is a program that hands the
		-- panel to a terminal of its own; a session that arrives
		-- over a network is given none, having no panel to give.
		kbd = caps.kbd,
		-- the tcp task, lent on the same terms as the screen: a
		-- shell given none hands out none.
		net = caps.net,
		-- and the udp task, separately: the two soft-fail
		-- independently (see kernel.c's driver table), so a machine
		-- with one and not the other lends what it has.
		udp = caps.udp,
		-- and the resolver, so a program may use a name where it
		-- would otherwise need an address.
		dns = caps.dns,
		-- entropy as data, not authority: one draw per program, so
		-- two of them never start from the same bytes.
		rng = caps.seed and
		    require("crypto.drbg").new(caps.seed) or nil,
		-- the power task, on the same terms again. This one is the
		-- machine itself, so a public session (sshd, webterm) is
		-- given none and its programs cannot reset the machine --
		-- which is a grant a level up, not a check in bin/reboot.lua.
		power = caps.power,
		-- the debug capability, same terms again: it debugs any
		-- proc on the machine, so a public session is given none.
		dbg = caps.dbg,
		-- the bluetooth controller, same terms: raw HCI is the
		-- whole radio, so a session that arrives over a network
		-- gets none.
		hci = caps.hci,
		-- the bluetooth service, which is what a program that is
		-- not a diagnostic should hold: blesrv arbitrates, raw hci
		-- does not.
		ble = caps.ble,
		-- where the exit notices of the programs this shell starts
		-- arrive, and where the console sends the interrupt. A shell
		-- in a proc of its own reads the mailbox, which is the
		-- default; one sharing a proc with a console is given a port,
		-- because the console owns the mailbox and forwards to it.
		notices = caps.notices or sys.SELF,
		coro = caps.coro or false,
		-- TERM says what this system's own terminal renders, which
		-- lib/fbcons.lua bounds: eight colors, bold, reverse and
		-- cursor addressing. A caller with a better one says so by
		-- passing its own env.
		env = caps.env or { PATH = caps.path or "/bin", HOME = "/",
		    TERM = "ansi" },
		cwd = "/",
		status = 0,
	}, Sh)
end

-- a send right to where this shell reads its notices, made once, so the
-- interrupt lands beside the exit notices and one recv waits for either.
function Sh:noticeright()
	if self.notices == sys.SELF then
		return thread.selfright()
	end
	if not self.noticesend then
		self.noticesend = assert(sys.sendright(self.notices),
		    "out of rights")
	end
	return self.noticesend
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
	-- no argument means home, which here is the root
	local target = argv[2] or "/"
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
-- mount and unmount are builtins for the reason cd is one: a program
-- gets a description of the namespace and adopts its own copy, so a
-- mount made in one would vanish with the proc that made it. These have
-- to run in the shell, against the shell's live namespace.
--
-- There is deliberately no `post` builtin, and no longer any need for
-- one: posting is `echo <handle> >/srv/name`, since srvfs's write
-- adopts a right named by number in the writing proc. A prompt still
-- has no way to produce a handle worth posting, but a program does, and
-- it needs nothing but its namespace to do it.
builtins["mount"] = function(sh, argv)
	local name, at = argv[2], argv[3]
	local order = "replace"

	-- plan 9's -b/-a: union the new tree before or after what is
	-- already at the mountpoint, instead of hiding it.
	local rest = {}

	for i = 2, #argv do
		if argv[i] == "-b" then
			order = "before"
		elseif argv[i] == "-a" then
			order = "after"
		else
			rest[#rest + 1] = argv[i]
		end
	end
	name, at = rest[1], rest[2]

	if not name or not at then
		sh:print("usage: mount [-b|-a] service /mountpoint\n")
		return 1
	end

	-- the right comes out of the namespace, not out of a capability
	-- this shell was handed: reading /srv/name yields a handle already
	-- valid here, because srvfs runs in this proc. That is Plan 9's
	-- `mount(open("/srv/x", ORDWR), ...)`, and it means a shell needs
	-- no registry right of its own -- only a namespace with /srv in
	-- it, which is inherited like any other mount.
	local path = name:sub(1, 1) == "/" and name or "/srv/" .. name
	local text, rerr = sh.ns:readfile(ns.clean(path))

	if not text then
		sh:print("mount: " .. path .. ": " .. tostring(rerr) .. "\n")
		return 1
	end

	local right = tonumber((text:gsub("%s+$", "")))

	if not right then
		sh:print("mount: " .. path .. ": not a service\n")
		return 1
	end

	local p = at:sub(1, 1) == "/" and ns.clean(at) or
	    ns.clean(sh.cwd .. "/" .. at)
	local ok, merr = sh.ns:mount(p, require("mnt").new(right), "mnt",
	    { port = { __right = right } }, order)

	if not ok then
		sys.close(right)
		sh:print("mount: " .. p .. ": " .. tostring(merr) .. "\n")
		return 1
	end
	return 0
end

builtins["unmount"] = function(sh, argv)
	if not argv[2] then
		sh:print("usage: unmount /mountpoint\n")
		return 1
	end

	local p = argv[2]:sub(1, 1) == "/" and ns.clean(argv[2]) or
	    ns.clean(sh.cwd .. "/" .. argv[2])
	local ok, err = sh.ns:unmount(p)

	if not ok then
		sh:print("unmount: " .. p .. ": " .. tostring(err) .. "\n")
		return 1
	end
	return 0
end

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
	-- proc.spawn rather than sys.spawn, so the namespace is adopted
	-- before this one line runs. lib/prog.lua is a file like any
	-- other, and on a platform whose image stops at the filesystem it
	-- is on the filesystem -- a raw spawn would search the image, not
	-- find it, and the program would die before its own first line.
	-- The description goes in the ABI message as well: that is what
	-- the program itself is handed, and it may differ from this one.
	local pid, h = require("proc").spawn('require("prog").main()',
	    { name = argv[1], ns = self.ns:describe() })

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

	-- the screen goes to every program, not to a declared few. that is
	-- DOS, which this launcher takes literally: a program got the
	-- machine, video card included, and gave it back by ending. there
	-- is no list of graphical programs to keep in step, and a program
	-- that never asks (prog.screen) is unaffected.
	--
	-- it is still not ambient authority. the shell hands it over
	-- explicitly, in the ABI message, exactly as it hands over stdout;
	-- a shell that was not given a screen has nothing to pass on, and
	-- neither has anything it spawns.
	if self.fb then
		msg.fb = { __right = self.fb }
	end
	if self.ptr then
		msg.ptr = { __right = self.ptr }
	end
	if self.kbd then
		msg.kbd = { __right = self.kbd }
	end
	-- and the terminal, on the same terms as the screen: lent to every
	-- program, used by the few that ask (prog.tty -> a full-screen editor
	-- like vi). the handle is this shell's own console, whatever it is --
	-- cons, an ssh session, a browser -- so a program gets raw keys and
	-- control output over the same terminal the prompt uses.
	if self.cons then
		msg.tty = { __right = self.cons }
	end
	-- and the network, on the same terms again: a right to the tcp
	-- task, used by the few programs that ask (prog.net -> fetch). A
	-- shell that was not given one hands on nothing, so a machine with
	-- no stack is a machine whose programs cannot reach a network
	-- rather than one that fails oddly when they try.
	if self.net then
		msg.net = { __right = self.net }
	end
	-- udp, for the programs that ask a server one question and read one
	-- answer (prog.udp -> host, date).
	if self.udp then
		msg.udp = { __right = self.udp }
	end
	-- the resolver (prog.dns -> fetch, host).
	if self.dns then
		msg.dns = { __right = self.dns }
	end
	if self.rng then
		msg.seed = self.rng.bytes(32)
	end
	-- and the power task, for bin/reboot.lua. Every program gets it
	-- where the shell has it, like the screen and the network: the
	-- authority is the grant, and a program that never asks
	-- (prog.power) is unaffected.
	if self.power then
		msg.power = { __right = self.power }
	end
	-- and the debug capability, for bin/dbg.lua. Same rule: the grant
	-- is the authority, and a program that never asks is unaffected.
	if self.dbg then
		msg.dbg = { __right = self.dbg }
	end
	-- and the bluetooth controller, for bin/hcitool.lua and the host
	-- stack above it. Same rule again.
	if self.hci then
		msg.hci = { __right = self.hci }
	end
	if self.ble then
		msg.ble = { __right = self.ble }
	end
	-- the pull flag rides BESIDE stdin, not inside it. a table carrying
	-- __right is serialized as the right and nothing else (see
	-- kernel.c's serialize), so every sibling field is silently
	-- dropped -- which is what happened to `stdin.pull` for as long as
	-- it was written that way: `cat < file` handed the program a pull
	-- server and told it, by omission, to drain a pipe, and it read a
	-- send right as a receive one.
	if msg.stdin and streams.stdinpull then
		msg.stdinpull = true
	end
	sys.send(h, msg)

	-- the handle stays open, and is the second return: it is the only
	-- right to the child's own port, so it is also the only thing that
	-- makes sys.kill legal. Closed by the caller once the child's exit
	-- notice has arrived -- an interrupt that could not kill what it
	-- interrupted is what closing it here bought.
	return pid, h
end

-- parse one pipeline stage: argv, its redirections, and the program it
-- names. shared by both launch paths below, which agree on every part of
-- this and on none of what follows it.
--
-- returns nil plus a message (and optionally a status) on failure.
function Sh:stage(part)
	local words = split(part)
	local argv, r = redirs(words)

	if not argv then
		return nil, "dos: " .. r
	end
	if #argv == 0 then
		return nil, "dos: empty command in pipeline"
	end
	if builtins[argv[1]] then
		return nil, "dos: " .. argv[1] ..
		    " is a builtin and cannot be piped"
	end
	local path = self:find(argv[1])

	if not path then
		-- the hint goes HERE because this is where a lost user
		-- actually is: they typed something that does not exist,
		-- which is the moment they need to be told where the list
		-- lives.
		return nil, argv[1] .. ": not found (try 'help')", 127
	end
	return { argv = argv, r = r, path = path }
end

-- ---- the coroutine launcher ----
--
-- the same pipeline, with every stage a coroutine in THIS proc instead
-- of a proc of its own: prog.corun rather than sys.spawn, Channels
-- rather than ports, and the programs themselves unchanged, because
-- prog.chanstream satisfies the same :read/:write/:close that a port
-- stream does.
--
-- what it costs and buys, against Sh:pipeports below:
--
--   - a stage is a coroutine and a table, not a ~34-40KB lua_State, so
--     MAXPROCS stops bounding pipeline depth. that is the whole reason
--     lib/webterm.lua wants this: a visitor's session becomes one proc
--     rather than one plus one per command.
--   - no isolation between stages, or between a stage and this shell.
--     they share a heap, an instruction budget and a memory cap, so a
--     runaway program takes the session down instead of just itself.
--     acceptable where the session is already one user's, and NOT
--     acceptable for the boot console, which is why this is a flag and
--     not a replacement.
--   - file redirects need no server coroutine: prog.filestream talks to
--     an ns File directly, where the port path has to put M.filereader
--     or M.filewriter behind a port to make a pull-style stream.
--
-- a namespace is deliberately NOT passed per stage. ns.setcurrent is
-- per-proc state, so every coroutine here shares this shell's namespace
-- -- see prog.corun.
function Sh:pipecoro(stages)
	local prog = require("prog")
	-- the console is another proc either way, so it stays a port
	-- stream. never closed: it is not ours, and every stage shares it.
	local cons = prog.pipestream(self.cons)
	local done = thread.chancreate(#stages)
	local status = {}
	local closers = {}
	local prev = nil

	for i, part in ipairs(stages) do
		local st, msg, code = self:stage(part)

		if not st then
			self:print(msg .. "\n")
			return code or 1
		end

		local stdin, stdout = nil, cons

		if prev then
			stdin = prog.chanstream(prev)
			prev = nil
		elseif st.r.stdin then
			local f = self.ns:open(
			    ns.clean(self.cwd .. "/" .. st.r.stdin), "r")

			if not f then
				self:print("dos: cannot open " ..
				    st.r.stdin .. "\n")
				return 1
			end
			stdin = prog.filestream(f)
			closers[#closers + 1] = stdin
		end

		-- the channel this stage WRITES, if any. it has to be closed
		-- the moment this stage returns rather than after the join:
		-- close() is the only eof a channel has, and the next stage
		-- is blocked reading until it arrives.
		local mine = nil

		if i < #stages then
			mine = thread.chancreate(2)	-- bounded: backpressure
			stdout = prog.chanstream(mine)
			prev = mine
		elseif st.r.stdout then
			local f = self.ns:create(
			    ns.clean(self.cwd .. "/" .. st.r.stdout), "w")

			if not f then
				self:print("dos: cannot create " ..
				    st.r.stdout .. "\n")
				return 1
			end
			stdout = prog.filestream(f)
			closers[#closers + 1] = stdout
		end

		local idx = i
		local spec = {
			path = st.path, name = st.argv[1], args = st.argv,
			env = self.env, cwd = self.cwd, ns = self.ns,
			stdin = stdin, stdout = stdout, stderr = cons,
			-- the console handle itself, so a full-screen program run
			-- in a coro session (ssh, webterm) reaches the raw terminal
			-- the same way a spawned one does. bare handle, not
			-- {__right=}: corun takes objects, not wire rights.
			tty = self.cons,
			-- likewise udp, as a bare handle: a coro stage
			-- reaches the same tasks a spawned one does.
			udp = self.udp,
			dns = self.dns,
			seed = self.rng and self.rng.bytes(32) or nil,
		}

		thread.spawn(function()
			-- a stage that raises must not take the shell with
			-- it, nor leave the join waiting forever. prog.run
			-- pcalls the program itself, so this catches only a
			-- failure of the runtime around it.
			local ok, res = pcall(prog.corun, spec)

			status[idx] = ok and res or 1
			if not ok then
				cons:write("dos: " .. st.argv[1] .. ": " ..
				    tostring(res) .. "\n")
			end
			if mine then
				mine:close()
			end
			done:send(idx)
		end)
	end

	-- join. a Channel rather than thread.run(), because Sh:run is
	-- ALREADY inside a thread.run() loop -- see the note on Sh:run --
	-- so what is needed here is to park until the stages report, not
	-- to start a second scheduler.
	for _ = 1, #stages do
		done:recv()
	end
	for _, c in ipairs(closers) do
		c:close()
	end
	return status[#stages] or 0
end

-- run a pipeline of one or more commands. returns the last command's
-- status, plus its exit message if it left one.
--
-- MUST be called from inside a thread.run() loop: the pipe and file
-- servers are coroutines, so nothing moves if nothing is driving them.
function Sh:run(line)
	local stages = {}

	-- a lone ! is a pipe as well.
	--
	-- The T-Deck's keyboard cannot type |: its symbol layer is
	-- # * @ / ( ) ? _ : ! , ; + " - . \ and the digits, and that is
	-- all there is. Without a second spelling, a pipeline cannot be
	-- entered at the panel at all.
	--
	-- It must stand alone, with space on both sides. The split below
	-- does not know about quoting, so a ! taken anywhere it appears
	-- would cut `echo "hi!"` in half -- and unlike |, ! is a
	-- character people write in ordinary text.
	line = line:gsub("%s+!%s+", "|")

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

	-- builtins are decided above, because they are this shell's own
	-- state either way. everything below is how a PROGRAM is launched,
	-- which is the one thing the two modes disagree about.
	if self.coro then
		return self:pipecoro(stages)
	end

	local pids = {}
	-- pid -> the right to that child's own port, which is what makes
	-- sys.kill legal. Held until its exit notice arrives.
	local ctl = {}
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

		-- stdin: the previous stage's pipe, a redirect, or the
		-- console -- which is what makes an interactive program
		-- possible at all. it used to be nothing, so a program
		-- reading fd 0 at the prompt got an immediate eof and no
		-- program could ever wait for a keypress. the console
		-- answers the ABI's read op (see lib/cons.lua) precisely so
		-- it can stand in for a pipe here.
		--
		-- pull, not pipe: a terminal produces on demand and has to
		-- be ASKED, where a pipe is drained off the port queue. that
		-- distinction is the whole reason the ABI carries a flag.
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
			local rp = sys.newport("dos.rp")

			thread.spawn(M.filereader(f, rp))
			servers[#servers + 1] = rp
			streams.stdin = rp
			streams.stdinpull = true
		else
			streams.stdin = self.cons
			streams.stdinpull = true
		end

		-- stdout: a pipe to the next stage, a redirect, or the console
		if i < #stages then
			local pipe = sys.newport("dos.pipe")

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
			local wp = sys.newport("dos.wp")

			thread.spawn(M.filewriter(f, wp))
			servers[#servers + 1] = wp
			streams.stdout = wp
		else
			streams.stdout = self.cons
		end

		local pid, h = self:spawn1(path, argv, streams)

		if not pid then
			self:print("dos: " .. tostring(h) .. "\n")
			return 1
		end
		pids[#pids + 1] = pid
		ctl[pid] = h
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

	-- what we killed deliberately, so its corpse can be dropped. A
	-- proc that dies badly is held for inspection, which is right for
	-- a crash and wrong for an interrupt: the person who typed it
	-- knows why it stopped, and a corpse holds the program's whole
	-- working set until something reaps it.
	local interrupted = {}

	-- claim the interrupt character while these run. The console
	-- watches the keyboard even when nothing is reading it, which is
	-- the only way a program that has stopped reading can still be
	-- stopped -- and that is the program you want to interrupt.
	if self.cons then
		sys.send(self.cons, { op = "intr",
		    reply = { __right = self:noticeright() } })
	end

	while left > 0 do
		local m = thread.recv(self.notices)

		-- kill every stage, not the last: a pipeline is one thing
		-- to the person who typed it, and leaving the writers alive
		-- to fill a pipe nobody drains is not stopping anything.
		if type(m) == "table" and m.op == "interrupt" then
			for pid in pairs(mine) do
				pcall(sys.kill, pid)
				interrupted[pid] = true
			end
		end

		-- only OUR stages count. The notice port is a general mailbox
		-- and may hold an unrelated monitor notification; counting one
		-- made this return early, which meant the {op="close"} below was
		-- never sent, and back when a pipe had a server that meant the
		-- server looped forever and hung thread.run().
		if m and m.exit and mine[m.exit] then
			left = left - 1
			mine[m.exit] = nil
			if interrupted[m.exit] then
				pcall(sys.reap, m.exit)
			end
			-- after the reap, which needs the same right
			if ctl[m.exit] then
				sys.close(ctl[m.exit])
				ctl[m.exit] = nil
			end
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

	-- given back: with nothing running, the interrupt character has
	-- nothing to mean, and a console still holding this would send
	-- the shell a message it no longer expects.
	if self.cons then
		sys.send(self.cons, { op = "intr" })
	end

	-- file servers are still coroutines and still need stopping; pipes
	-- do not, having never had a server.
	for _, port in ipairs(servers) do
		sys.send(port, { op = "stop" })
	end

	-- anything the loop above did not see an exit for, so a shell that
	-- returns early does not keep a right to a dead child forever.
	for pid, h in pairs(ctl) do
		sys.close(h)
		ctl[pid] = nil
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
