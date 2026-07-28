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
--     stdout = { __right = h } | nil,
--     stderr = { __right = h } | nil,
--   }
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
local thread = require("los.thread")
local ns = require("ns")

local M = {}

-- ---- streams ----
--
-- two implementations behind one shape (:read/:write/:close), because
-- the two things a program's stdout can be are genuinely different: a
-- port (a pipe, or the console task) and a file in the namespace.
--
-- the port form speaks the protocol lib/cons.lua and lib/wire.lua
-- already invented independently: {op="write", data=} with no reply, and
-- {op="read", reply={__right=}}. standardising on it is what lets a
-- program write the same way to a terminal, a pipe or a file without
-- ever learning which it has.

local PortStream = {}

PortStream.__index = PortStream

function M.portstream(h)
	return setmetatable({ h = h, replyport = nil }, PortStream)
end

function PortStream:write(data)
	sys.send(self.h, { op = "write", data = data })
	return #data
end

function PortStream:read(_)
	if not self.replyport then
		self.replyport = sys.newport()
	end
	sys.send(self.h, { op = "read", reply = { __right = self.replyport } })
	local r = thread.recv(self.replyport)

	-- nil means the far end is done; the ABI says "" is eof so that a
	-- program's `while data ~= ""` loop terminates rather than erroring
	return r or ""
end

function PortStream:close()
	if self.replyport then
		sys.close(self.replyport)
		self.replyport = nil
	end
end

local FileStream = {}

FileStream.__index = FileStream

function M.filestream(f)
	return setmetatable({ f = f }, FileStream)
end

function FileStream:write(data)
	local n = self.f:write(data)

	return n or 0
end

function FileStream:read(n)
	return self.f:read(n or 8192) or ""
end

function FileStream:close()
	self.f:close()
end

-- ---- the fd table ----

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

local function install(ctx)
	local fds = newfds(ctx)
	local G = _G

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

	-- os is excluded from our stdlib entirely (see src/linit.c), so this
	-- is not an override -- it is the only os a program has.
	G.os = G.os or {}
	G.os.exit = function(code)
		-- record the status, then unwind. the two are separate: see
		-- sys.setexit's comment on why the kernel does not raise.
		sys.setexit(tonumber(code) or 0)
		error(M.EXIT, 0)
	end

	-- plan 9's exits(msg): nil is success, any string is failure WITH a
	-- reason, which beats a number nobody has a table for. sys.setexit
	-- takes either, so both idioms are first class -- ported utilities
	-- keep calling os.exit(1) and native ones can say why.
	G.exits = function(msg)
		sys.setexit(msg)
		error(M.EXIT, 0)
	end
	G.os.getenv = function(k)
		return (ctx.env or {})[k]
	end
	G.os.time = function()
		return sys.uptime_ms() // 1000
	end

	-- io.write/io.stderr must reach the ABI's streams, not the raw
	-- console: a program in a pipeline whose io.write went straight to
	-- the terminal would bypass the pipe entirely.
	G.io = G.io or {}
	G.io.write = function(...)
		for _, v in ipairs({ ... }) do
			fds[1]:write(tostring(v))
		end
	end
	G.io.stdout = { write = function(_, ...) G.io.write(...) end }
	G.io.stderr = {
		write = function(_, ...)
			for _, v in ipairs({ ... }) do
				fds[2]:write(tostring(v))
			end
		end,
	}
	-- print goes to stdout like everything else
	G.print = function(...)
		local parts = {}

		for i, v in ipairs({ ... }) do
			parts[i] = tostring(v)
		end
		fds[1]:write(table.concat(parts, "\t") .. "\n")
	end

	local N = ctx.ns

	package.preload["posix.unistd"] = function()
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
	package.preload["posix.dirent"] = function()
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

	package.preload["posix.fcntl"] = function()
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

	return fds
end

-- resolve a program-supplied path against its cwd, so a relative path
-- means what the program expects
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
function M.main()
	local ctx = thread.recv(sys.SELF)

	M.ctx = ctx

	ctx.stdin = ctx.stdin and M.portstream(ctx.stdin.__right) or nil
	ctx.stdout = ctx.stdout and M.portstream(ctx.stdout.__right) or nil
	ctx.stderr = ctx.stderr and M.portstream(ctx.stderr.__right) or nil

	local N, nerr = ns.restore(ctx.nsdesc)

	if not N then
		sys.setexit(127)
		return
	end
	ctx.ns = N

	local fds = install(ctx)
	local src, serr = N:readfile(ctx.path)

	if not src then
		fds[2]:write((ctx.name or "?") .. ": " .. tostring(serr) .. "\n")
		sys.setexit(127)
		return
	end

	local chunk, lerr = load(src, "=" .. (ctx.name or "prog"))

	if not chunk then
		fds[2]:write((ctx.name or "?") .. ": " .. tostring(lerr) .. "\n")
		sys.setexit(126)
		return
	end

	local ok, err = pcall(chunk)

	if not ok and err ~= M.EXIT then
		fds[2]:write((ctx.name or "?") .. ": " .. tostring(err) .. "\n")
		sys.setexit(1)
	end
	-- flush nothing: writes are messages and already sent
end

return M
