#!/usr/bin/env lua5.4
-- lib/html.lua on the host: a page turned into lib/doc.lua's blocks.
-- Sans-io, so the whole reader runs here, and the fixture is a real
-- page rather than one written to pass.
-- TAP direct: lib/tap.lua needs los.sys.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local html = require("html")
local doc = require("doc")

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

-- a newline in a value would split the TAP line it is printed on, and
-- preformatted text is made of them
local function show(v)
	return (tostring(v):gsub("\r", "\\r"):gsub("\n", "\\n"))
end

local function is(got, want, name)
	ok(got == want, ("%s (got %s, want %s)"):format(name, show(got),
	    show(want)))
end

-- the text of a parse, one block a line, for asserting on shape
local function flat(blocks)
	local out = {}

	for i, b in ipairs(blocks) do
		local parts = {}

		for j = 1, b.n do
			parts[j] = b.text[j]
		end
		out[i] = b.kind .. ":" .. table.concat(parts)
	end
	return table.concat(out, "|")
end

-- ---- entities ----

is(html.unescape("a &amp; b"), "a & b", "a named entity")
is(html.unescape("&lt;p&gt;"), "<p>", "the ones that would be markup")
is(html.unescape("&#65;&#66;"), "AB", "a decimal reference")
is(html.unescape("&#x41;"), "A", "and a hex one")
is(html.unescape("&#8217;"), "\u{2019}", "a codepoint above ascii")
is(html.unescape("100% &"), "100% &", "a bare ampersand is left alone")
is(html.unescape("&nosuchthing;"), "&nosuchthing;",
    "and one nobody knows is left as it was written")

-- ---- attributes ----

local a = html.attrs('a href="/x" class=\'y\' rel=nofollow')

is(a.href, "/x", "a double quoted value")
is(a.class, "y", "a single quoted one")
is(a.rel, "nofollow", "and one with no quotes at all")

a = html.attrs('a href="/l/?uddg=x&amp;rut=y"')
is(a.href, "/l/?uddg=x&amp;rut=y",
    "an = inside a quoted value does not start another attribute")

-- ---- blocks ----

is(flat(html.parse("<p>one</p><p>two</p>")), "para:one|para:two",
    "two paragraphs are two blocks")
is(flat(html.parse("<h1>Big</h1><h2>Less</h2>")), "head:Big|head:Less",
    "headings are their own kind")
is(html.parse("<h1>a</h1>")[1].level, 1, "h1 is level one")
is(html.parse("<h4>a</h4>")[1].level, 3,
    "and anything past h3 is level three, which is all there is")

is(flat(html.parse("<ul><li>a</li><li>b</li></ul>")), "item:a|item:b",
    "list items")
is(flat(html.parse("<blockquote>said</blockquote>")), "quote:said",
    "a quote")
is(flat(html.parse("a<br>b")), "para:a|para:b",
    "a break ends the line without ending the paragraph's kind")
is(html.parse("<hr>")[1].kind, "rule", "a rule is a block of its own")

-- an unclosed tag is the ordinary case on a real page
is(flat(html.parse("<p>one<p>two")), "para:one|para:two",
    "a paragraph that is never closed still ends")

is(flat(html.parse("<div>  a\n\n  b  </div>")), "para:a b",
    "whitespace collapses, and the source's own indent is not content")
is(#html.parse("<p>   </p>"), 0,
    "a block with nothing but space in it is not a block")

is(flat(html.parse("<pre>  a\n  b</pre>")), "pre:  a\n  b",
    "preformatted text keeps its spaces and its newlines")

is(flat(html.parse("<p>a<script>var x = '<p>no</p>';</script>b</p>")),
    "para:ab", "a script is not content, and what is inside it is not markup")
is(flat(html.parse("<style>p { }</style><p>a</p>")), "para:a",
    "nor is a stylesheet")

is(flat(html.parse("<p>a<em>b</em>c</p>")), "para:abc",
    "an inline element is the text around it")
is(flat(html.parse("<p>a<nosuchtag>b</nosuchtag>c</p>")), "para:abc",
    "and so is one nobody has heard of")

-- ---- links ----

local blocks = html.parse('<p>see <a href="/docs">the docs</a> now</p>',
    { base = "https://example.com/a/b" })

