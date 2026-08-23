#!/usr/bin/env lua5.4
-- lib/gemini.lua on the host. Sans-io, so the whole of it runs here:
-- the bytes are strings and the only thing a board adds is the TLS
-- connection they arrive over.
-- TAP direct: lib/tap.lua needs los.sys.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local gemini = require("gemini")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
end

-- a CR or an LF in a value would split the TAP line it is printed on,
-- and this protocol is made of them
local function show(v)
	return (tostring(v):gsub("\r", "\\r"):gsub("\n", "\\n"))
end

local function is(got, want, name)
	ok(got == want, ("%s (got %s, want %s)"):format(name, show(got),
	    show(want)))
end

-- ---- URLs ----

local u = gemini.url("gemini://example.org/foo/bar?q=1")

is(u and u.host, "example.org", "the host comes out")
is(u and u.port, 1965, "and the default port, unwritten")
is(u and u.path, "/foo/bar", "and the path")
is(u and u.query, "q=1", "and the query, which gemini uses for input")

is(gemini.url("gemini://EXAMPLE.org:1965/").url, "gemini://example.org/",
    "a host folds to lower case and the default port is dropped")
is(gemini.url("gemini://example.org").path, "/",
    "no path at all is the root")
is(gemini.url("gemini://example.org:1966/x").url,
    "gemini://example.org:1966/x", "any other port is kept")
is(gemini.url("gemini://[2001:db8::1]/x").host, "2001:db8::1",
    "a v6 literal comes out without its brackets")
is(gemini.url("gemini://[2001:db8::1]:1966/").url,
    "gemini://[2001:db8::1]:1966/", "and goes back in with them")

ok(not gemini.url("http://example.org/"), "http is not gemini")
ok(not gemini.url("gemini:///x"), "a url with no host is refused")
ok(not gemini.url("gemini://user@example.org/"),
    "and one carrying userinfo, which gemini has none of")

-- what a page's own links mean, which is RFC 3986 and not gemini's
local base = "gemini://example.org/a/b/page.gmi"

is(gemini.resolve(base, "other.gmi"), "gemini://example.org/a/b/other.gmi",
    "a bare name is a sibling")
is(gemini.resolve(base, "/top.gmi"), "gemini://example.org/top.gmi",
    "a leading slash is from the root")
is(gemini.resolve(base, "../up.gmi"), "gemini://example.org/a/up.gmi",
    "and .. climbs one")
is(gemini.resolve(base, "../../../way/up"), "gemini://example.org/way/up",
    "climbing past the root stops at it")
is(gemini.resolve(base, "gemini://other.example/x"),
    "gemini://other.example/x", "an absolute link ignores the page it is on")
is(gemini.resolve(base, "//other.example/x"), "gemini://other.example/x",
    "and a scheme-relative one keeps the scheme")
is(gemini.resolve(base, "?q=2"), "gemini://example.org/a/b/page.gmi?q=2",
    "a bare query re-asks the same page")
is(gemini.resolve(base, ""), base, "an empty link is the page itself")
is(gemini.resolve(base, "."), "gemini://example.org/a/b/",
    "and a dot is the directory it sits in")

-- ---- the request ----

is(gemini.request("gemini://example.org/x"), "gemini://example.org/x\r\n",
    "a request is the url and a CRLF, and nothing else")
ok(not gemini.request("gemini://example.org/" .. string.rep("x", 1100)),
    "a url that will not fit in 1024 bytes is refused here")
is(gemini.answer("gemini://example.org/search", "hello world"),
    "gemini://example.org/search?hello%20world\r\n",
    "an answer to a prompt is the same page with the reply as a query")

-- ---- the reply ----

local function reply(...)
	local r = gemini.response()

	for _, part in ipairs({ ... }) do
		local okf, err = r:feed(part)

		if not okf then
			return nil, err
		end
	end
	return r
end

local r = reply("20 text/gemini\r\n# hi\n")

is(r.status, 20, "the status is two digits")
is(r.meta, "text/gemini", "and the meta is the rest of the line")
is(r:take(), "# hi\n", "the body is what follows the CRLF")

r = reply("20 text/gemini\r\n")
is(r.status, 20, "a reply with no body yet still has its header")
is(r:take(), "", "and nothing else")

-- the header may arrive in as many pieces as the network likes
r = gemini.response()
r:feed("2")
is(r.status, nil, "two bytes is not a header")
r:feed("0 text/gemi")
is(r.status, nil, "nor is a header without its CRLF")
r:feed("ni\r\nbody")
is(r.status, 20, "the status arrives when the line does")
is(r:take(), "body", "and the body that came with it")

-- and the CRLF itself may be split across two feeds
r = gemini.response()
r:feed("31 gemini://example.org/moved\r")
is(r.status, nil, "a CR on its own does not end the header")
r:feed("\nx")
is(r.status, 31, "the LF does")
is(r.meta, "gemini://example.org/moved", "and a 3x meta is where to go")

is(gemini.class(20), gemini.SUCCESS, "2x is success")
is(gemini.class(10), gemini.INPUT, "1x asks a question")
is(gemini.class(31), gemini.REDIRECT, "3x moves")
is(gemini.class(51), gemini.PERMFAIL, "5x is a no")
is(gemini.class(60), gemini.CERTREQ, "6x wants a certificate")

local sunk = {}

