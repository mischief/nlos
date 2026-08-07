-- host: turn a name into an address.
--
--   > host example.com
--   > host example.com 1.1.1.1      ask that server instead
--
-- The repl has `resolve(name)`, which spends a right to the dns task.
-- This asks a server directly over udp, so it works on a machine where
-- nothing started task/dns.lua, and it can be pointed at a server that
-- is not the machine's own -- which is most of what the command is for.
--
-- Where to ask comes from /net/dns, one address per line, served by
-- lib/dhcpd.lua from the lease. No capability and nothing told to us at
-- spawn: the resolver is a file, which is the whole argument for the
-- lease being a filesystem. See task/dns.lua, which reads the same file.

local unistd = require("posix.unistd")
local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")
local dns = require("dns")

local function die(s)
	unistd.write(2, "host: " .. s .. "\n")
	os.exit(1)
end

local name, server

for _, a in ipairs(arg) do
	if a:sub(1, 1) == "-" and #a > 1 then
		die("usage: host name [server]")
	elseif not name then
		name = a
	elseif not server then
		server = a
	else
		die("usage: host name [server]")
	end
end

if not name then
	die("usage: host name [server]")
end

local function quad(s)
	local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

	if not a then
		return nil
	end
	return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

-- already an address: say so and ask nobody. `host 1.2.3.4` otherwise
-- sends a query whose answer is its own question.
if quad(name) then
	unistd.write(1, name .. "\n")
	os.exit(0)
end

local udp = prog.udp()

if not udp then
	die("no udp capability: this shell was lent none")
end

if not server then
	local ns = prog.ns and prog.ns()
	local txt = ns and ns:readfile("/net/dns")

	server = txt and txt:match("^%s*([%d%.]+)")
	if not server then
		die("no resolver: /net/dns is unreadable, " ..
		    "and none was named")
	end
end

local sa, sb, sc, sd = quad(server)

if not sa then
	die("not an address: " .. server)
end

-- a source port that is not 53 and is not the same every time, for the
-- reason lib/dnsc.lua gives: it costs nothing not to hand the number to
-- whatever is watching.
local conn = udp.open(20000 + (os.time() % 10000))

if not conn then
	die("cannot open a udp port")
end

-- udp is lossy in a way tcp is not: a query or its reply can vanish and
-- the only evidence is silence. So ask more than once, and let the id
-- decide whether an answer is ours -- a late reply to a previous
-- question is otherwise an answer to this one.
--
-- caps.udp's recv blocks with no deadline, so the wait is posted by
-- hand against a port of our own and timed with thread.recvtimeout.
-- The cancel afterwards is not optional: without it the abandoned recv
-- stays pending in the ip task for good. task/dns.lua does the same
-- three things for the same reasons.
local TIMEOUT_MS = 1000
local TRIES = 3
local id = 1 + (os.time() % 65534)
local query = dns.build_query(name, id)
local answer, why

for _ = 1, TRIES do
	local replyport = sys.newport()

	sys.send(udp.handle, { op = "recv", connid = conn, maxlen = 512,
	    reply = { __right = replyport } })

	if not udp.send(conn, sa, sb, sc, sd, dns.PORT, query) then
		sys.send(udp.handle, { op = "cancel", connid = conn })
		thread.recv(replyport)
		sys.close(replyport)
		why = "send failed"
		break
	end

	local m, timedout = thread.recvtimeout(replyport, TIMEOUT_MS)

	if timedout == nil then
		sys.close(replyport)
		if type(m) == "table" and m.data then
			local ip, err = dns.parse(m.data, id)

			if ip then
				answer = ip
				break
			end
			why = err
		end
	else
		sys.send(udp.handle, { op = "cancel", connid = conn })
		thread.recv(replyport)
		sys.close(replyport)
		why = why or "no reply"
	end
end

udp.close(conn)

if not answer then
	die(name .. ": " .. tostring(why or "no reply"))
end
unistd.write(1, answer .. "\n")
