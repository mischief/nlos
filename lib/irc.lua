-- irc: the protocol, and nothing else.
--
-- Sans-io, the way lib/dns.lua and lib/ntp.lua are: this turns bytes
-- into messages and messages into bytes and never touches a
-- capability. Whoever holds the socket does the reading -- see
-- bin/irc.lua, which is the client this exists for.
--
-- The split is worth having beyond tidiness. A parser with no socket
-- can be tested against a table of lines under the host's own lua,
-- which is what test/irc-protocol.lua does: no guest, no network, and
-- every awkward line the wire can carry written down as data.
--
-- RFC 1459 with the parts of IRCv3 a client meets whether it asked for
-- them or not: message tags arrive from any server that has them,
-- unasked, and a parser that chokes on an "@" is a parser that fails on
-- connection.

local irc = {}

-- A classic line is 512 bytes including CRLF. Tags are counted
-- separately and bounded separately (IRCv3 message-tags), which is why
-- these are two numbers and not one.
irc.MAXLINE = 512
irc.MAXTAGS = 8191

-- ---- case ----
--
-- Nicks and channels compare case-insensitively, and not the way ascii
-- does it: RFC 1459 calls {}|^ the lowercase of []\~, because IRC came
-- from a scandinavian view of the alphabet. A client that uses ordinary
-- lowercasing has two windows for one channel the first time somebody
-- writes #Foo[bar].
--
-- rfc1459 rather than strict-rfc1459 (which excludes ~/^): it is what
-- the servers people actually use report in their CASEMAPPING.
local LOWER = {}

do
	for b = string.byte("A"), string.byte("Z") do
		LOWER[string.char(b)] = string.char(b + 32)
	end
	LOWER["["] = "{"
	LOWER["]"] = "}"
	LOWER["\\"] = "|"
	LOWER["~"] = "^"
end

function irc.lower(s)
	return (s:gsub("[A-Z%[%]\\~]", LOWER))
end

-- whether two names are the same name.
function irc.same(a, b)
	if a == nil or b == nil then
		return false
	end
	return irc.lower(a) == irc.lower(b)
end

-- a channel is anything starting with one of these. Four prefixes, not
-- one: & is a server-local channel, + is modeless, ! is safe-channel.
-- A client that only knows # puts a channel's traffic in a query
-- window.
function irc.ischannel(s)
	return type(s) == "string" and s:match("^[#&+!]") ~= nil
end

-- ---- tags ----
--
-- The escaping is its own small language (IRCv3 message-tags): ; and
-- space cannot appear raw in a value, so they travel as \: and \s. A
-- backslash before anything else is dropped, which is the spec's rule
-- and not an oversight.
local TAGESC = {
	[":"] = ";", ["s"] = " ", ["\\"] = "\\",
	["r"] = "\r", ["n"] = "\n",
}

local function untag(v)
	return (v:gsub("\\(.)", function(c)
		return TAGESC[c] or c
	end))
end

local function parsetags(s)
	local t = {}

	for item in s:gmatch("[^;]+") do
		local k, v = item:match("^([^=]+)=(.*)$")

		if k then
			t[k] = untag(v)
		else
			-- a tag with no = is present rather than empty, and
			-- the difference matters to anything testing for it.
			t[item] = true
		end
	end
	return t
end

