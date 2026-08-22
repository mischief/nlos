-- ls: written for this system rather than ported.
--
-- the ported utilities (seq, cat) run unchanged because the posix sliver
-- in lib/prog.lua covers what they use. ls is where that stops: the
-- original wants posix.pwd, posix.grp and getopt, and users and groups
-- do not exist here. Terminal detection does, under another name:
-- prog.tty() is nil where isatty would be false.
local prog = require("prog")

local N = prog.ns()
local long, all = false, false
local paths = {}

for _, a in ipairs(arg) do
	if a == "-l" then
		long = true
	elseif a == "-a" then
		all = true
	elseif a:sub(1, 1) == "-" then
		io.stderr:write("ls: unknown option " .. a .. "\n")
		os.exit(2)
	else
		paths[#paths + 1] = a
	end
end
if #paths == 0 then
	paths[1] = prog.cwd()
end

-- How wide to lay out in. prog.tty() is nil when the output was piped
-- or the caller has no console, which is where one name a line is the
-- right answer. A console that cannot measure itself -- a serial line
-- has no way to ask -- says nil, and 80 is the convention to fall back
-- on rather than a measurement.
local WIDTH = 80

local function width()
	local t = prog.tty()

	if not t then
		return nil
	end

	local cols = t.size()

	return (type(cols) == "number" and cols > 0) and cols or WIDTH
end

-- one name a line for -l, columns otherwise. Not `long and nil or
-- width()`: nil is false, so that columnises a long listing too.
local cols = nil

if not long then
	cols = width()
end

-- Down the column and then across, as ls has always done: a reader
-- looking for a name scans one column rather than jigging along a row.
--
-- Bytes are not cells for anything above ASCII, so the count is
-- characters where the name is valid utf8 and bytes where it is not.
local function textwidth(s)
	return utf8.len(s) or #s
end

local function columns(names, avail)
	local widest = 0

	for _, s in ipairs(names) do
		local w = textwidth(s)

		if w > widest then
			widest = w
		end
	end

	local colw = widest + 2
	local ncols = math.max(1, avail // colw)
	local nrows = (#names + ncols - 1) // ncols

	for r = 1, nrows do
		local line = {}

		for c = 0, ncols - 1 do
			local name = names[c * nrows + r]

			if name then
				line[#line + 1] = name
				-- no padding after the last one on a row,
				-- so a name at the right margin does not
				-- wrap on trailing blanks
				if names[(c + 1) * nrows + r] then
					line[#line + 1] = string.rep(" ",
					    colw - textwidth(name))
				end
			end
		end
		io.write(table.concat(line), "\n")
	end
end

local function show(path, ents)
	local names = {}

	if #paths > 1 then
		io.write(path .. ":\n")
	end
	for _, e in ipairs(ents) do
		if all or e.name:sub(1, 1) ~= "." then
			if long then
				io.write(string.format("%s %8d %s\n",
				    e.dir and "d" or "-", e.size, e.name))
			else
				names[#names + 1] = e.name ..
				    (e.dir and "/" or "")
			end
		end
	end

	if #names == 0 then
		return
	end
	if cols then
		columns(names, cols)
	else
		io.write(table.concat(names, "\n"), "\n")
	end
end

local status = 0

for _, path in ipairs(paths) do
	local st = N:stat(path)

	if not st then
		io.stderr:write("ls: " .. path .. ": no such file\n")
		status = 1
	elseif st.dir then
		local ents, err = N:readdir(path)

		if not ents then
			io.stderr:write("ls: " .. path .. ": " ..
			    tostring(err) .. "\n")
			status = 1
		else
			show(path, ents)
		end
	else
		io.write(path .. "\n")
	end
end

os.exit(status)
