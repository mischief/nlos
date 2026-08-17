-- the program ABI (lib/prog.lua) and the launcher (lib/dos.lua).
--
-- the claim being tested: two real utilities from the host lua/os tree run here
-- UNCHANGED. bin/seq.lua and bin/cat.lua differ from their originals only
-- in the shebang line. if the posix sliver in prog.lua is right, they
-- need no port at all.
local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local ns = require("ns")
local espfs = require("espfs")
local dos = require("dos")
local tap = require("tap")

tap.plan(34)

local N = ns.new()

local espcaps = sys.granted()

-- the ESP as a MOUNT, not a local espfs. a child cannot rebuild espfs
-- any more -- los.fs belongs to the esp server task alone -- so what
-- describe() must hand it is a right to that server. see lib/espsrv.lua.
N:mount("/", require("mnt").new(espcaps.esp), "mnt",
    { port = { __right = espcaps.esp } })

-- ---- a collector: stands in for a terminal, so we can read what a
-- ---- program actually wrote
local function collector()
	local port = sys.newport("test_prog")
	local out = {}

	-- drain everything queued without blocking, and CLEAR: each call
	-- returns what was written since the last one, not everything ever.
	return port, out, function()
		while true do
			local ok, m = sys.tryrecv(port)

			if not ok then
				local s = table.concat(out)

				for i = #out, 1, -1 do
					out[i] = nil
				end
				return s
			end
			if m and m.op == "write" then
				out[#out + 1] = m.data
			end
		end
	end
end

-- run one program to completion, returning its output and status
local function run(path, argv, stdinport)
	local outport, out, drain = collector()
	local pid, h = sys.spawn('require("prog").main()', { name = argv[1] })

	sys.monitor(pid)
	sys.send(h, {
		path = path,
		name = argv[1],
		args = argv,
		env = { PATH = "/bin" },
		cwd = "/",
		nsdesc = N:describe(),
		stdin = stdinport and { __right = stdinport } or nil,
		stdout = { __right = outport },
		stderr = { __right = outport },
	})
	sys.close(h)

	local status, exitmsg, normal
	local deadline = sys.uptime_ms() + 5000
	-- ACCUMULATE what each drain returns. drain() clears its buffer, so
	-- discarding the return here threw away anything the program wrote
	-- before it exited -- which was invisible while every program
	-- finished in one scheduler lap, and stopped being invisible the
	-- moment reads went through a mount and took several.
	local acc = {}

	while sys.uptime_ms() < deadline do
		local ok, m = sys.tryrecv(sys.SELF)

		if ok and m and m.exit == pid then
			status, exitmsg, normal = m.status, m.exitmsg, m.normal
			break
		end
		-- keep draining so a chatty program cannot fill the port
		acc[#acc + 1] = drain()
		sys.yield()
	end
	acc[#acc + 1] = drain()
	return table.concat(acc), status, exitmsg, normal
end

-- ---- seq: needs only arg, unistd.write, os.exit ----
local sout, sstatus = run("/bin/seq.lua", { "seq", "5" })

tap.is(sout, "1\n2\n3\n4\n5\n", "seq 5 produced 1..5 unchanged")
tap.is(sstatus, 0, "seq exited 0")

local s2 = run("/bin/seq.lua", { "seq", "2", "2", "8" })

tap.is(s2, "2\n4\n6\n8\n", "seq 2 2 8 honours first/incr/last")

-- a bad invocation must reach stderr and exit nonzero
local berr, bstatus = run("/bin/seq.lua", { "seq", "notanumber" })

tap.ok(berr:find("invalid argument") ~= nil,
    "seq wrote its usage error to stderr: " .. berr:gsub("\n", ""))
tap.is(bstatus, 1, "seq exited 1 via os.exit")

-- ---- cat: needs fcntl.open, a numeric fd, unistd.read ----
local cout, cstatus = run("/bin/cat.lua", { "cat", "/bin/seq.lua" })

tap.ok(cout:find("SPDX", 1, true) ~= nil,
    "cat read a real file through fcntl.open + a numeric fd")
tap.is(cstatus, 0, "cat exited 0")

local cbad, cbadstatus = run("/bin/cat.lua", { "cat", "/nope" })

tap.ok(cbad:find("cat:") ~= nil, "cat reported a missing file: " ..
    cbad:gsub("\n", ""))
tap.is(cbadstatus, 1, "cat exited 1 on a missing file")

-- ---- a program that was handed no stdout does not crash ----
local nopid, noh = sys.spawn('require("prog").main()', { name = "quiet" })

sys.monitor(nopid)
sys.send(noh, {
	path = "/bin/seq.lua", name = "seq", args = { "seq", "3" },
	env = {}, cwd = "/", nsdesc = N:describe(),
})
sys.close(noh)

local qm

repeat
	qm = thread.recv(sys.SELF)
until qm.exit == nopid
tap.ok(qm.normal, "a program with no stdout still exits normally")

-- ---- plan 9 style exits("why") carries a string ----
N:writefile("/bin/failing.lua", 'exits("deliberately unhappy")\n')

local _, fstatus, fmsg = run("/bin/failing.lua", { "failing" })

tap.is(fstatus, 1, "exits(string) reports status 1 for numeric consumers")
tap.is(fmsg, "deliberately unhappy",
    "and the exit MESSAGE survives to the monitor: " .. tostring(fmsg))

-- ---- the launcher's own parsing ----
local words = dos.split([[echo "two words" 'and more' bare]])

tap.is(table.concat(words, "|"), "echo|two words|and more|bare",
    "dos.split handles both quote styles")

-- ---- a pipeline: seq into cat, joined by a port ----
-- this is the piece that needs no pipe(), no dup2() and no SIGPIPE: the
-- writer exiting drops its right, and the reader sees eof.
-- drain any monitor notifications the tests above left behind, so the
-- launcher's wait loop starts from a clean mailbox
while select(1, sys.tryrecv(sys.SELF)) do end

local sh = dos.new({ ns = N, cons = select(1, collector()) })
local pipeout, pipeacc, pipedrain = collector()

sh.cons = pipeout

local pstatus = dos.once(sh, "seq 3 | cat")

-- the launcher drives its pipe coroutines inside run(), so by the time
-- it returns the output has been delivered
tap.is(pipedrain(), "1\n2\n3\n",
    "seq 3 | cat moved bytes through a port pipeline (status " ..
    tostring(pstatus) .. ")")

-- ---- the launcher, driven the way dos() drives it ----
-- same construction init.lua's dos() performs: a namespace over the
-- ESP plus the console handle. only thread.readline is missing, which is
-- why the lines are scripted here rather than typed.
local function shell()
	local cons, _, drain = collector()
	local s = dos.new({ ns = N, cons = cons })

	return s, drain
end

local sh2, drain2 = shell()

tap.is(dos.once(sh2, "pwd"), 0, "pwd builtin returns 0")
tap.is(drain2(), "/\n", "pwd printed the cwd")

tap.is(dos.once(sh2, "cd /bin"), 0, "cd into a real directory")
dos.once(sh2, "pwd")
tap.is(drain2(), "/bin\n", "cd changed the cwd")

tap.is(dos.once(sh2, "cd /nosuch"), 1, "cd into a missing directory fails")
drain2()

-- ls is native rather than ported: it needs the namespace, not the
-- posix sliver
dos.once(sh2, "cd /")
drain2()
dos.once(sh2, "ls /bin")
local lsout = drain2()

tap.ok(lsout:find("seq.lua") ~= nil and lsout:find("cat.lua") ~= nil,
    "ls /bin lists the programs: " .. lsout:gsub("\n", " "))

-- a command that is not there
tap.is(dos.once(sh2, "nosuchprogram"), 127, "unknown command is status 127")
drain2()

-- redirection into a file, then read it back through the namespace
dos.once(sh2, "seq 3 > /out.txt")
tap.is(N:readfile("/out.txt"), "1\n2\n3\n",
    "seq 3 > /out.txt wrote through a file server")

-- and back OUT of a file. this direction was broken and silent: the
-- launcher marks a file redirect as a PULL stream (the reader is a
-- server that answers {op="read"}), and that flag used to be written
-- inside the stdin table -- where the serializer drops it, since a table
-- carrying __right ships as the right alone. the program therefore got a
-- pull server and treated it as a pipe, calling tryrecv on a send right.
--
-- nothing caught it because nothing here read from a file redirect. it
-- surfaced only when a program first tried to read the CONSOLE, which
-- is a pull stream for the same reason.
dos.once(sh2, "cat < /out.txt")
tap.is(drain2(), "1\n2\n3\n", "cat < /out.txt read through a file server")

-- ---- the program environment is the program's own ----
--
-- install() used to write arg/os/io/print into _G and register the
-- posix sliver in package.preload, which is per-PROC. correct for
-- exactly one program per proc and silently wrong for any other
-- arrangement: two programs in one lua_State would share `arg`, so the
-- second to start would rewrite the first's argv mid-run. that is the
-- pipeline case, and it is what a coroutine-per-stage launcher needs.
--
-- a program can still SEE _G through its env's __index, so it can look
-- and report -- which is what makes this testable from the inside.
local envprobe = [[
local unistd = require("posix.unistd")
local out = {}

-- what install defines must be ours, not the proc's
out[#out + 1] = "G.arg=" .. tostring(rawget(_G, "arg"))
out[#out + 1] = "G.exits=" .. tostring(rawget(_G, "exits"))
out[#out + 1] = "preload=" .. tostring(package.preload["posix.unistd"])
-- ...while everything we did not define still reads through
out[#out + 1] = "string=" .. tostring(string ~= nil)
out[#out + 1] = "myarg=" .. tostring(arg[1])
unistd.write(1, table.concat(out, " ") .. "\n")
]]

N:writefile("/bin/envprobe.lua", envprobe)
dos.once(sh2, "envprobe hello")
local probeout = drain2()

tap.ok(probeout:find("G.arg=nil") ~= nil,
    "a program's arg does not land in _G: " .. probeout:gsub("\n", ""))
tap.ok(probeout:find("G.exits=nil") ~= nil,
    "nor does exits")
tap.ok(probeout:find("preload=nil") ~= nil,
    "the posix sliver is per-program, not in package.preload")
tap.ok(probeout:find("string=true") ~= nil,
    "the rest of the stdlib still reads through to _G")
tap.ok(probeout:find("myarg=hello") ~= nil,
    "and the program's own arg is intact")

-- ---- a pipeline as COROUTINES, in one proc ----
--
-- the payoff of the two changes above. `seq 3 | cat` with no spawn, no
-- second lua_State and no ports: both stages are coroutines in THIS
-- proc, joined by a Channel, and neither program was modified to allow
-- it -- prog.chanstream satisfies the same :read/:write/:close that
-- PipeStream does, so cat cannot tell what it is reading from.
--
-- this is what a proc costs today: ~34-40KB of lua_State per stage,
-- against a coroutine and a table here. it is also why MAXPROCS stops
-- bounding pipeline depth.
local prog = require("prog")

-- a sink standing in for the far end of the pipeline
local sink = { buf = {} }

function sink:write(d)
	self.buf[#self.buf + 1] = d
	return #d
end

function sink:read() return "" end
function sink:close() end

local pipe = thread.chancreate(2)	-- bounded: backpressure, not a buffer
local seqst, catst

thread.spawn(function()
	seqst = prog.corun({
		path = "/bin/seq.lua", name = "seq", args = { "seq", "3" },
		env = { PATH = "/bin" }, cwd = "/", ns = N,
		stdout = prog.chanstream(pipe),
	})
	-- the writer says when it is done. a channel has no refcount to
	-- infer eof from, which is exactly what Channel:close() is for.
	pipe:close()
end)

thread.spawn(function()
	catst = prog.corun({
		path = "/bin/cat.lua", name = "cat", args = { "cat" },
		env = { PATH = "/bin" }, cwd = "/", ns = N,
		stdin = prog.chanstream(pipe), stdout = sink,
	})
end)
thread.run()

tap.is(table.concat(sink.buf), "1\n2\n3\n",
    "seq 3 | cat ran as two coroutines in one proc")
tap.is(seqst, 0, "the writing stage reported its own status")
tap.is(catst, 0, "and so did the reading stage")

-- and the argv collision that made this impossible before: both stages
-- ran concurrently in one lua_State, so a shared _G.arg would have left
-- whichever started second holding the other's arguments.
tap.is(rawget(_G, "arg"), nil,
    "neither stage leaked its arg into the hosting proc")

-- ---- a pull stream's write parks rather than drops ----
--
-- Only reading differs between the two port streams, so a write that
-- reports bytes it never sent is the same defect in either. The queue
-- is filled first: the write below has nowhere to go until the reader
-- takes something off.
local full = sys.newport("test_prog.full")
local fullsend = sys.sendright(full)
local chunk = string.rep("x", 8192)

-- "full" means this message does not fit, not that the queue is shut:
-- a small one still would. So the write below is the same size as what
-- filled the queue, and is refused for as long as the queue is.
while sys.send(fullsend, { op = "write", data = chunk }) do
end

local tail = string.rep("t", 8192)
local wrote, arrived, tried

thread.spawn(function()
	-- the flag and the send are one step: nothing yields between them,
	-- so the drain below cannot make room before the write is tried.
	tried = true
	wrote = prog.portstream(fullsend):write(tail)
end)

-- recvtimeout, not recv: a write that was dropped leaves nothing to
-- wait for, and this has to fail rather than hang. The yield is what
-- keeps the drain from making room before the write is tried.
thread.spawn(function()
	while not tried do
		thread.yield()
	end
	while true do
		local m = thread.recvtimeout(full, 2000)

		if not m then
			return
		end
		if m.data == tail then
			arrived = true
			return
		end
	end
end)
thread.run()

tap.is(wrote, #tail, "a pull stream's write reports what it sent")
tap.ok(arrived, "and a full queue parks the write instead of dropping it")

sys.close(fullsend)
sys.close(full)

tap.done()
