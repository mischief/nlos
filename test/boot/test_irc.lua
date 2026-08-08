-- bin/irc.lua against a server this test is, over loopback.
--
-- The client wants a socket, a keyboard and a clock at once, so the
-- test is all three: a listener on 127.0.0.1, a console that answers
-- getch from a script, and deadlines on both so a client that never
-- finishes fails rather than hangs.
--
-- test/host_irc.lua covers the codec and needs none of this. What is
-- here is the part it cannot reach: that the client registers
-- unprompted, that what arrives on the socket reaches the screen, and
-- that a typed line leaves as a PRIVMSG.
local sys = require("los.sys")
local dos = require("dos")
local ns = require("ns")
local thread = require("los.thread")
local tcpc = require("client.tcp")
local irc = require("irc")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(11)

if not tap.ok(caps_of.tcp ~= nil, "the tcp task is running") then
	tap.done()
	return
end

local N = ns.new()

N:mount("/", require("mnt").new(caps_of.esp), "mnt",
    { port = { __right = caps_of.esp } })

local PORT = 17001
local tcp = tcpc.new(caps_of.tcp)
local listener = tcp.listen(PORT)

tap.ok(listener ~= nil, "listening on " .. PORT)

-- a recv with a deadline. tcpc's blocks forever, and a server
-- thread parked in one is a test that never returns from thread.run.
local function recvfor(conn, ms)
	local reply = sys.newport("test_irc.reply")

	sys.send(caps_of.tcp, { op = "recv", connid = conn, maxlen = 2048,
	    reply = { __right = reply } })

	local m, timedout = thread.recvtimeout(reply, ms)

	sys.close(reply)
	if timedout then
		return nil, "timeout"
	end
	return m
end

local saw = {}
local sawtext = {}

local function server()
	local conn = tcp.accept(listener)

	if not conn then
		return
	end

	local reader = irc.reader()
	local welcomed = false

	-- bounded: enough turns for registration, one message and a quit.
	for _ = 1, 40 do
		local data = recvfor(conn, 3000)

		if data == nil then
			break
		end
		reader:feed(data)

		for line in reader:lines() do
			local m = irc.parse(line)

			if m then
				saw[#saw + 1] = m.cmd
				if m.cmd == "PRIVMSG" then
					sawtext[#sawtext + 1] = m.params[2]
				end
				if m.cmd == "USER" and not welcomed then
					welcomed = true
					tcp.send(conn, ":test.server 001 " ..
					    "tester :Welcome\r\n")
					tcp.send(conn, ":friend!u@h PRIVMSG " ..
					    "tester :hello from the server\r\n")
				end
				if m.cmd == "QUIT" then
					tcp.close(conn)
					return
				end
			end
		end
	end
	tcp.close(conn)
end

-- the console: collects what is drawn, answers the size so terminfo
-- does not fall back to its cursor-position probe -- that probe reads
-- keys, and would eat the script below.
local function console(script)
	local port = sys.newport("test_irc")
	local out = {}
	local at = 0

	local function serve()
		while true do
			local m = thread.recv(port)

			if m.op == "stop" then
				return
			elseif m.op == "write" then
				out[#out + 1] = m.data
			elseif m.op == "size" then
				sys.send(m.reply.__right,
				    { cols = 80, rows = 24 })
			elseif m.op == "getch" then
				at = at + 1
				sys.send(m.reply.__right,
				    at <= #script and script:sub(at, at) or "")
			end
		end
	end

	return {
		right = sys.sendright(port),
		serve = serve,
		stop = function()
			sys.send(sys.sendright(port), { op = "stop" })
		end,
		drain = function()
			return table.concat(out)
		end,
	}
end

-- open a window on a channel, say something in it, close it, then
-- close the server window -- which is what quits. Text typed in the
-- server window goes nowhere by design, so the /q comes first.
local con = console("/q #test\rhello there\r/x\r/x\r")
local sh = dos.new({ ns = N, cons = con.right, net = caps_of.tcp })
local status, ran

thread.spawn(con.serve)
thread.spawn(server)
thread.spawn(function()
	status = sh:run("irc -n tester -p " .. PORT .. " 127.0.0.1")
	ran = true
	con.stop()
end)
thread.run()

if not tap.ok(ran, "the client ran to completion") then
	tap.done()
	return
end

local function sent(cmd)
	for _, c in ipairs(saw) do
		if c == cmd then
			return true
		end
	end
	return false
end

tap.ok(sent("NICK") and sent("USER"), "it registered unprompted")
tap.is(status, 0, "and exited 0")
tap.ok(sent("JOIN"), "/q joined the channel")
tap.ok(sent("PRIVMSG"), "a typed line left as a PRIVMSG")
tap.is(sawtext[1], "hello there", "with the text that was typed")
tap.ok(sent("QUIT"), "/x in the server window quit")

local out = con.drain()

-- the nick wears a color of its own, so the escape sequences around it
-- are part of what was drawn. Stripped rather than matched: what this
-- is about is that the line reached the screen attributed to whoever
-- said it, and the color has its own case below.
local plain = out:gsub("\27%[[%d;]*m", "")

tap.ok(plain:find("<friend> hello from the server", 1, true),
    "the server's message reached the screen, attributed")

-- and the nick alone is colored: the color opens before it and the pen
-- goes back to default before the words, so a wrapped message does not
-- tint the rows below it either.
tap.ok(out:find("\27%[9?%d+m<friend>\27%[0m hello"),
    "the nick is colored and the words are not")

tap.done()
