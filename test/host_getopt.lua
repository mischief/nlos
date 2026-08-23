#!/usr/bin/env lua5.4
-- lib/getopt, against the real one.
--
-- Every case is run twice: once on this host's luaposix getopt, once on
-- ours. The reference is not a table of expected values written here --
-- it is what the C implementation answers.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local getopt = require("getopt")

local ok, unistd = pcall(require, "posix.unistd")
local reference = ok and unistd.getopt

local count, failed = 0, 0

local function is(cond, name)
	count = count + 1
	io.write((cond and "ok " or "not ok ") .. count .. " - " .. name .. "\n")
	if not cond then
		failed = failed + 1
	end
end

-- one line per yield, so a mismatch shows which yield differed
local function collect(iter)
	local out = {}

	for opt, optarg, oi in iter do
		out[#out + 1] = table.concat({
			tostring(opt), tostring(optarg), tostring(oi),
		}, " ")
	end
	return table.concat(out, "\n")
end

local CASES = {
	{ "no options", { "file" }, "bsw:" },
	{ "one flag", { "-b", "file" }, "bsw:" },
	{ "clustered flags", { "-bs", "file" }, "bsw:" },
	{ "separate argument", { "-w", "40", "file" }, "bsw:" },
	{ "attached argument", { "-w40", "file" }, "bsw:" },
	{ "flag then argument", { "-bw", "40", "f" }, "bsw:" },
	{ "flag with attached", { "-bw40", "f" }, "bsw:" },
	{ "digits as options", { "-1", "-3", "a", "b" }, "123" },
	{ "clustered digits", { "-13", "a", "b" }, "123" },
	{ "double dash", { "--", "-file" }, "bsw:" },
	{ "lone dash", { "-", "file" }, "bsw:" },
	{ "operand first", { "file", "-b" }, "bsw:" },
	-- luaposix drops the offending letter -- its optopt is not exposed
	-- through the binding. Ours keeps it, so a program can name what it
	-- did not understand.
	{ "unknown option", { "-x", "file" }, "bsw:", "? x 2" },
	{ "missing argument", { "-w" }, "bsw:", "? w 2" },
	{ "empty argv", {}, "bsw:" },
	{ "several with args", { "-p", "1", "-R", "-i", "p.diff" }, "p:Ri:" },
	{ "all attached", { "-p1", "-i" .. "p.diff", "-R" }, "p:Ri:" },
}

for _, c in ipairs(CASES) do
	local name, argv, spec, ours = c[1], c[2], c[3], c[4]

	-- luaposix scans from index 1 but reads argv[0] as the program
	-- name, which is how a real utility is called
	argv[0] = "prog"

	local mine = collect(getopt.opts(argv, spec))
	local want = ours

	-- ours is set only where we diverge on purpose; everywhere else
	-- the reference is what luaposix answers
	if not want and reference then
		want = collect(reference(argv, spec))
	end
	if want then
		is(mine == want, name .. ": " .. spec ..
		    (mine == want and "" or "\n# ours:\n" .. mine ..
		    "\n# want:\n" .. want))
	else
		is(true, name .. " (skipped: no luaposix)")
	end
end

-- the property the utilities actually depend on: after the loop, the
-- captured optind indexes the first operand.
local OPERANDS = {
	{ { "-b", "file" }, "bsw:", 2 },
	{ { "-bs", "a", "b" }, "bsw:", 2 },
	{ { "-w", "40", "f" }, "bsw:", 3 },
	{ { "-w40", "f" }, "bsw:", 2 },
	{ { "file" }, "bsw:", 1 },
	{ { "-1", "a", "b" }, "123", 2 },
}

for _, c in ipairs(OPERANDS) do
	local argv, spec, want = c[1], c[2], c[3]

	argv[0] = "prog"
	local optind = 1

	for _, _, oi in getopt.opts(argv, spec) do
		optind = oi
	end
	is(optind == want, "optind for " .. table.concat(argv, " ") ..
	    " is " .. want .. " (got " .. optind .. ")")
end

-- ---- parse: the whole line at once ----
--
-- No luaposix equivalent to check against, so these are the properties
-- the callers depend on, written out.
local PARSE = {
	{ "flags set", { "-l", "-a", "f" }, "la", { l = true, a = true }, 3 },
	{ "clustered", { "-la", "f" }, "la", { l = true, a = true }, 2 },
	{ "with argument", { "-n", "16", "f" }, "n:", { n = "16" }, 3 },
	{ "attached argument", { "-n16", "f" }, "n:", { n = "16" }, 2 },
	{ "no options", { "f" }, "la", {}, 1 },
	{ "repeat keeps last", { "-n1", "-n2" }, "n:", { n = "2" }, 3 },
	-- the case the iterator cannot report: "--" is consumed, and what
	-- follows is an operand however it is spelled
	{ "double dash", { "--", "-f" }, "f", {}, 2 },
	{ "double dash alone", { "-f", "--", "-x" }, "f", { f = true }, 3 },
	{ "lone dash is an operand", { "-" }, "f", {}, 1 },
}

for _, c in ipairs(PARSE) do
	local name, argv, spec, wantflags, wantind = c[1], c[2], c[3], c[4], c[5]
	local flags, optind = getopt.parse(argv, spec)
	local same = flags ~= nil and optind == wantind

	if same then
		for k, v in pairs(wantflags) do
			same = same and flags[k] == v
		end
		for k in pairs(flags) do
			same = same and wantflags[k] ~= nil
		end
	end
	is(same, "parse " .. name .. ": " .. table.concat(argv, " ") ..
	    " (optind " .. tostring(optind) .. ", wanted " .. wantind .. ")")
end

local flags, err = getopt.parse({ "-x" }, "f")

is(flags == nil and err == "unknown option -x", "parse rejects -x: " ..
    tostring(err))

flags, err = getopt.parse({ "-n" }, "n:")
is(flags == nil and err == "option -n wants an argument",
    "parse rejects a missing argument: " .. tostring(err))

io.write("1.." .. count .. "\n")
os.exit(failed == 0 and 0 or 1)
