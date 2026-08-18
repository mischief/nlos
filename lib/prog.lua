-- prog: the program ABI, and the runtime that installs it.
--
-- a program here is a lua chunk in the namespace. it is started by
-- sys.spawn and its first message IS its argv/envp/fds:
--
--   {
--     args   = { "seq", "1", "5" },
--     env    = { PATH = "/bin", HOME = "/" },
--     cwd    = "/",
--     nsdesc = <ns:describe(), so the namespace is inherited>,
--     stdin  = { __right = h } | nil,
--     stdinpull = <bool>,
--     stdout = { __right = h } | nil,
--     stderr = { __right = h } | nil,
--   }
--
-- stdinpull sits BESIDE stdin rather than inside it, and must: a table
-- carrying __right is serialized as that right and nothing else, so any
-- sibling field in it is dropped in transit. it was written as
-- stdin.pull once and silently never arrived.
--
-- WRITING is the same whatever is on the other end -- cons, a pipe and a
-- file server all take {op="write", data=} -- so stdout/stderr need no
-- shape flag. READING differs: a pipe is drained straight off the port
-- queue, while cons and a file redirect must be ASKED
-- ({op="read", reply=}) because they produce on demand. hence pull.
--
-- that is main(argc, argv, envp) plus fds 0/1/2, delivered as a
-- capability handoff rather than inherited numbers -- exact rather than
-- approximate, because rights only travel in messages anyway. the
-- launcher decides what each program is handed, so a program that was
-- not given a capability has no path to it (see AGENTS.md on why
-- los.platform.* is registered per-owner rather than gated by a check).
--
-- ---- why this shim looks like luaposix ----
--
-- it is NOT an emulation of luaposix. it is the handful of calls that
-- real utilities turn out to use, under the same names, so a ported
-- program needs no diff at all. seq.lua wants exactly `arg`,
-- unistd.write and os.exit; cat.lua adds unistd.read, unistd.close and
-- fcntl.open. that is the whole surface, and implementing it beats
-- reimplementing a library.
--
-- numeric fds are the one concession: `unistd.write(1, s)` and
-- `fcntl.open(path) -> fd` are the idiom, so there is a per-program fd
-- table. it is not the kernel's -- it is a lua table in this proc,
-- mapping small integers to stream objects, and nothing outside the
-- program can see or name it.

local sys = require("los.sys")
-- los.thread is required where it is used, not here: see
-- docs/scheduling.md on what a program pays for it.
local ns = require("ns")

local M = {}

-- ---- streams ----
--
-- One shape (:read/:write/:close) over three things: a port, an in-proc
-- channel, and an ns Chan. That is what lets a program write the same
-- way to a terminal, a pipe or a file without learning which it has.

-- lib/stream/ holds them, required inside these rather than at the top:
-- a proc with no fds loads none of the three.

function M.pipestream(h, own)
	return require("stream.port").new(h, own)
end

function M.portstream(h, own)
	return require("stream.port").pull(h, own)
end

function M.chanstream(c)
	return require("stream.pipe").new(c)
end

function M.filestream(f)
	return require("stream.chan").new(f)
end

-- ---- the fd table ----

-- ---- the namespace, rooted where the program is ----
--
-- A namespace resolves absolute paths and nothing else, so a relative
-- argument has to be joined to the program's cwd before it goes in.
-- Leaving that to every caller is a rule that gets forgotten: `rm
-- wifi.lua` from /etc looked for /wifi.lua and reported that a file
-- plainly there did not exist. So the joining happens once, on the
-- handle prog.ns() hands over, and a program cannot skip it.
--
-- Idempotent, so a caller that already resolved is unaffected: abspath
-- of an absolute path is that path cleaned.
--
-- Every other method is forwarded with the real namespace as self,
-- cached on first use so a call costs a table lookup rather than a
-- closure.
-- Built on demand and one method at a time: a program that only calls
-- remove pays for one closure, not for the whole interface. The set is
-- one table for the proc however many programs run in it.
local PATHOP = {
	walk = true, open = true, create = true, stat = true,
	readdir = true, readfile = true, writefile = true, remove = true,
	lookup = true, mountpoints = true, mount = true, unmount = true,
}

local function rootedns(ctx)
	local N = ctx.ns

	if N == nil or ctx.rootedns then
		return N and ctx.rootedns
	end
	ctx.rootedns = setmetatable({}, {
		__index = function(t, k)
			local v = N[k]

			if type(v) ~= "function" then
				return v
			end

			local f

			if PATHOP[k] then
				f = function(_, p, ...)
					return v(N, M.abspath(ctx, p), ...)
				end
			else
				f = function(_, ...)
					return v(N, ...)
				end
			end
			rawset(t, k, f)
			return f
		end,
	})
	return ctx.rootedns
