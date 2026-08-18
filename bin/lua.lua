-- lua: a lua prompt, with this program's capabilities and no more.
--
--	lua			read and evaluate lines until eof
--	lua -e CHUNK		evaluate one chunk and print what it returns
--	lua FILE [ARG...]	run a file, arg[1..] as given

-- The boot console is a lua prompt with the machine's capabilities as
-- bare words. This is the same thing reached from a shell, so what it
-- can touch is what the launcher lent it: a session granted less gets
-- a weaker prompt without either side arranging it, and an ssh or panel
-- shell gets a prompt at all.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")

-- the capabilities, under the names the boot console binds, so a line
-- that works there works here. Absent rather than nil-guarded: a prompt
-- reports "undefined global fb" on a machine with no panel, which says
-- more than a nil index further in.
local function bind(env)
	local ctx = prog.ctx or {}

	env.sys = sys
	env.thread = thread
	env.prog = prog
	env.fb = ctx.fb
	env.net = ctx.net
	env.udp = ctx.udp
	env.dns = ctx.dns
	env.power = ctx.power
	env.dbg = ctx.dbg
	env.kbd = ctx.kbd
	env.ns = prog.ns()
	return env
end

-- into this program's own environment, not _G: lib/prog gives every
-- program a table of its own that reads through to the globals, and
-- what it puts there -- os, arg, a require that answers for the posix
-- sliver -- is only there.
bind(_ENV)

-- expression first, then statement: a bare `x` at a prompt is a
-- question, and `x = 1` is not an expression at all.
--
-- With this program's environment, or a typed line gets the bare
-- globals: load() defaults to _G rather than to the caller's _ENV, so
-- os.exit(0) at this prompt answered "undefined global 'os'".
local function compile(src, name)
	local chunk, err = load("return " .. src, name, "t", _ENV)

	if not chunk then
		chunk, err = load(src, name, "t", _ENV)
	end
	return chunk, err
end

-- os.exit raises a sentinel for the launcher to catch, so a handler
-- that turns everything into a traceback turns leaving into a fault:
-- `os.exit(0)` at this prompt printed an error and stayed. It goes
-- through untouched, and is raised again to carry on unwinding.
local function trace(err)
	if err == prog.EXIT then
		return err
	end
	return debug.traceback(err)
end

-- xpcall rather than pcall: the handler runs while the stack is still
-- live, which is the only way debug.traceback sees anything.
local function callit(chunk)
	local res = table.pack(xpcall(chunk, trace))

	if not res[1] then
		if res[2] == prog.EXIT then
			error(prog.EXIT, 0)
		end
		io.stderr:write("lua: " .. tostring(res[2]) .. "\n")
		return false
	end
	if res.n > 1 then
		local out = {}

		for i = 2, res.n do
			out[#out + 1] = tostring(res[i])
		end
		io.write(table.concat(out, "\t"), "\n")
	end
	return true
end

if arg[1] == "-e" then
	if not arg[2] then
		io.stderr:write("lua: -e needs a chunk\n")
		os.exit(1)
	end

	local chunk, err = compile(arg[2], "=(-e)")

	if not chunk then
		io.stderr:write("lua: " .. tostring(err) .. "\n")
		os.exit(1)
	end
	os.exit(callit(chunk) and 0 or 1)
end

if arg[1] then
	local path = arg[1]
	local N = prog.ns()
	local src, why = N and N:readfile(path)

	if not src then
		io.stderr:write(("lua: %s: %s\n"):format(path,
		    tostring(why or "no namespace")))
		os.exit(1)
	end
	-- the file's own arguments, numbered from one as a script expects,
	-- with the script itself at zero.
	local a = { [0] = path }

	for i = 2, #arg do
		a[i - 1] = arg[i]
	end
	_G.arg = a

	local chunk, err = load(src, "@" .. path)

	if not chunk then
		io.stderr:write("lua: " .. tostring(err) .. "\n")
		os.exit(1)
	end
	os.exit(callit(chunk) and 0 or 1)
end

-- interactive. The terminal's readline, not stdin: the console owns the
-- prompt that way, so history recall redraws it instead of over it.
local tty = prog.tty()

if not tty then
	io.stderr:write("lua: not a terminal\n")
	os.exit(1)
end

io.write(_VERSION .. " -- capabilities are globals; ^d to leave\n")

while true do
	local line = tty.readline("lua> ")

	if line == nil then
		break
	end
	if #line > 0 then
		local chunk, err = compile(line, "=lua")

		-- an unfinished chunk asks for the rest, which is what
		-- makes a function definition typeable at a prompt.
		while not chunk and err and err:sub(-5) == "<eof>" do
			local more = tty.readline("lua>> ")

			if more == nil then
				break
			end
			line = line .. "\n" .. more
			chunk, err = load(line, "=lua")
		end
		if chunk then
			callit(chunk)
		else
			io.stderr:write("lua: " .. tostring(err) .. "\n")
		end
	end
end
