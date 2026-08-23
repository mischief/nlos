-- agent: one question, one answer, and the tools in between.
--
--	agent what is in /bin?
--	agent -m gpt-5.4 -v 'read init.lua and say what it starts'
--
-- lib/agent.lua with a terminal in front of it. See docs/agent.md.

local prog = require("prog")
local agent = require("agent")
local llm = require("llm")

local KEYFILE = "/config/openai/key"
local MODEL = "gpt-5.4-mini"

local function die(s)
	io.stderr:write("agent: " .. s .. "\n")
	os.exit(1)
end

local function usage()
	io.stderr:write([[
usage: agent [-m model] [-k keyfile] [-u url] [-v] question...
  -m model    which model to ask (default gpt-5.4-mini)
  -k file     where the key is (default /config/openai/key)
  -u url      an endpoint other than openai's
  -v          say what each tool call did, on stderr
]])
	os.exit(2)
end

local model, keyfile, url, verbose = MODEL, KEYFILE, nil, false
local words = {}
local i = 1

while i <= #arg do
	local a = arg[i]

	if a == "-m" or a == "-k" or a == "-u" then
		i = i + 1
		if not arg[i] then
			usage()
		end
		if a == "-m" then
			model = arg[i]
		elseif a == "-k" then
			keyfile = arg[i]
		else
			url = arg[i]
		end
	elseif a == "-v" then
		verbose = true
	elseif a == "-h" or a == "--help" then
		usage()
	elseif a:sub(1, 1) == "-" and #a > 1 then
		die("unknown option: " .. a)
	else
		words[#words + 1] = a
	end
	i = i + 1
end

if #words == 0 then
	usage()
end

local N = prog.ns() or die("no namespace: nothing to read or run")
local net = prog.net() or
    die("no network capability: this shell was lent none")
local key = N:readfile(keyfile)

if not key then
	die("no key at " .. keyfile)
end
key = key:gsub("^%s+", ""):gsub("%s+$", "")

local client = llm.new({
	net = net,
	dns = prog.dns(),
	key = key,
	url = url,
	model = model,
	rand = prog.rand(),
	stateful = true,
	tools = agent.TOOLS,
	instructions = agent.INSTRUCTIONS,
})

if not client then
	die("could not build a client")
end

-- a tool is lent what this program was lent, no more. rand stays a
-- function so each spawn draws its own seed.
local A = agent.new({
	client = client,
	caps = {
		tcp = prog.ctx and prog.ctx.net,
		dns = prog.ctx and prog.ctx.dns,
		rand = prog.rand(),
	},
	ns = N,
	cwd = prog.cwd(),
	trace = verbose and function(call, out)
		io.stderr:write(("agent: %s %s -> %s\n"):format(call.name,
		    call.raw or "", (tostring(out):gsub("%s+$", ""))))
	end or nil,
})

local answer, err = A:run(table.concat(words, " "))

if not answer then
	die(tostring(err))
end
io.write(answer .. "\n")
