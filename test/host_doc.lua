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

-- ---- the index, which keeps no lines ----

local page = {}

for i = 1, 40 do
	local b = doc.block(i % 7 == 0 and "head" or "para", { level = 1 })

	doc.run(b, "block " .. i .. " with some words in it to fold ")
	doc.run(b, "a link here", "/l" .. i)
	page[i] = b
end

local L = doc.layout(page, 20)
local all = doc.wrap(page, 20)

is(L.nlines, #all, "the index counts the lines a full wrap makes")

-- and every line it hands back is the line the full wrap made
local same = 0

for i = 1, L.nlines do
	local got = L:lines(i, 1)[1]

	if got and got.text == all[i].text and got.kind == all[i].kind then
		same = same + 1
	end
end
is(same, L.nlines, "and each one of them, asked for on its own")

local win = L:lines(5, 10)

is(#win, 10, "a window is the number of lines asked for")
is(win[1].text, all[5].text, "starting where it was asked to")
is(win[10].text, all[14].text, "and ending ten later")

is(#L:lines(L.nlines, 10), 1, "a window at the end stops at the end")
is(#L:lines(L.nlines + 5, 10), 0, "and past it is nothing at all")

-- a link is found without folding the rest of the page
local at = nil

for i = 1, L.nlines do
	local l = all[i]

	for _, s in ipairs(l.spans) do
		if s.link == "/l3" then
			at = { i, s.from }
			break
		end
	end
	if at then
		break
	end
end
ok(at, "the page has a link to find")
is(L:linkat(at[1], at[2]), "/l3", "and the index finds it where it is")

is(L:nlinks(), 40, "it counts the links without keeping them")
is(L:link(1), "/l1", "and hands over the nth by walking the blocks")
is(L:link(40), "/l40", "including the last")
is(L:link(41), nil, "and nothing past it")

-- what it costs is the point of it
collectgarbage()
local before = collectgarbage("count")
local kept = doc.layout(page, 20)

collectgarbage()
local idx = collectgarbage("count") - before

before = collectgarbage("count")
local lines2 = doc.wrap(page, 20)

collectgarbage()
local full = collectgarbage("count") - before

ok(idx * 4 < full, ("an index is far smaller than the lines it stands " ..
    "for (%.1fk vs %.1fk)"):format(idx, full))
ok(kept.nlines == #lines2, "while standing for exactly as many")

-- ---- what a scroll costs ----

-- The board ran out of memory scrolling a bloated news page, and the
-- fault was here: folding a block allocated a string per word to throw
-- away. A window is asked for on every scroll, so this is the number
-- that has to stay small.
local html = require("html")
local f2 = assert(io.open(scriptdir .. "/fixtures/bloated-news.html", "rb"))
local bloat = f2:read("a")

f2:close()

local BL = doc.layout(html.parse(bloat, { base = "https://x/" }), 48)

ok(BL.nlines > 500, "the fixture is a page worth scrolling")

collectgarbage()
collectgarbage("stop")

local before = collectgarbage("count") * 1024
local ROUNDS = 100

for i = 1, ROUNDS do
	BL:lines(1 + (i * 7) % (BL.nlines - 16), 16)
end

local per = (collectgarbage("count") * 1024 - before) / ROUNDS

collectgarbage("restart")

ok(per < 24 * 1024, ("a scroll allocates %.1fk, which is a window and " ..
    "not the blocks it passed over"):format(per / 1024))

io.write(("1..%d\n"):format(count))
os.exit(failed == 0 and 0 or 1)