end

local function newfds(ctx)
	local fds = {}

	-- 0/1/2 come from the first message. a missing one is a stream that
	-- reads eof and swallows writes, so a program handed no stdout does
	-- not crash -- it just has nowhere to go, like >/dev/null.
	local null = {
		write = function(_, d) return #d end,
		read = function() return "" end,
		close = function() end,
	}

	fds[0] = ctx.stdin or null
	fds[1] = ctx.stdout or null
	fds[2] = ctx.stderr or ctx.stdout or null

	function fds.alloc(stream)
		local n = 3

		while fds[n] do
			n = n + 1
		end
		fds[n] = stream
		return n
	end

	return fds
end

-- ---- the environment a program sees ----
--
-- everything below goes into a table that becomes the program's _ENV,
-- NOT into _G. it used to be _G, which was correct for exactly one
-- program per proc and silently wrong for any other arrangement: two
-- programs in one lua_State would share `arg`, so the second to start
-- would rewrite the first's argv mid-run.
--
-- that is not hypothetical, it is the pipeline case -- `a | b` runs
-- both at once -- and it is the blocker for running a pipeline as
-- coroutines in one proc instead of a proc per stage.
--
-- `__index = _G` means a program still sees string, table, math and the
-- rest unchanged. it reads through; only what install() defines is its
-- own. no program needed a single change for this.
--
-- the posix sliver moves out of package.preload for the same reason,
-- and it is the less obvious half: those closures capture fds and ctx,
-- and package.loaded is per-PROC, so the second program to
-- require("posix.unistd") would have got the first one's file
-- descriptors. so the program's _ENV carries its own require, which
-- answers for the sliver and delegates everything else.

-- End the proc, where this program is the proc. Unwinding ends the
-- coroutine it is called from, so a program that spawned threads leaves
-- them parked and the proc alive; sys.exit says the whole proc is done.
-- A coroutine stage must never: the proc belongs to its launcher.
local function exitproc(ctx)
	if ctx.ownproc and sys.exit then
		sys.exit(ctx.status or 0)
	end
end


-- ---- os, built on use ----
--
-- os is excluded from our stdlib entirely (see src/linit.c), so what a
-- program gets is only this. The builders are shared, so what a program
-- pays for is the one function it calls. time, date, difftime, clock
-- and setlocale want no ctx and belong in C beside the rest.
local osbuild = {}

osbuild.exit = function(ctx)
	return function(code)
		-- record the status, then unwind: see sys.setexit on why
		-- the kernel does not raise. ctx.setexit rather than
		-- sys.setexit, because a program running as a coroutine
		-- must not set the PROC's status -- that belongs to the
		-- launcher hosting it.
		ctx.setexit(tonumber(code) or 0)
		exitproc(ctx)
		error(M.EXIT, 0)
	end
end

osbuild.getenv = function(ctx)
	return function(k)
		return (ctx.env or {})[k]
	end
end

-- the machine's wall clock, nil until something has set it. A program
-- that only wants an interval wants os.clock, which is always there.
osbuild.time = function()
	return function(t)
		if type(t) == "table" then
			return require("time").unix(t)
		end
		return sys.time()
	end
end

osbuild.date = function()
	return function(fmt, when)
		when = when or sys.time()
		if not when then
			return nil
		end
		return require("time").date(fmt, when)
	end
end

osbuild.difftime = function()
	return function(a, b)
		return (a or 0) - (b or 0)
	end
end

-- seconds since boot, monotonic: this is the one a timing loop wants,
-- and it does not need the clock to have been set.
osbuild.clock = function()
	return function()
		return sys.uptime_ms() / 1000
	end
end

-- the namespace at call time, not at start: a program may have mounted
-- something since. nil and a reason on failure, which is what a caller
-- tests and what lua's own os.remove answers.
osbuild.remove = function()
	return function(name)
		local N = ns.current()

		if not N then
			return nil, tostring(name) .. ": no namespace"
		end

		local ok, err = N:remove(name)

		if not ok then
			return nil, tostring(name) .. ": " ..
			    tostring(err or "cannot remove")
		end
		return true
	end
end

