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

local prog = require("prog")
local getopt = require("getopt")
local resolv = require("resolv")

local function die(s)
	io.stderr:write("host: " .. s .. "\n")
	os.exit(1)
end

-- no options, but parse for the "--" and the refusal of anything else
local flags, optind = getopt.parse(arg, "")

if not flags or #arg - optind + 1 > 2 then
	die("usage: host name [server]")
end

local name, server = arg[optind], arg[optind + 1]

if not name then
	die("usage: host name [server]")
end

-- already an address: say so and ask nobody. `host 1.2.3.4` otherwise
-- sends a query whose answer is its own question.
if resolv.quad(name) then
	io.write(name .. "\n")
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
io.write(answer .. "\n")