-- ---- parsing ----
--
-- [@tags] [:prefix] COMMAND [params] [:trailing]
--
-- The trailing parameter is returned as the last of params rather than
-- a field of its own. It is the last parameter -- the colon says where
-- it starts, not what it means -- and a client that reads params[2] for
-- the text of a PRIVMSG should not have to know which spelling the
-- sender chose for a word with no spaces in it.
--
-- Returns nil and a reason for a line that is not one. Reasons are for
-- a log, not for a user: a server sending junk is a server bug, and the
-- client's job is to keep reading.
function irc.parse(line)
	if type(line) ~= "string" then
		return nil, "not a string"
	end

	-- CR and LF are the framing, and a parser that tolerates them
	-- inside a line disagrees with the reader below about where a
	-- message ends.
	line = line:gsub("[\r\n]+$", "")

	local msg = { params = {} }
	local rest = line

	if rest:sub(1, 1) == "@" then
		local tags, after = rest:match("^@(%S*)%s+(.*)$")

		if not tags then
			return nil, "tags with no message"
		end
		msg.tags = parsetags(tags)
		rest = after
	end

	if rest:sub(1, 1) == ":" then
		local prefix, after = rest:match("^:(%S*)%s+(.*)$")

		if not prefix then
			return nil, "prefix with no command"
		end
		msg.prefix = prefix
		rest = after

		-- nick!user@host, or a server name. The nick is what a
		-- client shows and what it compares against, so it is split
		-- here rather than in every caller.
		local nick, user, host = prefix:match("^([^!]+)!([^@]+)@(.+)$")

		if nick then
			msg.nick, msg.user, msg.host = nick, user, host
		else
			msg.nick = prefix:match("^([^!@]+)")
		end
	end

	local cmd, after = rest:match("^(%S+)%s*(.*)$")

	if not cmd then
		return nil, "no command"
	end

	-- Upper case, which is what the wire uses and what every
	-- comparison in a client then reads as. Numerics stay the three
	-- characters they arrived as: "001" is a string, and turning it
	-- into a number loses the leading zero that makes it one.
	msg.cmd = cmd:upper()
	rest = after

	while #rest > 0 do
		if rest:sub(1, 1) == ":" then
			msg.params[#msg.params + 1] = rest:sub(2)
			break
		end

		local p, after2 = rest:match("^(%S+)%s*(.*)$")

		if not p then
			break
		end
		msg.params[#msg.params + 1] = p
		rest = after2
	end

	return msg
end

-- ---- formatting ----

-- A parameter cannot carry CR, LF or NUL: the first two end the line
-- and everything after them is read as another command. That is command
-- injection through anything a user types -- a nick, a channel, the
-- text of a message -- so it is cut here, in the one place every
-- outbound line goes through, rather than trusted to each caller.
local function clean(s)
	return (tostring(s):gsub("[%z\r\n]", ""))
end

-- format(msg) -> the line, CRLF included.
--
-- The colon goes on the last parameter when it needs one: it is empty,
-- it holds a space, or it starts with a colon itself. Adding it always
-- would be legal and is what many clients do; adding it only when it is
-- needed makes the wire read like the wire, which matters when the
-- thing you are debugging with is a packet trace.
function irc.format(msg)
	local out = {}

	if msg.prefix then
		out[#out + 1] = ":" .. clean(msg.prefix)
	end
	out[#out + 1] = clean(msg.cmd):upper()

	local params = msg.params or {}

	for i = 1, #params do
		local p = clean(params[i])

		if i == #params and
		    (p == "" or p:find(" ", 1, true) or p:sub(1, 1) == ":") then
			out[#out + 1] = ":" .. p
		else
			out[#out + 1] = p
		end
	end

	return table.concat(out, " ") .. "\r\n"
end

-- the same thing for a caller with the parts to hand rather than a
-- table: irc.line("PRIVMSG", "#chan", "hello there").
function irc.line(cmd, ...)
	return irc.format({ cmd = cmd, params = { ... } })
end

-- ---- the commands a client sends ----
--
-- One function each, rather than the caller writing irc.line() with a
-- string: the argument order of USER is not memorable, PART takes its
-- reason as a trailing parameter and JOIN takes its key as a middle
-- one, and every client gets one of those wrong once.

function irc.nick(n)
	return irc.line("NICK", n)
end

-- mode 0, and the unused * where RFC 1459 had a hostname: the server
-- reads it from the connection and has ignored this field for decades.
function irc.user(u, realname)
	return irc.line("USER", u, "0", "*", realname or u)
end

function irc.pass(p)
	return irc.line("PASS", p)
end

function irc.join(chan, key)
	if key then
		return irc.line("JOIN", chan, key)
	end
	return irc.line("JOIN", chan)
end

function irc.part(chan, why)
	if why then
		return irc.line("PART", chan, why)
	end
	return irc.line("PART", chan)
end

function irc.privmsg(target, text)
	return irc.line("PRIVMSG", target, text)
end

function irc.notice(target, text)
	return irc.line("NOTICE", target, text)
end

function irc.quit(why)
	return irc.line("QUIT", why or "")
end

function irc.ping(token)
	return irc.line("PING", token)
end

-- the answer a connection lives or dies by. A server pings an idle
-- client and drops it when nothing comes back, so this is the one
-- message a client must send without being asked.
function irc.pong(token)
	return irc.line("PONG", token)
end

-- ---- ctcp ----
--
-- A layer above PRIVMSG, wrapped in \1: ACTION is /me, and VERSION,
-- PING and TIME are the ones a client is asked and should answer.

local SOH = "\1"

function irc.ctcp(target, verb, arg)
	local body = arg and (verb .. " " .. arg) or verb

	return irc.privmsg(target, SOH .. body .. SOH)
end

function irc.action(target, text)
	return irc.ctcp(target, "ACTION", text)
end

-- unwrap the text of a PRIVMSG, or nil where it is not ctcp at all.
-- Returns the verb and whatever followed it.
function irc.isctcp(text)
	if type(text) ~= "string" then
		return nil
	end

	-- the closing \1 is optional in practice: enough clients leave it
	-- off that requiring it loses messages.
	local body = text:match("^\1([^\1]*)\1?$")

	if not body then
		return nil
	end

	local verb, arg = body:match("^(%S+)%s*(.*)$")

	return verb and verb:upper() or "", arg
end

-- ---- framing ----
--
-- A stream is not a sequence of messages: one read can hold half a line
-- or three and a half. This keeps the tail between reads.
--
-- Bounded on purpose. A server that never sends a newline would
-- otherwise grow this without limit, which on a board with 8MB is the
-- whole machine rather than one program -- so a line that cannot be a
-- line is dropped and said so.
local Reader = {}

Reader.__index = Reader

function irc.reader(limit)
	return setmetatable({
		pending = "",
		limit = limit or (irc.MAXTAGS + irc.MAXLINE),
		dropped = 0,
	}, Reader)
end

-- takes a string, or a los.buf: buffers are spreading through the
-- stack (lib/ip4.lua takes one now), and a reader that only knew about
-- strings would be the reason a socket could not hand one over.
function Reader:feed(chunk)
	if chunk == nil then
		return
	end
	if type(chunk) ~= "string" then
		chunk = chunk:str()
	end
	self.pending = self.pending .. chunk

	if #self.pending > self.limit then
		self.pending = ""
		self.dropped = self.dropped + 1
	end
end

-- the next complete line, or nil when there is not one yet.
--
-- Empty lines are skipped rather than returned: a server that ends
-- lines with CRLF and starts the next with nothing in between is
-- common enough, and an empty line parses to nothing anyway.
function Reader:next()
	while true do
		local i = self.pending:find("\n", 1, true)

		if not i then
			return nil
		end

		local line = self.pending:sub(1, i - 1):gsub("\r$", "")

		self.pending = self.pending:sub(i + 1)
		if #line > 0 then
			return line
		end
	end
end

-- for a loop: for line in r:lines() do ... end
function Reader:lines()
	return function()
		return self:next()
	end
end

-- ---- the numerics a client acts on ----
--
-- Not a table of all of them. These are the ones with behaviour behind
-- them: a client that does not know 433 cannot connect twice from the
-- same machine, and one that does not know 001 does not know when it
-- may join anything.
irc.RPL_WELCOME = "001"
irc.RPL_ISUPPORT = "005"
irc.RPL_TOPIC = "332"
irc.RPL_NAMREPLY = "353"
irc.RPL_ENDOFNAMES = "366"
irc.RPL_MOTD = "372"
irc.RPL_ENDOFMOTD = "376"
irc.ERR_NOMOTD = "422"
irc.ERR_NICKNAMEINUSE = "433"
irc.ERR_NOTREGISTERED = "451"

return irc
