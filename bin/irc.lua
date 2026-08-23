-- irc: an irc client.
--
--   > irc irc.libera.chat
--   > irc -n nick -p 6667 10.0.2.2
--   > irc -j '#lua-os' irc.libera.chat
--
-- One window per target, numbered, as plan 9's chat does it. Commands
-- take chat's spelling:
--
--   /q target       open a window, joining a channel on the way
--   /x [why]        close the window and part; in the server window,
--                   leave the server and exit
--   /n name         change nickname
--   /w [number]     switch windows, or list them
--   /me does a thing
--   /raw LINE       send a line as typed
--
-- Every command is typed. The T-Deck keyboard has letters, digits,
-- Enter and Backspace, and no dependable control key, so the control
-- keys below are extra and nothing needs one.
--
-- Plain text goes to the window's target. The server window has none,
-- so text there goes nowhere: use /raw.
--
-- No TLS on this machine, so the connection is plaintext.

local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")
local getopt = require("getopt")
local irc = require("irc")
local resolv = require("resolv")

local function die(s)
	io.stderr:write("irc: " .. s .. "\n")
	os.exit(1)
end

-- ---- arguments ----

local host, port, nick, join = nil, 6667, nil, {}

-- the iterator, not parse: -j may be given more than once and every
-- channel is wanted, where parse would keep only the last
local optind = 1