is(#blocks, 1, "a link does not break the paragraph it is in")
is(blocks[1].n, 3, "it is a run among the runs")
is(doc.runlink(blocks[1], 2), "https://example.com/docs",
    "resolved against the page it was found on")
is(doc.runlink(blocks[1], 1), nil, "the text before it carries no link")
is(doc.runlink(blocks[1], 3), nil, "nor the text after")

blocks = html.parse('<a href="//other.example/x">y</a>',
    { base = "https://example.com/" })
is(doc.runlink(blocks[1], 1), "https://other.example/x",
    "a scheme-relative href keeps the page's scheme")

blocks = html.parse('<a href="#top">y</a><a href="/z">w</a>',
    { base = "https://example.com/" })
is(doc.runlink(blocks[1], 1), nil, "a link to a place on this page is not one")
is(doc.runlink(blocks[1], 2), "https://example.com/z", "the next one still is")

blocks = html.parse('<a href="javascript:evil()">y</a>',
    { base = "https://example.com/" })
is(doc.runlink(blocks[1], 1), nil, "and a script url is not a link at all")

blocks = html.parse('<base href="/deep/"><a href="x">y</a>',
    { base = "https://example.com/a/b" })
is(doc.runlink(blocks[1], 1), "https://example.com/deep/x",
    "a base element moves what the rest of the page is relative to")

blocks = html.parse('<a href="/i"><img src="p.png" alt="a picture"></a>',
    { base = "https://example.com/" })
is(blocks[1].text[1], "[a picture]",
    "an image is its alt text, since nothing here can draw it")
is(doc.runlink(blocks[1], 1), "https://example.com/i",
    "and it is still the link it sits inside")

-- ---- the title ----

local _, info = html.parse("<html><head><title>The  Page</title></head>" ..
    "<body>hi</body></html>")

is(info.title, "The Page", "the title comes out, with its spaces folded")
is(flat(select(1, html.parse("<title>t</title><p>a</p>"))), "para:a",
    "and is not part of the text")

-- ---- ordered lists ----

blocks = html.parse("<ol><li>a</li><li>b</li></ol>")
is(blocks[1].marker, "1. ", "an ordered list numbers its items")
is(blocks[2].marker, "2. ", "counting up")

blocks = html.parse("<ul><li>a<ul><li>b</li></ul></li></ul>")
is(blocks[2].level, 2, "a nested list says how deep it is")

-- ---- the bounds ----

local many = string.rep("<p>x</p>", 500)
local b, i = html.parse(many, { maxblocks = 100 })

is(#b, 100, "a page stops at the block bound")
is(i.truncated, "blocks", "and says that is why it ended")

b = html.parse(many)
is(#b, 500, "under the bound nothing is dropped")

-- ---- a real page ----

local f = assert(io.open(scriptdir .. "/fixtures/ddg-lite.html", "rb"))
local page = f:read("a")

f:close()

local rblocks, rinfo = html.parse(page,
    { base = "https://lite.duckduckgo.com/lite/?q=lua+os" })

ok(#rblocks > 10, "a real search page is a page of blocks")
ok(rinfo.title and rinfo.title:find("lua os"), "with the query in its title")

local lines = doc.wrap(rblocks, 60)
local links = doc.links(lines)

ok(#links >= 5, "and links enough to be worth reading")

local absolute = 0

for _, l in ipairs(links) do
	if l:match("^https?://") then
		absolute = absolute + 1
	end
end
is(absolute, #links, "every one of them resolved to somewhere absolute")

-- the layout has to be answerable: every span sits on its own line
local bad = 0

for _, l in ipairs(lines) do
	for _, s in ipairs(l.spans) do
		if s.from < 1 or s.to > doc.len(l.text) then
			bad = bad + 1
		end
	end
end
is(bad, 0, "and every span falls inside the line it is on")

-- ---- what is kept, and what is only merged ----

-- an inline element changes nothing a reader can see here, so its text
-- joins what is beside it rather than costing a run of its own
blocks = html.parse("<p>the <i>Lua</i> language</p>")
is(blocks[1].n, 1, "inline markup does not split a sentence into runs")
is(blocks[1].text[1], "the Lua language", "and not one character is lost")

blocks = html.parse('<p>a <a href="/x">b</a> c <a href="/x">d</a></p>',
    { base = "https://e.com/" })
is(blocks[1].n, 4, "but a link is a run, and the text after it another")

is(flat(html.parse("<nav>menu</nav><p>body</p>")), "para:menu|para:body",
    "navigation is kept, being text like any other")
is(flat(html.parse("<nav>menu</nav><p>body</p>", { nochrome = true })),
    "para:body", "unless a caller says it did not come for the chrome")
is(flat(html.parse("<footer>small print</footer><p>b</p>",
    { nochrome = true })), "para:b", "which goes for the footer too")

-- ---- the byte bound, which is the other half of it ----

local web = require("web")

local cap = web.capsink(10)

is(cap.sink("abc"), true, "a sink under the bound takes what it is given")
is(cap.sink("defg"), true, "and keeps taking")
is(cap.sink("hijklmno"), false,
    "the piece that would cross the bound is refused")
is(cap.n, 10, "having kept exactly as much as the bound allows")
is(cap.take(), "abcdefghij", "which is the front of what arrived")
ok(cap.cut, "and it says it was cut, so a caller can tell that from a failure")
is(cap.sink("more"), false, "nothing is taken after that")

cap = web.capsink(10)
cap.sink("short")
ok(not cap.cut, "a body that fits is not marked cut")
is(cap.take(), "short", "and comes back whole")

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