r = gemini.response({ sink = function(s) sunk[#sunk + 1] = s end })
r:feed("20 text/gemini\r\nabc")
r:feed("def")
is(table.concat(sunk), "abcdef", "a sink takes the body as it arrives")
is(r.nbody, 6, "and the count is kept either way")

ok(not reply("hello\r\n"), "a header that is not two digits is refused")
ok(not reply(string.rep("2", 2000)),
    "and one that never ends stops rather than growing")

r = gemini.response()
ok(not r:eof(), "a peer that closes before its header said nothing")

r = gemini.response()
r:feed("20 text/gemini\r\npartial")
ok(r:eof(), "and a close after one IS the end of the body")

is(gemini.mime("text/gemini; charset=utf-8"), "text/gemini",
    "the type comes off the meta")
is(select(2, gemini.mime("text/gemini; lang=en")).lang, "en",
    "with its parameters")
is(gemini.mime(""), "text/gemini", "an empty meta means gemtext")
ok(gemini.isgemtext("text/gemini"), "which is what a client renders")
ok(not gemini.isgemtext("text/plain"), "and text/plain is not that")

-- ---- gemtext ----

local PAGE = table.concat({
	"# Heading",
	"## Sub",
	"",
	"A paragraph.",
	"=> gemini://example.org/one One",
	"=>relative.gmi",
	"* an item",
	"> a quote",
	"```alt text",
	"# not a heading in here",
	"=> nor a link",
	"```",
	"last",
}, "\n")

local nodes = gemini.parse(PAGE)
local kinds = {}

for i, n in ipairs(nodes) do
	kinds[i] = n.kind
end
is(table.concat(kinds, ","),
    "head,head,text,text,link,link,item,quote,prebegin,pre,pre,preend,text",
    "every line is one node, and the fence toggles what they mean")

is(nodes[1].level, 1, "one hash is level one")
is(nodes[2].level, 2, "two is level two")
is(nodes[1].text, "Heading", "and the hash is not part of the text")
is(nodes[5].url, "gemini://example.org/one", "a link gives its url")
is(nodes[5].label, "One", "and its label")
is(nodes[6].url, "relative.gmi", "a link needs no space after the arrow")
is(nodes[6].label, "", "and no label at all")
is(nodes[7].text, "an item", "an item loses its bullet")
is(nodes[8].text, "a quote", "a quote loses its mark")
is(nodes[9].alt, "alt text", "the fence carries its alt text")
is(nodes[10].text, "# not a heading in here",
    "and a hash inside the fence is just a hash")
is(nodes[11].text, "=> nor a link", "as is an arrow")

is(#gemini.parse("no newline at the end"), 1,
    "a last line without a newline is still a line")
is(gemini.parse("a\r\nb\r\n")[1].text, "a", "CRLF endings lose the CR")
is(#gemini.parse(""), 0, "an empty page has no nodes")

-- fed a byte at a time, which is what a slow link does
local g = gemini.gemtext()
local nodes2 = {}

for i = 1, #PAGE do
	g:feed(PAGE:sub(i, i))
end
g:eof()
for n in function() return g:next() end do
	nodes2[#nodes2 + 1] = n
end
is(#nodes2, #nodes, "a page fed one byte at a time parses the same")
is(nodes2[9].alt, "alt text", "fence and all")

-- ---- laying it out ----

local lines = gemini.wrap(gemini.parse(
    "a bbbb cccc dddd eeee ffff"), 12)

is(#lines, 3, "a paragraph folds to the width")
is(lines[1].text, "a bbbb cccc", "on spaces")
is(lines[3].text, "ffff", "and the last line is what is left")

lines = gemini.wrap(gemini.parse("=> /a first\n=> /b second"), 40,
    { number = true })
is(lines[1].text, "[1] first", "links are numbered for a caller to name")
is(lines[2].text, "[2] second", "counting up the page")
is(lines[2].url, "/b", "and each line knows the link it came from")
is(lines[2].link, 2, "by number as well")

lines = gemini.wrap(gemini.parse("=> /a one two three four five"), 12,
    { number = true })
is(#lines, 4, "a long label folds under its own number")
is(lines[2].text, "    three", "and the fold is indented past it")
is(lines[2].url, "/a", "every line of it still names the link")

lines = gemini.wrap(gemini.parse("```\n  a picture  \n```"), 8)
is(#lines, 1, "a fence itself takes no line")
is(lines[1].text, "  a picture  ",
    "and what is inside is passed through, spaces and width and all")

lines = gemini.wrap(gemini.parse("supercalifragilistic"), 8)
is(lines[1].text, "supercal",
    "a word longer than the line is broken rather than run off it")

-- gemini is utf-8, so a column is a codepoint and not a byte
lines = gemini.wrap(gemini.parse("\u{e9}\u{e9}\u{e9} \u{e9}\u{e9}\u{e9}"), 4)
is(#lines, 2, "an accented word takes the columns it looks like it takes")
is(lines[1].text, "\u{e9}\u{e9}\u{e9}", "and is not broken up by its bytes")

lines = gemini.wrap(gemini.parse(string.rep("\u{1f30d}", 6)), 4)
is(lines[1].text, string.rep("\u{1f30d}", 4),
    "a hard break falls on a character boundary")
is(lines[2].text, string.rep("\u{1f30d}", 2), "and what is left follows")

lines = gemini.wrap(gemini.parse("* one\n> two"), 20)
is(lines[1].text, "* one", "an item is drawn with its bullet back")
is(lines[2].text, "> two", "and a quote with its mark")

lines = gemini.wrap(gemini.parse(""), 20)
is(#lines, 0, "an empty page lays out to nothing")

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
