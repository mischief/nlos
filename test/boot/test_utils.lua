-- the utilities ported from the host lua/os tree, run as programs.
--
-- Driven through the shell, because what is being tested is that they
-- read a pipe, a redirect and a named file through lua's io and nothing
-- else. A unit test importing them would prove none of that.
local sys = require("los.sys")
local dos = require("dos")
local ns = require("ns")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(51)

local N = ns.new()

N:mount("/", require("mnt").new(caps_of.esp), "mnt",
    { port = { __right = caps_of.esp } })

local function collector()
	local port = sys.newport("test_utils")
	local out = {}

	return sys.sendright(port), function()
		while true do
			local ok, m = sys.tryrecv(port)

			if not ok then
				local s = table.concat(out)

				for i = #out, 1, -1 do
					out[i] = nil
				end
				return s
			end
			if m and m.op == "write" then
				out[#out + 1] = m.data
			end
		end
	end
end

local cons, drain = collector()
local sh = dos.new({ ns = N, cons = cons })

-- run a command and answer what it wrote, with the status
local function run(cmd)
	local status = dos.once(sh, cmd)

	return drain(), status
end

-- ---- no arguments, no i/o ----

local out, status = run("true")

tap.is(status, 0, "true exits 0")
out, status = run("false")
tap.is(status, 1, "false exits 1")

tap.is(run("basename /a/b/c.lua"), "c.lua\n", "basename strips the path")
tap.is(run("basename /a/b/c.lua .lua"), "c\n", "and the suffix when given")
tap.is(run("dirname /a/b/c.lua"), "/a/b\n", "dirname keeps the path")

-- ---- a pipe ----

tap.is(run("seq 3 | wc"), "       3       3       6 \n",
    "wc counts lines, words and bytes off a pipe")
tap.is(run("seq 5 | head -2"), "1\n2\n", "head -2 stops at two lines")
tap.is(run("seq 5 | tail -2"), "4\n5\n", "tail -2 keeps the last two")
tap.is(run("seq 3 | tr 123 abc"), "a\nb\nc\n", "tr translates a set")

-- sort reads all of stdin before it can answer, which is the case that
-- would hang if a read waited for a byte count instead of end of input.
tap.is(run("seq 3 | sort -r"), "3\n2\n1\n", "sort -r reverses")

-- ---- files, written through the namespace ----
--
-- The ESP is booted under -snapshot, so these never reach the image the
-- other tests share.
assert(N:writefile("/u1.txt", "b\na\na\nc\n"))
assert(N:writefile("/u2.txt", "a\nb\nd\n"))
assert(N:writefile("/cols.txt", "one:two:three\nfour:five:six\n"))

tap.is(run("sort /u1.txt"), "a\na\nb\nc\n", "sort reads a named file")
tap.is(run("sort /u1.txt | uniq"), "a\nb\nc\n", "uniq folds the repeat")
tap.is(run("sort /u1.txt | uniq -c"),
    "      2 a\n      1 b\n      1 c\n", "uniq -c counts them")
tap.is(run("cut -d : -f 2 /cols.txt"), "two\nfive\n",
    "cut takes a field out of each line")
tap.is(run("wc /u2.txt"), "       3       3       6 /u2.txt\n",
    "wc names the file it counted")

-- ---- getopt, which is lib/getopt.lua rather than a C library ----

tap.is(run("comm -12 /u1.txt /u2.txt"), "b\n",
    "comm -12 leaves only the common line")
tap.is(run("fold -w 3 /cols.txt"), "one\n:tw\no:t\nhre\ne\nfou\nr:f\nive\n:si\nx\n",
    "fold -w 3 wraps at three columns")

assert(N:writefile("/tabs.txt", "a\tb\n"))
tap.is(run("expand -t 4 /tabs.txt"), "a   b\n",
    "expand -t 4 turns the tab into spaces to the next stop")

-- a clustered flag and an attached argument in one word: the two forms
-- a hand-rolled loop gets wrong
tap.is(run("paste -sd, /u2.txt"), "a,b,d\n",
    "paste -sd, joins the lines with a comma")

-- ---- exit status and stderr ----

out, status = run("wc /nosuch")
tap.is(status, 1, "wc exits 1 on a missing file")
tap.ok(out:find("wc:") ~= nil, "and says so: " .. out:gsub("\n", ""))

out, status = run("cmp /u1.txt /u1.txt")
tap.is(status, 0, "cmp of a file with itself exits 0")
out, status = run("cmp /u1.txt /u2.txt")
tap.is(status, 1, "cmp of two different files exits 1")
tap.ok(out:find("differ") ~= nil, "and reports where: " .. out:gsub("\n", ""))

out, status = run("expr 2 + 3")
tap.is(out, "5\n", "expr adds")
tap.is(status, 0, "and exits 0 for a true result")

tap.is(run("printf '%s-%s\\n' a b"), "a-b\n", "printf takes a format")

-- ---- a redirect in each direction ----

tap.is(run("seq 3 | tee /tee.txt"), "1\n2\n3\n", "tee passes stdin through")
tap.is(N:readfile("/tee.txt"), "1\n2\n3\n", "and wrote the same to the file")

tap.is(run("sort < /u1.txt"), "a\na\nb\nc\n", "sort reads a redirect")

out = run("diff /u1.txt /u2.txt")
tap.ok(out:find("<") ~= nil and out:find(">") ~= nil,
    "diff shows both sides: " .. out:gsub("\n", " "))

-- ---- od, on bytes whose dump is known ----

tap.is(run("seq 3 | od -c | head -1"), "0000000   1  \\n   2  \\n   3  \\n\n",
    "od -c shows the digits and the newlines")

-- ---- unexpand, the other direction from expand ----

assert(N:writefile("/spaces.txt", "        a\n"))
tap.is(run("unexpand /spaces.txt"), "\ta\n",
    "unexpand turns a full tab stop back into a tab")

-- ---- diff -u and patch, one feeding the other ----
--
-- patch is the only import that reads a file named by an option rather
-- than by an operand, so -i is what proves getopt reaches it.
assert(N:writefile("/p1.txt", "a\nb\nc\n"))
assert(N:writefile("/p2.txt", "a\nB\nc\n"))

out = run("diff -u /p1.txt /p2.txt")
tap.ok(out:find("^%-%-%- ") ~= nil and out:find("\n@@ ") ~= nil,
    "diff -u writes a unified header and a hunk")

assert(N:writefile("/p.diff", out))
out, status = run("patch -i /p.diff")
tap.is(status, 0, "patch applied the hunk: " .. out:gsub("\n", ""))
tap.is(N:readfile("/p1.txt"), "a\nB\nc\n", "and the file now matches p2")

-- ---- what getopt bought the programs that had hand-rolled loops ----
--
-- Clustering, attached arguments and "--" now work everywhere rather
-- than in whichever programs spelled them out.

tap.is(run("ls -la /"), run("ls -l -a /"),
    "ls -la is ls -l -a")
tap.is(run("sort -rn /u1.txt"), run("sort -r -n /u1.txt"),
    "sort -rn is sort -r -n")
tap.is(run("cut -d: -f1 /cols.txt"), run("cut -d : -f 1 /cols.txt"),
    "cut takes its delimiter attached or apart")
tap.is(run("xd -n4 /u2.txt"), run("xd -n 4 /u2.txt"),
    "xd -n4 is xd -n 4")

-- "--", on a name that would otherwise read as an option. The programs
-- that spelled this out by hand all got it wrong: rm's terminator was
-- matched after -f rather than before it, so it never took effect.
assert(N:writefile("/-r", "b\na\n"))

out, status = run("sort -- -r")
tap.is(status, 0, "sort -- takes a file named like an option")
tap.is(out, "a\nb\n", "and sorted it rather than reversing")
tap.is(run("sort -r /-r"), "b\na\n",
    "where the same word without -- is the reverse flag")

out, status = run("ls -Q")
tap.is(status, 2, "an unknown option is refused")
tap.ok(out:find("unknown option") ~= nil, "by name: " .. out:gsub("\n", ""))

-- ---- the converted parsers that no other test reaches ----

out, status = run("dmesg -s")
tap.is(status, 0, "dmesg -s ran")
tap.ok(out:find("bytes held of") ~= nil, "and sized the ring: " ..
    out:gsub("\n", ""))

out, status = run("dmesg -x")
tap.is(status, 1, "dmesg refuses an option it does not have")

-- trace names its pid as an operand, and -n as an option argument. The
-- operand pair (rows, pid) is the case the old lookahead handled.
out, status = run("trace -n 64")
tap.is(status, 0, "trace -n 64 armed a trace: " .. out:gsub("\n", ""))
tap.ok(out:find("64 lines") ~= nil, "and said how many lines")

out, status = run("trace -n notanumber")
tap.is(status, 2, "trace -n wants a number")

tap.done()
