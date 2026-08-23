-- web: fetch a page and read it.

--   > web lite.duckduckgo.com/lite/?q=lua
--   > web -i https://example.com/          (with the status line)
--   > web -w 40 https://example.com/ | p
--   > web -m https://example.com/          (just the article)
--   > web -c https://example.com/          (without nav and footer)

-- The reading is lib/web.lua over lib/html.lua: no CSS, no scripts,
-- no images. What it prints is the text, folded to the width, with the
-- links numbered so one can be named. bin/fetch.lua is the program for
-- the bytes themselves.

-- The page is never held whole and neither are its lines: it is
-- parsed as it arrives, and printed a window at a time out of an
-- index. A long article costs what its text costs.

local unistd = require("posix.unistd")
local prog = require("prog")
local web = require("web")
local doc = require("doc")

local function die(s)
	unistd.write(2, "web: " .. s .. "\n")
	os.exit(1)
end

local function usage()
	unistd.write(2, "usage: web [-icm] [-w cols] url\n")
	os.exit(2)
end

local showhead, nochrome, article, cols, url = false, false, false, 80, nil
local i = 1

while i <= #arg do
	local a = arg[i]

	if a == "-i" then
		showhead = true
	elseif a == "-m" then
		article = true
	elseif a == "-c" then
		nochrome = true
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
if not url:match("^%a+://") then
	url = "https://" .. url
end

local net = prog.net()

if not net then
	die("no network capability: this shell was lent none")
end

if not prog.rand() and url:match("^https://") then
	die("no entropy: this shell was lent no seed, and tls needs one")
end

local opts = {
	rand = prog.rand(),
	nochrome = nochrome,
	main = article,
	-- the key is printed, not checked: nothing here remembers one
	-- yet, so first use is every use
	onkey = function(h, fp)
		unistd.write(2, ("web: %s is %s\n"):format(h, fp))
	end,
	onredirect = function(from, to, status)
		unistd.write(2, ("web: %d %s -> %s\n"):format(status, from,
		    to))
	end,
}

local res, err = web.fetch(net, prog.dns(), url, opts)

if not res then
	die(tostring(err))
end
if showhead then
	unistd.write(1, ("%d %s\n"):format(res.status,
	    res.headers["content-type"] or ""))
end
if res.status >= 400 then
	die(("%d, and nothing to read"):format(res.status))
end
if not res.blocks then
	die("not text: " .. web.mime(res.headers))
end
if res.info.title then
	unistd.write(1, res.info.title .. "\n\n")
end

local L = doc.layout(res.blocks, cols)
local nos, nlinks = L:linkmap()
local marked = {}

-- the number goes where the link starts, once, so a link folded over
-- two lines is still one thing with one name
local function mark(l)
	local s = l.text

	for k = #l.spans, 1, -1 do
		local sp = l.spans[k]
		local no = nos[sp.link]

		if no and not marked[no] then
			marked[no] = true
			s = doc.sub(s, 1, sp.to) .. "[" .. no .. "]"
			    .. doc.sub(s, sp.to + 1)
		end
	end
	return s
end

-- a window at a time, which is the point of the index: a long page is
-- printed without ever holding its lines
local WINDOW = 64
local at = 1

while at <= L.nlines do
	local lines = L:lines(at, WINDOW)

	if #lines == 0 then
		break
	end

	local out = {}

	for n, l in ipairs(lines) do
		out[n] = mark(l)
	end
	unistd.write(1, table.concat(out, "\n"))
	unistd.write(1, "\n")
	at = at + #lines
end

-- the links after the page, since a number in the text is only useful
-- if what it stands for can be read
if nlinks > 0 then
	local by = {}

	for u, k in pairs(nos) do
		by[k] = u
	end
	unistd.write(1, "\n")
	for k = 1, nlinks do
		unistd.write(1, ("[%d] %s\n"):format(k, by[k]))
	end
end
if res.truncated then
	unistd.write(2, ("web: stopped at the %s bound; the page is longer\n")
	    :format(res.truncated))
end