-- nil plus a message, as os.rename does everywhere. Crossing a mount
-- fails here exactly as it fails on unix, and for the same reason: see
-- NS:rename. bin/mv.lua is what copies instead.
osbuild.rename = function()
	return function(from, to)
		local N = ns.current()

		if not N then
			return nil, tostring(from) .. ": no namespace"
		end

		local ok, err = N:rename(from, to)

		if not ok then
			return nil, ("%s -> %s: %s"):format(tostring(from),
			    tostring(to), tostring(err or "cannot rename"))
		end
		return true
	end
end

-- one locale, and it is C. nil for any other is what a caller checks
-- before it formats anything.
osbuild.setlocale = function()
	return function(name)
		if name == nil or name == "" or name == "C" then
			return "C"
		end
		return nil
	end
end

-- what is absent says why. "attempt to call a nil value" names the
-- line that used it and not the reason it is not there.
local noos = {
	execute = "no shell to run one; see prog.spawn",
	tmpname = "this machine has no /tmp",
}

local function install(ctx)
	local fds = newfds(ctx)
	local G = setmetatable({}, { __index = _G })

	-- lua's own convention, which is what the utilities are written
	-- against: arg[0] is the program name and arg[1] the FIRST REAL
	-- argument, so #arg counts arguments rather than argv entries. the
	-- ABI message carries argv with the name at [1] (that is what a
	-- shell has), so it gets shifted here exactly once.
	--
	-- getting this wrong is silent and total: seq saw #arg == 2 for
	-- `seq 5` and took its two-argument branch, and cat tried to open a
	-- file called "cat".
	local argv = ctx.args or {}

	G.arg = {}
	G.arg[0] = argv[1] or ctx.name
	for i = 2, #argv do
		G.arg[i - 1] = argv[i]
	end

	-- os is excluded from our stdlib entirely (see src/linit.c), so
	-- this is not an override -- it is the only os a program has.
	--
	-- Built on use. Most programs touch os.exit and nothing else, and
	-- a table of eight closures per program is seven it never calls;
	-- what is per program here is one table and one __index.
	G.os = setmetatable({}, {
		__index = function(t, k)
			local build = osbuild[k]

			if not build then
				error("os." .. tostring(k) .. ": " ..
				    (noos[k] or "no such thing here"), 2)
			end

			local f = build(ctx)

			rawset(t, k, f)
			return f
		end,
	})

	-- plan 9's exits(msg): nil is success, any string is failure WITH a
	-- reason, which beats a number nobody has a table for. sys.setexit
	-- takes either, so both idioms are first class -- ported utilities
	-- keep calling os.exit(1) and native ones can say why.
	G.exits = function(msg)
		ctx.setexit(msg)
		error(M.EXIT, 0)
	end

	-- lua's io, over the ABI's streams rather than the raw console: a
	-- program in a pipeline whose io.write went to the terminal would
	-- bypass the pipe. Built on use, like os above -- a program that
	-- writes a line does not pay for the file half.
	local std = {}

	-- One handle shape for all three, and for a file, so io.type
	-- answers "file" for any of them as lua's does. nsio is loaded by
	-- the namespace anyway -- ns.adopt installs it -- so a lighter
	-- object for stdout would save nothing.
	local function out(fd, name)
		if not std[fd] then
			std[fd] = require("nsio").stream(fds[fd], name)
		end
		return std[fd]
	end

	local function stdin()
		return out(0, "stdin")
	end

	G.io = setmetatable({}, {
		__index = function(t, k)
			local v

			if k == "stdin" then
				v = stdin()
			elseif k == "stdout" then
				v = out(1, "stdout")
			elseif k == "stderr" then
				v = out(2, "stderr")
			elseif k == "write" then
				v = function(...)
					return t.output():write(...)
				end
			elseif k == "read" then
				v = function(...)
					return t.input():read(...)
				end
			elseif k == "input" then
				v = function(f)
					if f then
						t.__in = type(f) == "string" and
						    assert(require("nsio").open(f,
						    "r", rootedns(ctx))) or f
					end
					t.__in = t.__in or stdin()
					return t.__in
				end
			elseif k == "output" then
				v = function(f)
					if f then
						t.__out = type(f) == "string" and
						    assert(require("nsio").open(f,
						    "w", rootedns(ctx))) or f
					end
					t.__out = t.__out or out(1, "stdout")
					return t.__out
				end
			elseif k == "lines" then
				v = function(path, ...)
					if not path then
						return t.input():lines(...)
					end
					if not ctx.ns then
						error("no namespace", 2)
					end
					return require("nsio").lines(path,
					    ..., rootedns(ctx))
				end
			elseif k == "close" then
				v = function(f)
					return (f or t.output()):close()
				end
			elseif k == "flush" then
				v = function()
					return t.output():flush()
				end
			elseif k == "open" then
				-- absent rather than failing, and only over a
				-- namespace: proc_new nils the file half for
				-- every proc but boot, and having somewhere
				-- to point it is what puts it back. A visitor
				-- given none probes and finds nothing.
				if not ctx.ns then
					return nil
				end
				v = function(path, mode)
					return require("nsio").open(path,
					    mode, rootedns(ctx))
				end
			elseif k == "type" then
				v = function(...)
					return require("nsio").type(...)
				end
			elseif k == "popen" then
				-- a proc, and so needs a namespace to find
				-- the command in, exactly as open does.
				if not ctx.ns then
					return nil
				end
				v = function(cmd, mode)
					return M.popen(ctx, cmd, mode)
				end
			elseif k == "tmpfile" then
				v = function()
					return nil, "this machine has no /tmp"
				end
			else
				return nil
			end
			rawset(t, k, v)
			return v
		end,
	})
	-- print goes to stdout like everything else
	G.print = function(...)
		local parts = {}

		for i, v in ipairs({ ... }) do
			parts[i] = tostring(v)
		end
		fds[1]:write(table.concat(parts, "\t") .. "\n")
	end

	local N = ctx.ns

	-- the per-program module table. lazy, and cached after first use,
	-- so require() semantics are unchanged from the package.preload
	-- version it replaces -- only the SCOPE differs.
	local mods, cache = {}, {}

	mods["posix.unistd"] = function()
		return {
			write = function(fd, s)
				local st = fds[fd]

				if not st then
					return nil, "bad file descriptor"
				end
				return st:write(s)
			end,
			read = function(fd, n)
				local st = fds[fd]

				if not st then
					return nil, "bad file descriptor"
				end
				return st:read(n)
			end,
			close = function(fd)
				local st = fds[fd]

				if st then
					st:close()
					fds[fd] = nil
				end
				return 0
			end,
		}
	end

	-- posix.dirent.dir maps cleanly onto ns:readdir, so it joins the
	-- sliver. note where the sliver STOPS: ls also wants posix.pwd,
	-- posix.grp, getopt and isatty -- users, groups and terminals this
	-- system does not have -- so ls is the first utility better
	-- rewritten than ported. see bin/ls.lua.
	mods["posix.dirent"] = function()
		return {
			dir = function(path)
				local ents, err =
				    N:readdir(M.abspath(ctx, path or "."))

				if not ents then
					return nil, err
				end
				local names = { ".", ".." }

				for _, e in ipairs(ents) do
					names[#names + 1] = e.name
				end
				return names
			end,
		}
	end

	mods["posix.fcntl"] = function()
		return {
			-- the flags utilities actually pass. they are opaque
			-- tokens as far as anything here cares.
			O_RDONLY = "r",
			O_WRONLY = "w",
			O_RDWR = "rw",
			O_CREAT = "w",
			open = function(path, mode)
				local f, err = N:open(M.abspath(ctx, path),
				    mode == "w" and "w" or
				    mode == "rw" and "rw" or "r")

				if not f then
					return nil, err
				end
				return fds.alloc(M.filestream(f))
			end,
		}
	end

	-- require("prog") inside a program gets a view scoped to THAT
	-- program, so prog.ns()/prog.cwd() answer for the caller rather
	-- than for whichever program last started in this proc. __index
	-- falls through to the module proper, so abspath, filestream and
	-- EXIT are all still there.
	mods["prog"] = function()
		return setmetatable({
			ns = function() return rootedns(ctx) end,
			cwd = function() return ctx.cwd or "/" end,
			ctx = ctx,
		}, { __index = M })
	end

	-- `require` is NOT localised above this: ns.setcurrent replaces the
	-- global with a namespace-routed implementation, and capturing an
	-- upvalue here would pin whichever one happened to exist when the
	-- program started.
	G.require = function(name)
		local build = mods[name]

		if not build then
			return require(name)
		end
		if cache[name] == nil then
			cache[name] = build()
		end
		return cache[name]
	end

	return fds, G
end

-- resolve a program-supplied path against its cwd, so a relative path
-- means what the program expects
-- ---- io.popen ----
--
-- One command, run as a PROC. A proc because both ends of a pipe
-- cannot live in one of them: sys.hungup asks whether anyone ELSE
-- holds the port, so a reader whose writer is a thread beside it is
-- told the pipe is finished. See test/boot/test_selfpipe.lua.

-- No pipeline, no redirection: those are the shell's, and running a
-- shell here would put the writer back inside this proc. Refused by
-- name rather than parsed and ignored.
local SHELLISH = "[|<>&;]"

-- lua's own splitting, quotes included, so `io.popen('cat "a b"')`
-- means what it means at a prompt. Not dos.split: requiring the shell
-- for one function would load all of it.
local function argvof(line)
	local words, cur, inq = {}, nil, nil

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

-- the shell's own rule (dos's Sh:find), so a name means the same thing
-- from a program as it does at a prompt: a slash is a path, otherwise
-- PATH, and ".lua" is tried before the bare name.
local function findprog(ctx, name)
	local N = ctx.ns

	if name:find("/") then
		local p = M.abspath(ctx, name)

		return N:stat(p) and p or nil
	end
	for dir in (ctx.env and ctx.env.PATH or "/bin"):gmatch("[^:]+") do
		for _, cand in ipairs({ dir .. "/" .. name .. ".lua",
		    dir .. "/" .. name }) do
			if N:stat(cand) then
				return cand
			end
		end
	end
	return nil
