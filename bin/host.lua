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
-- The asking is lib/resolv.lua, shared with bin/irc.lua. What is left
-- here is the argument handling and where to report.

local unistd = require("posix.unistd")
local prog = require("prog")
local resolv = require("resolv")

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

-- already an address: say so and ask nobody. `host 1.2.3.4` otherwise
-- sends a query whose answer is its own question.
if resolv.quad(name) then
	unistd.write(1, name .. "\n")
	os.exit(0)
end

local udp = prog.udp()

if not udp then
	die("no udp capability: this shell was lent none")
end

server = server or resolv.server(prog.ns and prog.ns())
if not server then
	die("no resolver: /net/dns is unreadable, and none was named")
end

local answer, why = resolv.resolve(udp, name, server)

if not answer then
	die(name .. ": " .. tostring(why))
end
unistd.write(1, answer .. "\n")