for opt, optarg, oi in getopt.opts(arg, "n:p:j:") do
	if opt == "n" then
		nick = optarg
	elseif opt == "p" then
		port = tonumber(optarg)
	elseif opt == "j" then
		join[#join + 1] = optarg
	else
		die("usage: irc [-n nick] [-p port] [-j channel] host")
	end
	optind = oi
end

host = arg[optind]

if not host or not port then
	die("usage: irc [-n nick] [-p port] [-j channel] host")
end

nick = nick or "luaos"

local net = prog.net()

if not net then
	die("no network capability: this shell was lent none")
end

-- ---- the terminal ----

local term = require("ed.terminfo").new()
local tty = prog.tty()

if not term:ok() or not tty then
	die("not a terminal")
end

term:detect_size()

-- ---- windows ----
--
-- One per target, plus the server window at index 1 for everything
-- unaddressed. The scrollback is a bounded ring: unbounded, it is the
-- whole machine on a board with 8MB.
local SCROLLBACK = 200

local wins = { { name = "server", target = nil, lines = {}, dirty = true } }
local cur = 1

local function winfind(target)
	for n = 1, #wins do
		if wins[n].target and irc.same(wins[n].target, target) then
			return n
		end
	end
	return nil
end

local function winmake(target)
	local n = winfind(target)

	if n then
		return n
	end
	wins[#wins + 1] = { name = target, target = target, lines = {},
	    dirty = true }
	return #wins
end

-- ---- color ----
--
-- SGR, which the panel console draws (lib/fbcons.lua) and a host
-- terminal over ssh understands. Held apart from the text rather than
-- written into it: an escape sequence in the string would be counted as
-- width by the wrap below, and a line would break in the wrong place.
local SYSTEM = "90"		-- joins, parts, what this program says
local SERVER = "36"		-- a numeric, or anything unrecognised
local NOTICE = "33"

-- a nick's color, remembered in a table: the same person keeps the same
-- color for as long as the client runs, on every window, which is what
-- makes a busy channel readable at a glance.
--
-- The first choice comes from the name rather than from the rng, so a
-- nick usually lands on the same color across a restart and on two
-- machines watching the same channel. Where that color is already
-- somebody else's the next free one is taken instead -- two people in
-- one window sharing a color is the thing this exists to avoid, and
-- with ten colors and a table it only has to happen when they run out.
--
-- Not 33, 36 or 90: the notices, the server lines and this program's
-- own are those, and a nick wearing one would read as the machine
-- talking.
local NICKCOLORS = {
	"31", "32", "34", "35", "91", "92", "93", "94", "95", "96",
}

local nickcolors = {}		-- nick (lowercased) -> SGR number
local nicktaken = {}		-- SGR number -> the nick holding it

local function nickcolor(name)
	-- irc case folding: Nick and nick are one person, so they are one
	-- color. lib/irc.lua's same() is the same rule.
	local key = name:lower()
	local have = nickcolors[key]

	if have then
		return have
	end

	local h = 0

	for i = 1, #key do
		h = (h * 31 + key:byte(i)) % 65521
	end

	local first = h % #NICKCOLORS

	for k = 0, #NICKCOLORS - 1 do
		local c = NICKCOLORS[(first + k) % #NICKCOLORS + 1]

		if not nicktaken[c] then
			nickcolors[key] = c
			nicktaken[c] = key
			return c
		end
	end

	-- more people than colors: share, starting where the name pointed.
	local c = NICKCOLORS[first + 1]

	nickcolors[key] = c
	return c
end

-- a line, with an optional color over the first `pre` characters of it:
-- the nick in "<nick> what they said" is colored and what they said is
-- not, so the color marks who is talking without tinting the words.
-- With no `pre`, the color covers the whole line.
local function put(w, s, color, pre)
	local lines = wins[w].lines

	lines[#lines + 1] = { s = s, c = color, pre = pre or #s }
	if #lines > SCROLLBACK then
		table.remove(lines, 1)
	end
	wins[w].dirty = true
end

-- everything the server says that is not addressed to a window goes to
-- the server window, rather than being dropped: an irc client that
-- hides what it did not understand is one you cannot debug.
local function say(s, color)
	put(1, s, color or SYSTEM)
end

-- ---- drawing ----
--
-- Assembled whole and written once: a write is a message, as in
-- bin/top.lua.
local input = ""
local buf = {}

-- one stored line as the rows it takes on a screen `cols` wide, appended
-- to `out`. A line is broken at a space where there is one in reach and
-- in the middle of a word where there is not, so a long word cannot
-- stall the wrap. Truncating instead loses the end of what somebody
-- said, which on a 53-column panel is most of a sentence.
--
-- `offs` takes where each row starts in the line it came from, which is
-- what lets the color follow a span of the line across the rows it
-- wrapped onto rather than stopping at the first.
local function wrap(s, cols, out, offs)
	local i, n = 1, #s

	local function piece(from, to)
		out[#out + 1] = s:sub(from, to)
		offs[#offs + 1] = from
	end

	if n == 0 then
		piece(1, 0)
		return
	end
	while i <= n do
		if n - i + 1 <= cols then
			piece(i, n)
			return
		end

		local cut = cols

		-- a break inside a word only where the row holds no space:
		-- the character after the row decides, because a row ending
		-- exactly at a space needs no break at all.
		if s:sub(i + cols, i + cols) ~= " " then
			for p = cols, 2, -1 do
				if s:sub(i + p - 1, i + p - 1) == " " then
					cut = p - 1
					break
				end
			end
		end
		piece(i, i + cut - 1)
		i = i + cut
		while s:sub(i, i) == " " do	-- the space it broke at
			i = i + 1
		end
	end
end

local function draw()
	local rows = term.rows or 24
	local cols = term.cols or 80
	local body = rows - 2
	local w = wins[cur]
	local n = 0

	local function emit(s)
		n = n + 1
		buf[n] = s
	end

	emit("\27[H")

	-- the newest lines, wrapped, oldest first. Walked backwards and
	-- filled from the bottom, because how many rows a line takes is
	-- not known until it is wrapped: a line whose wrapping overflows
	-- the window keeps its end, which is where the sentence finished.
	-- a row is the text plus how much of its head to color. The color
	-- belongs to the first `pre` characters of the LINE, so a row that
	-- wrapped takes whatever part of that span falls on it: a line
	-- colored end to end stays colored to its last row, and a nick
	-- colored at the start of a message that wraps does not tint the
	-- rows below it.
	local shownrows = {}
	local segs, offs = {}, {}

	for k = #w.lines, 1, -1 do
		local line = w.lines[k]

		for j = 1, #segs do
			segs[j], offs[j] = nil, nil
		end
		wrap(line.s, cols, segs, offs)
		for j = #segs, 1, -1 do
			if #shownrows >= body then
				break
			end

			local pre = 0

			if line.c then
				pre = line.pre - (offs[j] - 1)
				if pre < 0 then
					pre = 0
				elseif pre > #segs[j] then
					pre = #segs[j]
				end
			end
			table.insert(shownrows, 1, {
				s = segs[j],
				c = (pre > 0) and line.c or nil,
				pre = pre,
			})
		end
		if #shownrows >= body then
			break
		end
	end

	-- the erase comes first, so a row that fills the width keeps its
	-- last character: erasing after it would erase from the column the
	-- cursor is still owed a wrap from.
	for k = 1, body do
		local r = shownrows[k]

		emit("\27[K")
		if r and r.c then
			local pre = r.pre

			if pre > #r.s then
				pre = #r.s
			end
			emit("\27[" .. r.c .. "m")
			emit(r.s:sub(1, pre))
			emit("\27[0m")
			emit(r.s:sub(pre + 1))
		else
			emit(r and r.s or "")
		end
		emit("\r\n")
	end

	-- the status line: which windows exist, which one this is, and the
	-- nick the server thinks you have. The last of those is not
	-- cosmetic -- a 433 on connect means it is not the one you asked
	-- for.
	local tabs = {}

	for k = 1, #wins do
		local mark = (k == cur) and "*" or " "

		tabs[#tabs + 1] = mark .. k .. ":" .. wins[k].name
	end
	emit("\27[7m")
	-- a column short of the width: the erase after it paints the rest
	-- of the row reversed, and a status line filling the last column
	-- would be cut by that erase instead.
	emit(("[%s] %s"):format(nick, table.concat(tabs, " ")):sub(1,
	    cols - 1))
	emit("\27[K\27[0m\r\n")

	-- the input line, tail-first: a line longer than the terminal
	-- should show what is being typed rather than its beginning.
	local shown = input

	if #shown > cols - 2 then
		shown = shown:sub(#shown - (cols - 3))
	end
	emit("> " .. shown .. "\27[K")

	term:write(table.concat(buf, "", 1, n))
	for k = 1, n do
		buf[k] = nil
	end
end

-- ---- the connection ----

local udp = prog.udp()
local addr = host

if not resolv.quad(addr) then
	local server = resolv.server(prog.ns and prog.ns())
	local got, why = resolv.resolve(udp, host, server)

	if not got then
		die(host .. ": " .. tostring(why))
	end
	addr = got
end

local a, b, c, d = resolv.quad(addr)
local conn = net.dial(a, b, c, d, port)

if not conn then
	die("cannot connect to " .. addr .. ":" .. port)
end

local function send(line)
	net.send(conn, line)
end

-- ---- the event loop ----
--
-- Three ports, one alt: the socket, the keyboard, the clock.
-- sys.timer hands back a port, so the timeout is a case like the rest.
--
-- Both reads are posted by hand: the caps.lua wrappers wait for their
-- own reply, which a program watching two things cannot do.
local sockport = sys.newport("irc.sockport")
local keyport = sys.newport("irc.keyport")
local reader = irc.reader()

local function postrecv()
	sys.send(net.handle, { op = "recv", connid = conn, maxlen = 2048,
	    reply = { __right = sockport } })
end

local function postkey()
	sys.send(tty.handle, { op = "getch",
	    reply = { __right = keyport } })
end

-- silence before we ask whether the server is still there, for a
-- connection that has gone away without saying so.
local IDLE_MS = 120000
-- and before then, while the server has yet to say anything at all: a
-- registration that never finishes is a screen that says "connecting"
-- and nothing else, and that is worth naming rather than waiting out.
local REGISTER_MS = 15000
local pinged = false
local toldnotimer = false

local running = true
local registered = false

local function quit(why)
	send(irc.quit(why or "lua-os"))
	running = false
end

-- ---- what arrives ----

local function onmsg(m)
	local cmd = m.cmd

	if cmd == "PING" then
		-- a server drops a client that does not answer.
		send(irc.pong(m.params[1] or ""))
		return
	end

	if cmd == "PONG" then
		pinged = false
		return
	end

	if cmd == irc.RPL_WELCOME then
		registered = true
		nick = m.params[1] or nick
		say("* registered as " .. nick)
		for _, ch in ipairs(join) do
			send(irc.join(ch))
		end
		return
	end

	if cmd == irc.ERR_NICKNAMEINUSE then
		-- take a nearby name rather than sit unregistered, which
		-- is a connection that can do nothing.
		local alt = nick .. tostring(sys.uptime_ms() % 100)

		say("* " .. nick .. " is taken, trying " .. alt)
		nick = alt
		send(irc.nick(alt))
		return
	end

	if cmd == "PRIVMSG" or cmd == "NOTICE" then
		local target, text = m.params[1], m.params[2] or ""
		local from = m.nick or m.prefix or "?"
		-- a message to a channel belongs to that channel's window; a
		-- message to us belongs to the sender's.
		local w = irc.ischannel(target) and winfind(target) or
		    winfind(from)
		local verb, arg = irc.isctcp(text)

		if verb == "ACTION" then
			-- the whole line is the action, so the whole line
			-- takes the color: there is no "<nick>" to mark.
			put(w or 1, ("* %s %s"):format(from, arg or ""),
			    nickcolor(from))
		elseif verb then
			-- a ctcp we do not answer is still worth seeing.
			put(w or 1, ("[ctcp %s from %s]"):format(verb, from),
			    SYSTEM)
		elseif cmd == "NOTICE" then
			put(w or 1, ("-%s- %s"):format(from, text), NOTICE,
			    #from + 2)
		else
			put(w or 1, ("<%s> %s"):format(from, text),
			    nickcolor(from), #from + 2)
		end
		return
	end

	if cmd == "JOIN" then
		local ch = m.params[1]

		if irc.same(m.nick, nick) then
			put(winmake(ch), "* joined " .. ch, SYSTEM)
		else
			local w = winfind(ch)

			if w then
				put(w, ("* %s joined"):format(m.nick or "?"), SYSTEM)
			end
		end
		return
	end

	if cmd == "PART" or cmd == "QUIT" then
		local who = m.nick or "?"
		local ch = m.params[1]
		local w = ch and winfind(ch)

		if w and not irc.same(who, nick) then
			put(w, ("* %s left"):format(who), SYSTEM)
			return
		end
		if cmd == "QUIT" then
			-- a quit names no channel, so it goes wherever the
			-- person is known.
			for k = 2, #wins do
				if irc.same(wins[k].target, who) then
					put(k, ("* %s quit"):format(who), SYSTEM)
				end
			end
			return
		end
	end

	-- everything else, in the server window, the way plan 9's chat
	-- prints its catch-all: the prefix and then the parameters, which
	-- is enough to read a numeric without a table of them.
	local parts = {}

	for k = 2, #m.params do
		parts[#parts + 1] = m.params[k]
	end
	say(("%s %s"):format(cmd, table.concat(parts, " ")), SERVER)
end

-- ---- what is typed ----

-- the window list, for /w with no argument. Printed rather than only
-- shown in the status line, which truncates: on a 53-column panel the
-- tabs run off the end as soon as there are three of them.
local function listwins()
	for k = 1, #wins do
		say(("%s%d %s"):format(k == cur and "*" or " ", k,
		    wins[k].name))
	end
end

local function docommand(line)
	local word, rest = line:match("^/(%S+)%s*(.*)$")

	if not word then
		return
	end
	word = word:lower()

	-- /2 as a shorthand for /w 2: the thing done most often, in the
	-- fewest keys, on a keyboard where every key costs.
	if word:match("^%d+$") then
		word, rest = "w", word
	end

	if word == "q" or word == "query" or word == "join" or word == "j" then
		if rest == "" then
			say("* /q target")
		else
			if irc.ischannel(rest) then
				send(irc.join(rest))
			end
			cur = winmake(rest)
		end
	elseif word == "x" or word == "close" or word == "part" then
		local w = wins[cur]

		if not w.target then
			-- the server window is the connection: closing it
			-- is leaving, which is what chat does too.
			quit(rest ~= "" and rest or nil)
		else
			if irc.ischannel(w.target) then
				send(irc.part(w.target, rest ~= "" and rest
				    or nil))
			end
			table.remove(wins, cur)
			cur = 1
		end
	elseif word == "n" or word == "nick" then
		if rest == "" then
			say("* /n name")
		else
			send(irc.nick(rest))
		end
	elseif word == "w" or word == "win" then
		local n = tonumber(rest)

		if not n then
			listwins()
		elseif wins[n] then
			cur = n
		else
			say("* no window " .. rest)
		end
	elseif word == "me" then
		local w = wins[cur]

		if w.target then
			send(irc.action(w.target, rest))
			put(cur, ("* %s %s"):format(nick, rest), nickcolor(nick))
		end
	elseif word == "raw" then
		if rest ~= "" then
			send(rest .. "\r\n")
		end
	else
		say("* no such command: /" .. word)
	end
end

local function online(line)
	if line == "" then
		return
	end
	if line:sub(1, 1) == "/" then
		docommand(line)
		return
	end

	local w = wins[cur]

	if not w.target then
		-- the server window has nowhere to send to, and guessing a
		-- channel would put a mistyped command in front of people.
		say("* no target here; use /q, /w or /raw")
		return
	end
	send(irc.privmsg(w.target, line))
	put(cur, ("<%s> %s"):format(nick, line),
	    nickcolor(nick), #nick + 2)
end

-- one keystroke. Raw mode, so this is the whole line editor: the
-- console's own hands back a finished line, and this program cannot
-- block waiting for one. Enter, Backspace and printable characters are
-- all it needs; the control keys are extra.
local function onkey(k)
	if k == "\r" or k == "\n" then
		local line = input

		input = ""
		online(line)
	elseif k == "\8" or k == "\127" then
		input = input:sub(1, #input - 1)
	elseif k == "\21" then			-- ctrl-u, or backspace held
		input = ""
	elseif k == "\14" then			-- ctrl-n, or /w n+1
		cur = cur % #wins + 1
	elseif k == "\16" then			-- ctrl-p, or /w n-1
		cur = (cur - 2) % #wins + 1
	elseif k == "\3" then			-- ctrl-c, or /x
		quit()
	elseif k == "\27" then
		-- an escape sequence: read it to its end and ignore it, so
		-- the tail of an arrow key is not typed into the line.
		-- lib/console.lua does the same for the same reason.
		local c2 = tty.getch(50)

		if c2 == "[" or c2 == "O" then
			repeat
				local c3 = tty.getch(50)
			until c3 == "" or c3 == nil or c3:match("[@-~]")
		end
	elseif #k == 1 and k >= " " then
		input = input .. k
	end
end

-- ---- run ----

term:raw()
term:clear()

send(irc.nick(nick))
send(irc.user(nick, "lua-os"))
say("* connecting to " .. addr .. ":" .. port .. " as " .. nick)

postrecv()
postkey()
draw()

local ok, err = xpcall(function()
	while running do
		-- a short wait until the server has spoken, the long one
		-- after. A connection that is up and silent is the failure
		-- that looks like nothing at all: the socket is fine, the
		-- program is waiting, and the screen says "connecting"
		-- forever. Saying so does not mend it, but it tells the two
		-- apart from where you are sitting.
		local timer = sys.timer(registered and IDLE_MS or REGISTER_MS)
		local cases = { { port = sockport }, { port = keyport } }

		if timer then
			cases[3] = { port = timer }
		elseif not toldnotimer then
			toldnotimer = true
			say("* no timer left: the idle check is off")
		end

		local which, m = thread.alt(cases)

		if timer then
			sys.close(timer)
		end

		if which == 1 then
			if m == nil then
				say("* disconnected")
				running = false
			else
				reader:feed(m)
				for line in reader:lines() do
					local msg = irc.parse(line)

					if msg then
						onmsg(msg)
					else
						say("? " .. line)
					end
				end
				postrecv()
			end
		elseif which == 2 then
			if m == "" or m == nil then
				-- the terminal went away
				running = false
			else
				onkey(m)
				postkey()
			end
		elseif not registered then
			-- the connection came up and the server has said
			-- nothing. Not an error yet -- a server checking
			-- ident with nowhere to check it can take this long
			-- -- so this waits on, having said where it is.
			say("* connected, but the server has not spoken in " ..
			    (REGISTER_MS // 1000) .. "s")
		else
			-- nothing from the server for a long time. Ask once;
			-- a second silence means the connection is gone
			-- whatever the socket believes.
			if pinged then
				say("* no answer; disconnected")
				running = false
			else
				pinged = true
				send(irc.ping("luaos"))
			end
		end

		if running then
			draw()
		end
	end
end, function(e)
	return debug.traceback(tostring(e), 2)
end)

net.close(conn)
term:show_cursor()
term:restore()
term:clear()

if not ok then
	die(tostring(err))
end