end

function M.popen(ctx, cmd, mode)
	mode = tostring(mode or "r"):gsub("b", "")
	if mode ~= "r" then
		return nil, "io.popen: only 'r' is supported"
	end
	if type(cmd) ~= "string" then
		return nil, "io.popen: a command is a string"
	end
	if cmd:find(SHELLISH) then
		return nil, "io.popen: no pipeline or redirection here"
	end

	local argv = argvof(cmd)

	if #argv == 0 then
		return nil, "io.popen: no command"
	end

	local path = findprog(ctx, argv[1])

	if not path then
		return nil, argv[1] .. ": not found"
	end

	local thread = require("los.thread")
	local port = sys.newport("popen")
	-- described once: proc.spawn adopts it before the child's first
	-- line runs, and the ABI message carries the same thing.
	local desc = ctx.ns:describe()
	local pid, h = require("proc").spawn('require("prog").main()',
	    { name = argv[1], ns = desc })

	if not pid then
		sys.close(port)
		return nil, "io.popen: spawn failed"
	end
	sys.monitor(pid)
	sys.send(h, {
		path = path,
		name = argv[1],
		args = argv,
		env = ctx.env,
		cwd = ctx.cwd,
		nsdesc = desc,
		-- the write end is the CHILD's, which is what makes the
		-- hangup mean end-of-output rather than nothing at all.
		stdout = { __right = port },
	})
	sys.close(h)

	local f = require("nsio").stream(M.pipestream(port, true), "popen")
	local status = nil

	-- lua's close on a popen handle answers the COMMAND's status. The
	-- pipe ends when the child drops its right, so eof comes first and
	-- the notice after.
	f.close = function(self)
		while self:read(4096) ~= nil do
		end
		while status == nil do
			local m = thread.recv(sys.SELF)

			if type(m) == "table" and m.exit == pid then
				status = m.normal and (m.status or 0) or 1
			end
		end
		getmetatable(self).close(self)
		if status == 0 then
			return true, "exit", 0
		end
		return nil, "exit", status
	end
	return f
