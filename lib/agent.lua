-- agent: a model, a few tools, and the loop between them.
--
--	local a = agent.new({ client = llm.new{...}, caps = sys.granted() })
--	print(a:run("what is in /bin?"))

-- The loop is the whole of it: ask, and while the answer is tool calls
-- rather than words, run them and hand the results back. What ends it
-- is a turn with no calls in it.

-- `lua` is the general one -- everything here is reachable from lua and
-- almost nothing is reachable any other way -- and `spawn` runs a
-- program under the ABI a shell uses. read_file and write_file are
-- clm's shape, and named as clm names them so a model's priors help.

-- The instructions matter more than usual: this machine is not the one
-- the model has read about, and one left to guess reaches for a shell,
-- for /usr, and for a filesystem that is the same for every process.

local sys = require("los.sys")
local thread = require("los.thread")
local proc = require("proc")
local ns = require("ns")
local llm = require("llm")

local M = {}

local Agent = {}

Agent.__index = Agent

M.INSTRUCTIONS = [[
You are running on lua-os: a small operating system written in Lua, on
a machine that is not Unix and not Linux. Read this before guessing.

- There is no shell syntax, no pipes in a tool call, no sh -c. To run
  something, call spawn with a program and its arguments as a list.
- Programs live in /bin and are Lua files: /bin/ls.lua, /bin/cat.lua.
  Name them to spawn without the directory or the extension: "ls".
- The filesystem is a per-process namespace, plan 9 style. / holds bin,
  lib, task, etc, net, proc and srv. /net and /proc are synthesised --
  files there are the machine answering, not bytes on a disk.
- The lua tool evaluates a chunk in this process. It is the most
  capable thing you have: require("los.sys") reaches the kernel,
  require("ns").current() reaches the namespace. Prefer it when no
  program does what you want, and say what you are doing.
- read_file takes a window of lines; write_file replaces a whole file.
  The root may be read-only, and then write_file says so.
- Answer from what the tools return. Do not invent paths or output.
]]

M.TOOLS = {
	{
		type = "function",
		name = "lua",
		description = "Evaluate a Lua chunk on the machine and " ..
		    "return what it prints and what it returns. The whole " ..
		    "of lua-os is reachable from here.",
		parameters = {
			type = "object",
			properties = {
				chunk = {
					type = "string",
					description = "Lua source to run.",
				},
			},
			required = { "chunk" },
		},
	},
	{
		type = "function",
		name = "read_file",
		description = "Read a window of lines from a file. " ..
		    "Windowed because this machine is small: a whole file " ..
		    "may not fit in the answer.",
		parameters = {
			type = "object",
			properties = {
				path = { type = "string",
				    description = "Path in the namespace." },
				offset = { type = "integer",
				    description = "First line, 1-indexed." },
				limit = { type = "integer",
				    description = "How many lines at most." },
			},
			required = { "path" },
		},
	},
	{
		type = "function",
		name = "write_file",
		description = "Write a file, replacing what was there. " ..
		    "The root may be read-only, and then this says so.",
		parameters = {
			type = "object",
			properties = {
				path = { type = "string",
				    description = "Path in the namespace." },
				content = { type = "string",
				    description = "The whole new contents." },
			},
			required = { "path", "content" },
		},
	},
	{
		type = "function",
		name = "spawn",
		description = "Run a program from /bin and return its " ..
		    "output. No shell: give the program and its arguments " ..
		    "separately.",
		parameters = {
			type = "object",
			properties = {
				program = {
					type = "string",
					description = "A name in /bin, " ..
					    "such as ls or cat.",
				},
				args = {
					type = "array",
					items = { type = "string" },
					description = "Arguments, in order.",
				},
			},
			required = { "program" },
		},
	},
}

-- what a tool call may name, built from the list above so the two
-- cannot drift: offering a tool and refusing to run it, or running one
-- never offered, are both mistakes this makes impossible.
M.OFFERED = {}

for _, t in ipairs(M.TOOLS) do
	M.OFFERED[t.name] = true
end

-- ---- the tools ----

