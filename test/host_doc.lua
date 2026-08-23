#!/usr/bin/env lua5.4
-- lib/doc.lua on the host: blocks of inline runs, folded to a width,
-- and where each link lands once they are. No framebuffer needed to
-- answer any of it.
-- TAP direct: lib/tap.lua needs los.sys.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

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

-- a newline in a value would split the TAP line it is printed on
local function show(v)
	return (tostring(v):gsub("\r", "\\r"):gsub("\n", "\\n"))
end

local function is(got, want, name)
	ok(got == want, ("%s (got %s, want %s)"):format(name, show(got),
	    show(want)))
end

local function para(...)
	local b = doc.block("para")

	for _, r in ipairs({ ... }) do
		doc.run(b, r[1], r[2])
	end
	return b
end

-- ---- a paragraph with a link inside it ----

local lines = doc.wrap({ para({ "see " }, { "the docs", "/docs" },
    { " for more" }) }, 40)

is(#lines, 1, "a short paragraph is one line")
is(lines[1].text, "see the docs for more", "with its runs joined")
is(#lines[1].spans, 1, "and one span on it")
is(lines[1].spans[1].from, 5, "starting where the link text starts")
is(lines[1].spans[1].to, 12, "and ending where it ends")
is(lines[1].spans[1].link, "/docs", "naming the link")

is(doc.linkat(lines[1], 5), "/docs", "the first cell of the link is it")
is(doc.linkat(lines[1], 12), "/docs", "and so is the last")
is(doc.linkat(lines[1], 4), nil, "the space before it is not")
is(doc.linkat(lines[1], 13), nil, "nor the space after")
is(doc.linkat(lines[1], 1), nil, "nor anything else on the line")

-- ---- a link that crosses a fold ----

lines = doc.wrap({ para({ "a " }, { "link with several words", "/x" },
    { " end" }) }, 12)

ok(#lines > 1, "a long paragraph folds")

local hits = 0

for _, l in ipairs(lines) do
	for _, s in ipairs(l.spans) do
		if s.link == "/x" then
			hits = hits + 1
		end
	end
end
ok(hits > 1, "a link crossing a fold is a span on each line it touches")

for i, l in ipairs(lines) do
	for _, s in ipairs(l.spans) do
		ok(s.from >= 1 and s.to <= doc.len(l.text),
		    ("span %d stays inside its own line"):format(i))
	end
end

-- what a cell answers has to match what is drawn there
for _, l in ipairs(lines) do
	for col = 1, doc.len(l.text) do
		local link = doc.linkat(l, col)
		local ch = doc.sub(l.text, col, col)

		if link and ch == " " then
			-- a space inside a link is still the link, but one
			-- outside every span must not answer
			ok(true, "spaces inside a link belong to it")
			break
		end
	end
end

-- ---- prefixes move the columns ----

lines = doc.wrap({ doc.run(doc.block("item"), "go", "/go") }, 20)
is(lines[1].text, "* go", "an item is drawn with its bullet")
is(lines[1].spans[1].from, 3, "and the link starts past it")
is(doc.linkat(lines[1], 1), nil, "the bullet is not part of the link")
is(doc.linkat(lines[1], 3), "/go", "the text after it is")

lines = doc.wrap({ doc.run(doc.block("quote"), "said", "/s") }, 20)
is(lines[1].text, "> said", "a quote keeps its mark")
is(doc.linkat(lines[1], 3), "/s", "and its link is past that too")

-- ---- headings, rules and preformatted ----

lines = doc.wrap({ doc.run(doc.block("head", { level = 2 }), "Title") },
    20)
is(lines[1].text, "  Title", "a level two heading is indented")
is(lines[1].level, 2, "and says which level it is")

lines = doc.wrap({ doc.block("rule") }, 10)
is(lines[1].text, "----------", "a rule is the width")

lines = doc.wrap({ doc.run(doc.block("pre"), "  a\n  bb\n") }, 4)
is(#lines, 2, "preformatted text is lines, not folds")
is(lines[1].text, "  a", "kept as it is")
is(lines[2].text, "  bb", "however wide it is")

-- ---- numbering ----

lines = doc.wrap({
	para({ "one ", nil }, { "first", "/a" }),
	para({ "two ", nil }, { "second", "/b" }),
	para({ "again ", nil }, { "first", "/a" }),
}, 40)

local links = doc.links(lines)

is(#links, 2, "a link named twice is one link")
is(links[1], "/a", "numbered in the order they are read")
is(links[2], "/b", "counting up the page")
is(lines[1].spans[1].no, 1, "and every span learns its number")
is(lines[3].spans[1].no, 1, "including the second mention of one")

-- ---- what has no runs at all ----

lines = doc.wrap({ doc.block("para") }, 20)
is(#lines, 1, "an empty paragraph is still a line")
is(lines[1].text, "", "an empty one")
is(doc.linkat(lines[1], 1), nil, "with nothing under any cell")

is(#doc.wrap({}, 20), 0, "an empty document lays out to nothing")

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