end

function M.abspath(ctx, path)
	path = tostring(path)
	if path:sub(1, 1) == "/" then
		return ns.clean(path)
	end
	return ns.clean((ctx.cwd or "/") .. "/" .. path)
end

-- a program's own context, for programs written FOR this system rather
-- than ported to it: prog.ns() is the namespace it was given, prog.cwd()
-- where it started. deliberately separate from the posix.* sliver, which
-- exists to make foreign code run unchanged -- this is the native API,
-- and mixing the two would blur which is which.
function M.ns()
	return M.ctx and M.ctx.ns
end

function M.cwd()
	return (M.ctx and M.ctx.cwd) or "/"
end

-- the sentinel os.exit raises. a program's own pcall can swallow it,
-- which differs from a real exit() -- documented rather than worked
-- around, because the alternative is the kernel raising, and then ANY
-- pcall anywhere could swallow it just the same.
M.EXIT = "\1prog.exit"

-- ---- the entry point ----
--
-- a spawned program's whole body is `require("prog").main()`. this reads
-- the ABI message, builds the environment, then loads and runs the real
-- chunk. that keeps every program a plain lua file with no preamble.
-- ---- run: everything that does not care how the program was started --
--
-- ctx must arrive complete:
--   path/name/args/env/cwd  as the ABI describes them
--   ns                      a LIVE namespace, not a description
--   stdin/stdout/stderr     stream objects, or nil
--   setexit(v)              how this program reports its status
--
-- the split is what lets one program run either as a whole proc
-- (M.main) or as a coroutine beside its pipeline neighbours (M.corun).
-- everything mode-specific is above this line -- where the streams come
-- from, where the namespace comes from, where a status goes -- and a
-- program cannot tell the difference, which is the point.
--
-- returns the status, so a coroutine host has something to collect.
function M.run(ctx)
	local who = ctx.name or "?"
	local fds, env = install(ctx)

	-- M.screen() reads this. set here rather than only in M.main so
	-- the coroutine path (M.corun) reaches a screen too -- with the
	-- caveat coro mode already carries everywhere else: coroutines
	-- share one proc, so they share this, and the last one to start
	-- wins. that is the same trade M.corun's own comment describes
	-- for the namespace, and it is why coro is off by default.
	M.ctx = ctx
	local src, serr = ctx.ns:readfile(ctx.path)

	if not src then
		fds[2]:write(who .. ": " .. tostring(serr) .. "\n")
		ctx.setexit(127)
		return 127
	end

	-- "t" is text-only: a program comes out of the namespace, and
	-- loading precompiled bytecode from there would hand the lua vm
	-- unverified input, which is a memory-safety hole rather than a
	-- feature anything here wants.
	local chunk, lerr = load(src, "=" .. who, "t", env)

	if not chunk then
		fds[2]:write(who .. ": " .. tostring(lerr) .. "\n")
		ctx.setexit(126)
		return 126
	end

	local ok, err = pcall(chunk)

	if not ok and err ~= M.EXIT then
		fds[2]:write(who .. ": " .. tostring(err) .. "\n")
		ctx.setexit(1)
		return 1
	end
	-- flush nothing: writes are messages and already sent
	return ctx.status or 0