-- what a program wrote, gathered from a port it was given as stdout.
--
-- Ends when every writer is gone, which is why our own send right is
-- closed after the spawn message carries a copy: hold one and the drain
-- never sees the end.
local function drain(port, limit)
	local parts, n = {}, 0

	while true do
		local m, why = thread.await(port)

		if why then
			break
		end
		if type(m) == "table" and type(m.data) == "string" then
			n = n + #m.data
			if n > limit then
				parts[#parts + 1] =
				    "\n[output truncated]\n"
				break
			end
			parts[#parts + 1] = m.data
		end
	end
	return table.concat(parts)
end

function Agent:spawn(args)
	local name = tostring(args.program or "")

	if name == "" then
		return "spawn: no program named"
	end
	-- a name, not a path: the model is told to say "ls", and a model
	-- that says /bin/ls.lua anyway is not wrong either.
	local path = name

	if not path:find("/") then
		path = "/bin/" .. path .. ".lua"
	end
	if not self.ns:stat(path) then
		return "spawn: no such program: " .. path
	end

	local argv = { name }

	for _, a in ipairs(args.args or {}) do
		argv[#argv + 1] = tostring(a)
	end

	local out = sys.newport("agent.out")
	local send = sys.sendright(out)
	local pid, h = proc.spawn('require("prog").main()',
	    { name = name, ns = self.nsdesc })

	if not pid then
		sys.close(send)
		sys.close(out)
		return "spawn: could not start " .. name
	end

	sys.send(h, {
		path = path,
		name = name,
		args = argv,
		env = { PATH = "/bin", HOME = "/" },
		cwd = self.cwd or "/",
		nsdesc = self.nsdesc,
		stdout = { __right = send },
		stderr = { __right = send },
		net = self.caps.tcp and { __right = self.caps.tcp } or nil,
		dns = self.caps.dns and { __right = self.caps.dns } or nil,
	})
	sys.close(h)
	-- ours is closed now: rights are copied on send, and a writer we
	-- still held would keep the drain below waiting forever.
	sys.close(send)

	local text = drain(out, self.limit)

	sys.close(out)
	if text == "" then
		return "(no output)"
	end
	return text
end

-- a window of lines, read as far as the window and no further.
--
-- Opened and drained rather than readfile'd: readfile builds the whole
-- file as one string first, so windowing afterwards would prevent
-- nothing -- a model asking for a megabyte would have spent it before
-- the limit was consulted. This stops reading once it has enough.
function Agent:read_file(args)
	local path = ns.clean(tostring(args.path or ""))
	local f, err = self.ns:open(path, "r")

	if not f then
		return "read_file: " .. path .. ": " .. tostring(err)
	end

	local from = math.max(1, math.tointeger(args.offset) or 1)
	local want = math.max(1, math.tointeger(args.limit) or 200)
	local out, n, at = {}, 0, 0
	local buf, more, bytes = "", false, 0

	-- complete lines out of what has arrived, returning true when the
	-- window is full and there is more file behind it. buf keeps only
	-- the tail after the last newline, so it stays about one line long
	-- however big the file is.
	local function take()
		while true do
			local nl = buf:find("\n", 1, true)

			if not nl then
				return false
			end

			local line = buf:sub(1, nl - 1)

			buf = buf:sub(nl + 1)
			at = at + 1
			if at >= from then
				n = n + 1
				if n > want then
					return true
				end
				out[#out + 1] = line
			end
		end
	end

	while true do
		local chunk, rerr = f:read(4096)

		if not chunk then
			f:close()
			return "read_file: " .. path .. ": " .. tostring(rerr)
		end
		if chunk == "" then
			-- a last line with no newline after it
			if buf ~= "" then
				at = at + 1
				if at >= from and n < want then
					out[#out + 1] = buf
				end
			end
			break
		end
		bytes = bytes + #chunk
		buf = buf .. chunk
		more = take()
		if more then
			break
		end
	end
	f:close()

	if more then
		out[#out + 1] = ("[more: line %d on]"):format(at)
	end
	if #out == 0 then
		return ("read_file: %s: no lines from %d (read %d bytes)")
		    :format(path, from, bytes)
	end
	return table.concat(out, "\n")
end

function Agent:write_file(args)
	local path = ns.clean(tostring(args.path or ""))
	local content = args.content

	if type(content) ~= "string" then
		return "write_file: no content"
	end

	local n, err = self.ns:writefile(path, content)

	if not n then
		return "write_file: " .. path .. ": " .. tostring(err)
	end
	return ("wrote %d bytes to %s"):format(n, path)
end

function Agent:lua(args)
	local src = tostring(args.chunk or "")

	if src == "" then
		return "lua: no chunk given"
	end

	-- print goes into the answer rather than to a console the model
	-- cannot see. Everything else is this proc's own environment,
	-- which is the point of the tool.
	local said = {}
	local env = setmetatable({
		print = function(...)
			local n = select("#", ...)
			local bits = {}

			for i = 1, n do
				bits[i] = tostring((select(i, ...)))
			end
			said[#said + 1] = table.concat(bits, "\t")
		end,
	}, { __index = _G, __newindex = _G })

	local chunk, cerr = load(src, "=tool", "t", env)

	if not chunk then
		return "lua: " .. tostring(cerr)
	end

	local ok, res = pcall(chunk)

	if not ok then
		return "lua: error: " .. tostring(res)
	end
	if res ~= nil then
		said[#said + 1] = "= " .. tostring(res)
	end
	if #said == 0 then
		return "(no output)"
	end
	return table.concat(said, "\n")
end

-- ---- the loop ----

-- new(opts) -> agent
--
--   client   an llm client, made stateful where the endpoint has it
--   caps     sys.granted(), for what a spawned program is lent
--   ns       the namespace, defaulting to this proc's
--   turns    how many tool rounds before answering from what it has.
--            Reading a tree one file at a time spends these fast, so
--            the bound is high enough for that and exists only to stop
--            a loop that will not end.
function M.new(opts)
	opts = opts or {}

	local a = setmetatable({
		client = opts.client,
		caps = opts.caps or {},
		ns = opts.ns or ns.current(),
		cwd = opts.cwd or "/",
		turns = opts.turns or 32,
		limit = opts.limit or 8192,
		trace = opts.trace,
	}, Agent)

	a.nsdesc = a.ns and a.ns:describe() or nil
	return a
end

-- valid utf8, because a json string must be one: a file read by a tool
-- may hold a byte that is not text, and the server refuses the whole
-- request for it rather than the one string.
local function text8(s)
	s = tostring(s)
	if utf8.len(s) then
		return s
	end

	local out, i = {}, 1

	while i <= #s do
		local ok, bad = utf8.len(s, i)

		if ok then
			out[#out + 1] = s:sub(i)
			break
		end
		out[#out + 1] = s:sub(i, bad - 1) .. "?"
		i = bad + 1
	end
	return table.concat(out)
end

function Agent:dispatch(call)
	local fn = Agent[call.name]

	-- by name from the class, but only the ones offered: a model that
	-- asked for "run" or "close" must not reach a method that happens
	-- to exist.
	if not M.OFFERED[call.name] then
		fn = nil
	end
	if not fn then
		return "no such tool: " .. tostring(call.name)
	end

	local ok, res = pcall(fn, self, call.arguments)

	if not ok then
		return "tool error: " .. tostring(res)
	end
	return text8(res)
end

-- run(prompt) -> text, or nil plus why.
--
-- Each round sends the tool results and nothing else, so a stateful
-- client carries an id rather than a transcript however long the loop
-- runs -- which is what makes a loop affordable here at all.
function Agent:run(prompt)
	local input = prompt
	local res, err = self.client:ask(input,
	    self.client.stateful and self.client.last and
	    { previous_response_id = self.client.last } or nil)

	if not res then
		return nil, err
	end
	self.client.last = res.id

	for _ = 1, self.turns do
		local calls = llm.calls(res)

		if #calls == 0 then
			return llm.text(res) or "", res
		end

		local results = {}

		for _, c in ipairs(calls) do
			local out = self:dispatch(c)

			if self.trace then
				self.trace(c, out)
			end
			results[#results + 1] = llm.result(c.call_id, out)
		end

		res, err = self.client:ask(results,
		    self.client.stateful and
		    { previous_response_id = self.client.last } or nil)
		if not res then
			return nil, err
		end
		self.client.last = res.id
	end

	-- out of rounds, but not out of an answer: ask once more with the
	-- tools closed off, so the work already done is reported rather
	-- than thrown away.
	local extra = { tool_choice = "none" }

	if self.client.stateful and self.client.last then
		extra.previous_response_id = self.client.last
	end

	res, err = self.client:ask(("You have used all %d tool rounds. " ..
	    "Answer now from what you have found, and say what is still " ..
	    "unchecked."):format(self.turns), extra)
	if not res then
		return nil, ("stopped after %d rounds of tool calls: %s")
		    :format(self.turns, tostring(err))
	end
	self.client.last = res.id
	return llm.text(res) or
	    ("stopped after %d rounds of tool calls"):format(self.turns), res
end

return M
