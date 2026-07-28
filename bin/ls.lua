-- ls: written for this system rather than ported.
--
-- the ported utilities (seq, cat) run unchanged because the posix sliver
-- in lib/prog.lua covers what they use. ls is where that stops: the
-- original wants posix.pwd, posix.grp, getopt and isatty -- users,
-- groups and terminal detection none of which exist here. rewriting is
-- 40 lines; faking a passwd database to avoid it would be worse.
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

local function show(path, ents)
	if #paths > 1 then
		io.write(path .. ":\n")
	end
	for _, e in ipairs(ents) do
		if all or e.name:sub(1, 1) ~= "." then
			if long then
				io.write(string.format("%s %8d %s\n",
				    e.dir and "d" or "-", e.size, e.name))
			else
				io.write(e.name .. (e.dir and "/" or "") .. "\n")
			end
		end
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