end

-- ctx.status is always recorded; the sink is what differs. proc mode
-- adds sys.setexit so the kernel reports it to a monitor, and coroutine
-- mode has no sink at all -- the status belongs to the program, not to
-- the proc hosting it, and its host reads it from M.run's return.
local function setexit(ctx, sink)
	return function(v)
		ctx.status = v
		if sink then
			sink(v)
		end
	end
end

-- a spawned program's whole body is `require("prog").main()`: read the
-- ABI message, turn rights into streams and a description into a
-- namespace, then run.
function M.main()
	-- sys.alt, not thread.recv: every program does this one receive,
	-- and it must not be what loads the thread module.
	local _, ctx = sys.alt({ sys.SELF })

	-- stdinpull is a TOP-LEVEL field, not one inside stdin: a table
	-- carrying __right serializes to the right alone and drops its
	-- siblings, so a flag written inside it never arrives. the older
	-- spelling is still honoured for a caller that has not moved.
	local pull = ctx.stdinpull or (ctx.stdin and ctx.stdin.pull)

	ctx.stdin = ctx.stdin and
	    (pull and M.portstream(ctx.stdin.__right) or
	     M.pipestream(ctx.stdin.__right)) or nil
	-- writes are uniform, so the cheap stream will do for both
	ctx.stdout = ctx.stdout and M.pipestream(ctx.stdout.__right) or nil
	ctx.stderr = ctx.stderr and M.pipestream(ctx.stderr.__right) or nil

	-- the screen, if the launcher lent us one. see M.screen below.
	ctx.fb = ctx.fb and ctx.fb.__right or nil
	-- the pointer, if the launcher lent us one. see M.mouse below.
	ctx.ptr = ctx.ptr and ctx.ptr.__right or nil
	-- the keyboard as a device, for a program that hands the panel to
	-- a terminal rather than reading keys itself.
	ctx.kbd = ctx.kbd and ctx.kbd.__right or nil
	-- the window, if we are in one. see M.events below.
	ctx.ev = ctx.ev and ctx.ev.__right or nil
	-- the terminal, if the launcher lent us one. see M.tty below.
	ctx.tty = ctx.tty and ctx.tty.__right or nil
	-- the network, if the launcher lent us one. see M.net below.
	ctx.net = ctx.net and ctx.net.__right or nil
	-- and udp, which is a task of its own. see M.udp below.
	ctx.udp = ctx.udp and ctx.udp.__right or nil
	-- the resolver, if the launcher lent us one. see M.dns below.
	ctx.dns = ctx.dns and ctx.dns.__right or nil
	-- entropy, as data. see M.rand below; ctx.seed is already bytes.
	-- the power task, if the launcher lent us one. see M.power below.
	ctx.power = ctx.power and ctx.power.__right or nil
	-- the debug capability, if the launcher lent one. bin/dbg.lua is
	-- the only program that asks.
	ctx.dbg = ctx.dbg and ctx.dbg.__right or nil
	-- the bluetooth controller, if the launcher lent one. bin/hcitool
	-- and the host stack are what ask.
	ctx.hci = ctx.hci and ctx.hci.__right or nil
	-- the bluetooth service. What an ordinary program asks for: blesrv
	-- arbitrates the controller, where hci above it is the raw radio.
	ctx.ble = ctx.ble and ctx.ble.__right or nil

	local N, nerr = ns.restore(ctx.nsdesc)

	if not N then
		sys.setexit(127)
		return 127
	end
	ctx.ns = N
	-- route require and io.open through this namespace, so a module on a
	-- mount is found and not only the set the ambient C searcher sees in
	-- firmware. On a platform whose whole lib tree is one image (efi's
	-- ESP) the ambient search already finds everything and this changes
	-- nothing; on esp32, where /lib is the firmware image unioned with
	-- the luafs partition, it is the difference between a program reaching
	-- an uploaded lib and not. Skipped for a program given no namespace,
	-- which keeps the ambient searcher it has nothing to replace with.
	if ctx.nsdesc then
		ns.setcurrent(N)
	end
	ctx.setexit = setexit(ctx, sys.setexit)
	-- this program IS the proc, which is what lets os.exit end it from
	-- a thread. M.corun does not set it, and must not.
	ctx.ownproc = true
	return M.run(ctx)
