-- gemini: fetch a gemini:// page and print it.

--   > gemini gemini://geminiprotocol.net/
--   > gemini -i gemini://example.org/         (with the status line)
--   > gemini -r gemini://example.org/x.png    (the bytes, unrendered)
--   > gemini -w 40 gemini://example.org/ | p

-- The protocol is lib/gemini.lua, which owns no capability and rides
-- whichever the caller holds. This program holds the tcp task, lent by
-- the shell the same way the screen is.

-- Rendered by default: gemtext is wrapped to the width and its links
-- are numbered, so a page reads and a link can be named. -r turns that
-- off, which is what anything not text wants.

local unistd = require("posix.unistd")
local prog = require("prog")
local gemini = require("gemini")

local function die(s)
	unistd.write(2, "gemini: " .. s .. "\n")
	os.exit(1)
end

local function usage()
	unistd.write(2, "usage: gemini [-ir] [-w cols] url\n")
	os.exit(2)
end

local showhead, raw, cols, url = false, false, 80, nil
local i = 1

while i <= #arg do
	local a = arg[i]

	if a == "-i" then
		showhead = true
	elseif a == "-r" then
		raw = true
	elseif a == "-w" then
		i = i + 1
		cols = tonumber(arg[i]) or usage()
	elseif a:sub(1, 1) == "-" and #a > 1 then
		usage()
	else
		url = url or a
	end
	i = i + 1
end

if not url then
	usage()
end

-- a bare host is a url with the scheme left off, which is what anyone
-- types first. There is only the one scheme to mean.
if not url:match("^%a+://") then
	url = "gemini://" .. url
end

local net = prog.net()

if not net then
	die("no network capability: this shell was lent none")
end

local opts = {
	rand = prog.rand(),
	-- the key is printed, not checked: nothing on this machine
	-- remembers one yet, so first use is every use.
	onkey = function(h, fp)
		unistd.write(2, ("gemini: %s is %s\n"):format(h, fp))
	end,
	onredirect = function(from, to, status)
		unistd.write(2, ("gemini: %d %s -> %s\n"):format(status,
		    from, to))
	end,
}

if not opts.rand then
	die("no entropy: this shell was lent no seed, and tls needs one")
end

-- Held rather than streamed when it is a page: wrapping needs the
-- whole of a line, and the numbering needs the whole of the document.
-- -r streams, which is what a caller piping bytes somewhere asked for.
if raw then
	opts.sink = function(part)
		unistd.write(1, part)
		return true
	end
end

local res, err = gemini.fetch(net, prog.dns(), url, opts)

if not res then
	die(tostring(err))
end
if showhead then
	unistd.write(1, ("%d %s\n"):format(res.status, res.meta))
end

local class = gemini.class(res.status)

-- 1x is a question, and the answer is a fresh request carrying it as a
-- query. Said rather than asked: stdin here may be a pipe, and a
-- prompt read from one would be whatever the pipe held.
if class == gemini.INPUT then
	unistd.write(2, ("gemini: %s\n"):format(res.meta ~= "" and res.meta
	    or "input wanted"))
	unistd.write(2, ("gemini: answer with %s?your+answer\n"):format(
	    res.url))
	os.exit(1)
end
if class ~= gemini.SUCCESS then
	die(("%d %s"):format(res.status, res.meta))
end
if raw then
	os.exit(0)
end

local body = res:take()

if not gemini.isgemtext(res.meta) then
	unistd.write(1, body)
	os.exit(0)
end

local lines = gemini.wrap(gemini.parse(body), cols, { number = true })
local out = {}

for n = 1, #lines do
	out[n] = lines[n].text
end
unistd.write(1, table.concat(out, "\n"))
unistd.write(1, "\n")

-- the links, after the page: a number in the text is only useful if
-- what it stands for can be read, and a url in the middle of a
-- paragraph is what gemtext exists to avoid.
local links = {}

for _, l in ipairs(lines) do
	if l.url and l.link then
		links[l.link] = l.url
	end
end
if links[1] then
	unistd.write(1, "\n")
	for n = 1, #links do
		unistd.write(1, ("[%d] %s\n"):format(n,
		    gemini.resolve(res.url, links[n])))
	end
end
