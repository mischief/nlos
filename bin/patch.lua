-- SPDX-License-Identifier: ISC
-- patch: apply unified diff patches
local getopt = require("getopt")

local strip = 0
local reverse = false
local input_file = nil
local optind = 1

for opt, optarg, oi in getopt.opts(arg, "p:Ri:") do
	if opt == "p" then strip = tonumber(optarg) or 0
	elseif opt == "R" then reverse = true
	elseif opt == "i" then input_file = optarg
	end
	optind = oi
end

-- Read patch input
local patch_text
if input_file then
	local f = io.open(input_file, "r")
	if not f then io.stderr:write("patch: can't open " .. input_file .. "\n"); os.exit(1) end
	patch_text = f:read("a"); f:close()
else
	patch_text = io.read("a")
end

-- Strip path components
local function strip_path(path, n)
	for _ = 1, n do
		path = path:gsub("^[^/]*/", "")
	end
	return path
end

-- Parse unified diff into hunks
local function parse_patch(text)
	local files = {}
	local current = nil
	for line in text:gmatch("[^\n]*") do
		if line:match("^%-%-%- ") then
			current = { old = line:sub(5):gsub("%s.*", ""), hunks = {} }
		elseif line:match("^%+%+%+ ") and current then
			current.new = line:sub(5):gsub("%s.*", "")
			files[#files + 1] = current
		elseif line:match("^@@ ") and current then
			local ol, oc, nl, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
			ol = tonumber(ol) or 1; oc = tonumber(oc) or 1
			nl = tonumber(nl) or 1; nc = tonumber(nc) or 1
			current.hunks[#current.hunks + 1] = { old_start = ol, old_count = oc, new_start = nl, new_count = nc, lines = {} }
		elseif current and #current.hunks > 0 and (line:sub(1, 1) == " " or line:sub(1, 1) == "+" or line:sub(1, 1) == "-") then
			local hunk = current.hunks[#current.hunks]
			hunk.lines[#hunk.lines + 1] = line
		end
	end
	return files
end

-- Apply hunks to file content
local function apply_hunks(lines, hunks)
	local result = {}
	local pos = 1
	for _, hunk in ipairs(hunks) do
		local start = hunk.old_start
		-- Copy lines before this hunk
		while pos < start do
			result[#result + 1] = lines[pos]
			pos = pos + 1
		end
		-- Apply hunk
		for _, hl in ipairs(hunk.lines) do
			local op = hl:sub(1, 1)
			local content = hl:sub(2)
			if reverse then
				if op == "+" then op = "-" elseif op == "-" then op = "+" end
			end
			if op == " " then
				result[#result + 1] = content
				pos = pos + 1
			elseif op == "-" then
				pos = pos + 1 -- skip old line
			elseif op == "+" then
				result[#result + 1] = content
			end
		end
	end
	-- Copy remaining lines
	while pos <= #lines do
		result[#result + 1] = lines[pos]
		pos = pos + 1
	end
	return result
end

local files = parse_patch(patch_text)
if #files == 0 then
	io.stderr:write("patch: no valid patches found\n"); os.exit(1)
end

for _, file in ipairs(files) do
	local target = strip_path(file.old, strip)
	if target == "/dev/null" then target = strip_path(file.new, strip) end

	-- Read target file
	local lines = {}
	local f = io.open(target, "r")
	if f then
		for l in f:lines() do lines[#lines + 1] = l end
		f:close()
	end

	-- Apply
	local result = apply_hunks(lines, file.hunks)

	-- Write back
	f = io.open(target, "w")
	if not f then
		io.stderr:write("patch: can't write " .. target .. "\n"); os.exit(1)
	end
	for _, l in ipairs(result) do f:write(l .. "\n") end
	f:close()

	io.write("patching file " .. target .. "\n")
end