end

-- run a program as a COROUTINE in the caller's proc: no spawn, no
-- lua_State, no message. spec carries stream OBJECTS rather than rights
-- (the caller already holds both ends -- see M.chanstream) and a live
-- namespace rather than a description.
--
-- the namespace is not optional-with-a-default by accident. ns.setcurrent
-- is per-PROC state -- it swaps `require` and installs nsio into this
-- lua_State -- so every coroutine here necessarily shares one namespace,
-- and pretending otherwise by restoring a second would silently give the
-- program a namespace its require() does not use.
--
-- call it inside thread.spawn to get concurrency; called directly it
-- simply runs to completion, which is what a one-stage "pipeline" is.
function M.corun(spec)
	local ctx = {
		path = spec.path, name = spec.name, args = spec.args,
		env = spec.env, cwd = spec.cwd,
		ns = spec.ns or ns.current(),
		stdin = spec.stdin,
		stdout = spec.stdout,
		stderr = spec.stderr or spec.stdout,
		fb = spec.fb,
		ptr = spec.ptr,
		-- a coroutine stage carries the terminal as the bare handle the
		-- shell holds, where M.main gets it wrapped in {__right=} off the
		-- wire -- see Sh:pipecoro. either way M.tty() reads ctx.tty.
		tty = spec.tty,
		net = spec.net,
		udp = spec.udp,
		dns = spec.dns,
		seed = spec.seed,
	}

	if not ctx.ns then
		return 127
	end
	ctx.setexit = setexit(ctx, nil)
	return M.run(ctx)
end

-- ---- the screen ----
--
-- a program that was lent the framebuffer gets it here, wrapped, or nil
-- if it was not. that is the whole test: no probing, no capability
-- query, just whether the launcher put one in the ABI message -- the
-- same rule AGENTS.md states for every other capability.
--
-- this is DOS, taken as literally as the rest of lib/dos.lua takes it: a
-- program that wants the screen gets ALL of it, draws on it, and gives
-- it back by exiting. there is no window, nothing to share it with, and
-- no compositor -- because there is no window system yet, and a program
-- like this is what you can write before there is one. windows 3.1 ran
-- from a DOS prompt for the same reason, in the same order.
--
-- when a layer does arrive it goes HERE, not underneath: this returns
-- something that draws on the whole screen today and would return a
-- window tomorrow, and a program written against it need not care which
-- it got. that is why it hands back a capability object rather than the
-- raw right.
function M.screen()
	local ctx = M.ctx

	if not ctx or not ctx.fb then
		return nil
	end
	return require("draw").new(ctx.fb)
end

-- a generator of this program's own, from the seed the launcher drew
-- for it. Entropy is data here: the raw draw stays in the boot proc and
-- what travels is bytes, so two programs never start from the same.
function M.rand()
	local ctx = M.ctx

	if not ctx or not ctx.seed then
		return nil
	end
	ctx.rng = ctx.rng or require("crypto.drbg").new(ctx.seed)
	return ctx.rng.bytes
