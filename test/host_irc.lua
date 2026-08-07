#!/usr/bin/env lua5.4
-- lib/irc.lua on the host: lines in, messages out, and back again.
--
-- The library is sans-io, so every case here is a string written down
-- rather than a connection arranged. That is the point of the split:
-- the awkward lines -- a prefix with no user, a trailing parameter that
-- is empty, a tag whose value holds the separator it is separated by --
-- are all reachable as data, and none of them is easy to make a real
-- server send.
--
-- Two properties get most of the attention. A line that goes out must
-- be one line, whatever a user typed into it; and a line that comes
-- back must parse to what it was built from.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local irc = require("irc")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
	return cond
end

local function is(got, want, name)
	if not ok(got == want, name) then
		io.write(("# got %q, want %q\n"):format(tostring(got),
		    tostring(want)))
	end
end

-- ---- parsing ----

do
	local m = irc.parse(":nick!user@host PRIVMSG #chan :hello there")

	is(m.cmd, "PRIVMSG", "command")
	is(m.nick, "nick", "nick out of the prefix")
	is(m.user, "user", "user out of the prefix")
	is(m.host, "host", "host out of the prefix")
	is(m.params[1], "#chan", "target")
	is(m.params[2], "hello there", "the trailing parameter keeps its spaces")
	is(#m.params, 2, "and is the last parameter, not a field of its own")
end

do
	-- a server prefix has no ! or @, and the whole of it is the name.
	local m = irc.parse(":irc.example.org 001 me :Welcome")

	is(m.cmd, "001", "a numeric stays three characters")
	is(m.nick, "irc.example.org", "a server prefix reads as the name")
	is(m.user, nil, "with no user")
	is(m.params[2], "Welcome", "and its text")
end

do
	local m = irc.parse("PING :12345")

	is(m.cmd, "PING", "a line with no prefix")
	is(m.prefix, nil, "has none")
	is(m.params[1], "12345", "and its token")
end

do
	-- the trailing colon is what makes an empty parameter possible at
	-- all, and QUIT with no reason is the common case of it.
	local m = irc.parse(":a!b@c QUIT :")

	is(m.params[1], "", "an empty trailing parameter survives")
	is(#m.params, 1, "as a parameter")
end

do
	-- a colon inside the trailing text is text, not another marker.
	local m = irc.parse(":a!b@c PRIVMSG #x :see: this")

	is(m.params[2], "see: this", "a colon inside the trailing text is text")
end

do
	-- middle parameters and a trailing one together, which is where a
	-- parser that splits on every colon goes wrong.
	local m = irc.parse(":s 353 me = #chan :alice bob carol")

	is(m.params[3], "#chan", "middles before the trailing parameter")
	is(m.params[4], "alice bob carol", "and the names after it")
	is(#m.params, 4, "four parameters")
end

do
	local m = irc.parse("@id=123;flag :a!b@c PRIVMSG #x :hi")

	is(m.tags and m.tags.id, "123", "a tag with a value")
	is(m.tags and m.tags.flag, true, "a tag without one is present, not empty")
	is(m.cmd, "PRIVMSG", "and the message parses past them")
end

do
	-- ; and space cannot appear raw in a tag value, so they arrive
	-- escaped and have to come back.
	local m = irc.parse("@k=a\\sb\\:c PING :x")

	is(m.tags and m.tags.k, "a b;c", "tag escapes are undone")
end

do
	is(irc.parse(""), nil, "an empty line is not a message")
	is(irc.parse(":prefix-only"), nil, "a prefix with no command is not one either")
	ok(irc.parse("PING x\r\n") ~= nil, "framing is tolerated on the end")
end

-- ---- formatting ----

is(irc.privmsg("#chan", "hello there"),
    "PRIVMSG #chan :hello there\r\n", "a message with spaces gets its colon")
is(irc.privmsg("#chan", "hello"),
    "PRIVMSG #chan hello\r\n", "and one without does not")
is(irc.join("#chan"), "JOIN #chan\r\n", "join")
is(irc.join("#chan", "secret"), "JOIN #chan secret\r\n",
    "join with a key, which is a middle parameter")
is(irc.part("#chan", "bye now"), "PART #chan :bye now\r\n",
    "part with a reason, which is a trailing one")
is(irc.user("me", "Me Myself"), "USER me 0 * :Me Myself\r\n", "user")
is(irc.pong("12345"), "PONG 12345\r\n", "pong")
is(irc.quit(), "QUIT :\r\n", "quit with no reason still has the parameter")

-- the injection case, and the reason clean() exists: a user typing a
-- newline must not be able to send a second command.
do
	local line = irc.privmsg("#chan", "hi\r\nQUIT :owned")

	is(line, "PRIVMSG #chan :hiQUIT :owned\r\n",
	    "CR and LF are cut out of a parameter")
	is(select(2, line:gsub("\r\n", "")), 1, "so one call is one line")
end

do
	local line = irc.line("JOIN", "#a\r\nPART #b")

	is(select(2, line:gsub("\r\n", "")), 1,
	    "a channel name cannot carry a second command either")
end

-- ---- round trip ----
--
-- What goes out parses back to what it was built from, which is the
-- property that keeps the two halves honest about each other.
do
	local cases = {
		{ "PRIVMSG", "#chan", "hello there" },
		{ "PRIVMSG", "nick", "one" },
		{ "TOPIC", "#chan", "a: b c" },
		{ "PART", "#chan", "" },
		{ "MODE", "#chan", "+o", "someone" },
	}

	for _, c in ipairs(cases) do
		local line = irc.line(table.unpack(c))
		local m = irc.parse(line)
		local same = m and m.cmd == c[1] and #m.params == #c - 1

		if same then
			for i = 2, #c do
				if m.params[i - 1] ~= c[i] then
					same = false
				end
			end
		end
		ok(same, "round trip: " .. table.concat(c, " ", 1, 2))
	end
end

-- ---- casemapping ----

ok(irc.same("#Foo", "#foo"), "channels compare without case")
ok(irc.same("Nick[a]", "nick{a}"), "and [] compares equal to {} (rfc1459)")
ok(not irc.same("alice", "bob"), "different names do not")
ok(irc.ischannel("#chan") and irc.ischannel("&local") and
    irc.ischannel("+modeless"), "the channel prefixes")
ok(not irc.ischannel("nick"), "a nick is not a channel")

-- ---- ctcp ----

do
	local line = irc.action("#chan", "waves")
	local m = irc.parse(line)
	local verb, arg = irc.isctcp(m.params[2])

	is(verb, "ACTION", "an action is ctcp")
	is(arg, "waves", "with its text")
	is(irc.isctcp("ordinary text"), nil, "ordinary text is not")
end

-- ---- framing ----

do
	local r = irc.reader()

	-- one read holding one and a half lines, which is the case a
	-- client meets on its first packet and never stops meeting.
	r:feed("PING :one\r\nPRIV")
	is(r:next(), "PING :one", "a whole line comes out")
	is(r:next(), nil, "the half line waits")

	r:feed("MSG #x :hi\r\n")
	is(r:next(), "PRIVMSG #x :hi", "and completes on the next read")
	is(r:next(), nil, "then there is nothing")
end

do
	local r = irc.reader()

	r:feed("a\r\nb\r\nc\r\n")
	is(r:next(), "a", "three lines in one read: first")
	is(r:next(), "b", "second")
	is(r:next(), "c", "third")
	is(r:next(), nil, "and no more")
end

do
	local r = irc.reader()
	local n = 0

	r:feed("one\r\n\r\ntwo\r\n")
	for _ in r:lines() do
		n = n + 1
	end
	is(n, 2, "an empty line between two is skipped rather than returned")
end

do
	-- a server that never sends a newline must not be able to grow
	-- this without bound.
	local r = irc.reader(64)

	r:feed(string.rep("x", 100))
	is(r:next(), nil, "an overlong line is dropped")
	is(r.dropped, 1, "and counted")

	r:feed("PING :after\r\n")
	is(r:next(), "PING :after", "and the reader keeps working afterwards")
end

io.write(("1..%d\n"):format(count))
if failed > 0 then
	io.write(("# %d of %d failed\n"):format(failed, count))
	os.exit(1)
end