end

-- the resolver, where the launcher lent one. A program that takes a
-- url or a host name asks for this; one given none is left to say so
-- rather than to fail at a name it cannot turn into an address.
function M.dns()
	local ctx = M.ctx

	if not ctx or not ctx.dns then
		return nil
	end
	return require("client.dns").new(ctx.dns)
end

-- the pointer, as a reader over the right the launcher lent us: the
-- port carries records and read() takes one off it. nil where the
-- machine has none, and in a window, where they arrive on the event
-- port with the window's own state -- see M.events.
function M.mouse()
	local ctx = M.ctx

	if not ctx or not ctx.ptr then
		return nil
	end
	return require("mouse").reader(ctx.ptr)
end

-- the event port, or nil off a window system. redraw: the pixels are
-- gone, paint from your own state. hidden: what you draw is thrown
-- away, so you may stop.
--	{ t = "win", state = "redraw" | "visible" | "hidden" }
--	"c"	a keystroke, where M.haskeys() is true
function M.events()
	local ctx = M.ctx

	return ctx and ctx.ev or nil
end

-- whether keystrokes arrive on that port. Asked rather than discovered,
-- since a program with no keys would otherwise wait on one forever.
function M.haskeys()
	local ctx = M.ctx

	return (ctx and ctx.keys) == true
end

-- whether the launcher gave this program an input stream at all, which
-- is not the same question as whether there is anything to read.
--
-- fd 0 always exists: a program handed no stdin gets a stream that
-- reads eof, so `cat </dev/null` and `cat` under a launcher with no
-- keyboard behave alike and nothing has to check. That is right for a
-- filter and wrong for a program that waits to be dismissed -- under a
-- window system there is no keyboard to dismiss it with, so an eof
-- means "you will never be told to go", and a program that reads it as
-- "go now" leaves the moment it has drawn.
--
-- So: nil where none was given. bin/smiley.lua is the one that cares.
function M.stdin()
	local ctx = M.ctx

	return ctx and ctx.stdin or nil
end

-- the network, wrapped, or nil where the launcher lent none. Same rule
-- as M.screen, and the same shape lib/http.lua's get() takes.
--
-- This is the whole tcp task, not a socket: a right is a right, so a
-- shell that lends it says its programs may open connections and listen
-- for them. That is a larger thing to hand over than the screen, and it
-- is deliberate rather than overlooked -- the alternative is a network
-- served as a filesystem, which is plan 9's answer and a bigger build
-- than one program deserves.
function M.net()
	local ctx = M.ctx

	if not ctx or not ctx.net then
		return nil
	end
	return require("client.tcp").new(ctx.net)
end

-- udp, wrapped, or nil where the launcher lent none. A separate task
-- from tcp and separately granted, so a program asks for the one it
-- speaks rather than for "the network".
function M.udp()
	local ctx = M.ctx

	if not ctx or not ctx.udp then
		return nil
	end
	return require("client.udp").new(ctx.udp)
end

-- the terminal, wrapped, or nil if the launcher lent none -- the same
-- rule and the same test as M.screen, one capability up. a full-screen
-- program calls this once and errors out on nil, which is what "not a
-- terminal" means: it was piped, or handed to a shell with no console.
function M.tty()
	local ctx = M.ctx

	if not ctx or not ctx.tty then
		return nil
	end
	return require("client.tty").new(ctx.tty)
end

-- the power task, wrapped, or nil where the launcher lent none. Same
-- rule as M.screen and M.net, and the largest of the three: a holder
-- resets or powers off the machine, and there is no smaller piece of it
-- to ask for. So a program says what it needs it for by name
-- (bin/reboot.lua) and a shell without the grant refuses to run it,
-- rather than the program discovering the lack halfway through.
function M.power()
	local ctx = M.ctx

	if not ctx or not ctx.power then
		return nil
	end
	return require("client.power").new(ctx.power)
end

-- the bluetooth controller, as the raw right rather than a client
-- object: what talks to it is lib/ble, which is sans-io and takes a
-- transport rather than making one.
function M.hci()
	local ctx = M.ctx

	return ctx and ctx.hci or nil
end

-- the bluetooth service, which is what a program should ask for: one
-- proc owns the controller and arbitrates it, and a client that held
-- raw hci instead would fight the others for a singleton.
function M.ble()
	local ctx = M.ctx

	return ctx and ctx.ble or nil
end

return M
