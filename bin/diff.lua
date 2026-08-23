-- SPDX-License-Identifier: ISC
-- diff/diff.lua - compare files line by line

local context = 3
local unified = false
local optind = 1

-- Simple arg parsing (getopt doesn't handle optional args well)
while optind <= #arg do
	local a = arg[optind]
	if a == "-u" then unified = true; optind = optind + 1
	elseif a:match("^%-u%d+$") then unified = true; context = tonumber(a:sub(3)); optind = optind + 1
	elseif a:match("^%-U$") then unified = true; optind = optind + 1; context = tonumber(arg[optind]) or 3; optind = optind + 1
	elseif a:match("^%-c$") then unified = false; optind = optind + 1
	elseif a:match("^%-C$") then optind = optind + 1; context = tonumber(arg[optind]) or 3; optind = optind + 1
	elseif a:sub(1, 1) == "-" then optind = optind + 1
	else break end
end

local file1 = arg[optind]
local file2 = arg[optind + 1]
if not file1 or not file2 then
	io.stderr:write("usage: diff [-u] file1 file2\n"); os.exit(2)
end

local function read_lines(path)
	if path == "-" then
		local lines = {}
		for l in io.lines() do lines[#lines + 1] = l end
		return lines
	end
	local f = io.open(path, "r")
	if not f then io.stderr:write("diff: " .. path .. ": No such file or directory\n"); os.exit(2) end
	local lines = {}
	for l in f:lines() do lines[#lines + 1] = l end
	f:close()
	return lines
end

-- Myers diff algorithm (simple O(ND) implementation)
local function lcs_diff(a, b)
	local n, m = #a, #b
	local max = n + m
	local v = {}
	v[1] = 0
	local trace = {}

	for d = 0, max do
		trace[d] = {}
		for k = -d, d, 2 do
			local x
			if k == -d or (k ~= d and (v[k - 1] or 0) < (v[k + 1] or 0)) then
				x = v[k + 1] or 0
			else
				x = (v[k - 1] or 0) + 1
			end
			local y = x - k
			while x < n and y < m and a[x + 1] == b[y + 1] do
				x = x + 1; y = y + 1
			end
			v[k] = x
			trace[d][k] = x
			if x >= n and y >= m then
				-- Backtrack to build edit script
				local edits = {}
				local cx, cy = n, m
				for dd = d, 0, -1 do
					local kk = cx - cy
					local prev_x
					if kk == -dd or (kk ~= dd and (trace[dd - 1] and (trace[dd - 1][kk - 1] or 0) < (trace[dd - 1][kk + 1] or 0))) then
						prev_x = trace[dd - 1] and trace[dd - 1][kk + 1] or 0
					else
						prev_x = trace[dd - 1] and trace[dd - 1][kk - 1] or 0
						if kk ~= -dd then prev_x = prev_x + 1 end
					end
					-- Simpler approach: just mark changes
				end
				-- Use simpler LCS approach for edit script
				return nil -- fall through to simple method
			end
		end
	end
	return nil
end

-- Simple LCS-based diff (O(NM) but correct and simple)
local function compute_lcs(a, b)
	local n, m = #a, #b
	-- For large files, use a hash-based approach
	local dp = {}
	for i = 0, n do dp[i] = {} end
	for i = 0, n do dp[i][0] = 0 end
	for j = 0, m do dp[0][j] = 0 end
	for i = 1, n do
		for j = 1, m do
			if a[i] == b[j] then dp[i][j] = dp[i - 1][j - 1] + 1
			else dp[i][j] = math.max(dp[i - 1][j], dp[i][j - 1]) end
		end
	end
	-- Backtrack
	local edits = {}
	local i, j = n, m
	while i > 0 or j > 0 do
		if i > 0 and j > 0 and a[i] == b[j] then
			edits[#edits + 1] = { op = " ", line = a[i], ai = i, bi = j }
			i = i - 1; j = j - 1
		elseif j > 0 and (i == 0 or dp[i][j - 1] >= dp[i - 1][j]) then
			edits[#edits + 1] = { op = "+", line = b[j], bi = j }
			j = j - 1
		else
			edits[#edits + 1] = { op = "-", line = a[i], ai = i }
			i = i - 1
		end
	end
	-- Reverse
	local rev = {}
	for k = #edits, 1, -1 do rev[#rev + 1] = edits[k] end
	return rev
end

local a = read_lines(file1)
local b = read_lines(file2)

local edits = compute_lcs(a, b)

-- Check if files are identical
local has_diff = false
for _, e in ipairs(edits) do
	if e.op ~= " " then has_diff = true; break end
end
if not has_diff then os.exit(0) end

-- Output unified diff
if unified then
	-- Group changes into hunks with context
	local hunks = {}
	local i = 1
	while i <= #edits do
		if edits[i].op ~= " " then
			local start = math.max(1, i - context)
			-- Find end of this change group
			local j = i
			while j <= #edits do
				if edits[j].op ~= " " then
					j = j + 1
				else
					-- Check if next change is within context
					local next_change = nil
					for k = j + 1, math.min(j + 2 * context, #edits) do
						if edits[k].op ~= " " then next_change = k; break end
					end
					if next_change and next_change - j <= 2 * context then
						j = next_change + 1
					else
						break
					end
				end
			end
			local finish = math.min(#edits, j - 1 + context)
			hunks[#hunks + 1] = { start = start, finish = finish }
			i = finish + 1
		else
			i = i + 1
		end
	end

	-- Print header
	io.write("--- " .. file1 .. "\n")
	io.write("+++ " .. file2 .. "\n")

	for _, hunk in ipairs(hunks) do
		-- Calculate line numbers
		local a_start, a_count, b_start, b_count = 0, 0, 0, 0
		local first_a, first_b = true, true
		for k = hunk.start, hunk.finish do
			local e = edits[k]
			if e.op == " " or e.op == "-" then
				if first_a then a_start = e.ai or (a_start + 1); first_a = false end
				a_count = a_count + 1
			end
			if e.op == " " or e.op == "+" then
				if first_b then b_start = e.bi or (b_start + 1); first_b = false end
				b_count = b_count + 1
			end
		end
		if a_start == 0 then a_start = 1 end
		if b_start == 0 then b_start = 1 end

		io.write(string.format("@@ -%d,%d +%d,%d @@\n", a_start, a_count, b_start, b_count))
		for k = hunk.start, hunk.finish do
			local e = edits[k]
			io.write(e.op .. e.line .. "\n")
		end
	end
else
	-- Normal diff output (ed-style)
	local i = 1
	while i <= #edits do
		local e = edits[i]
		if e.op == "-" then
			local start_a = e.ai
			local del_lines = { e.line }
			while i + 1 <= #edits and edits[i + 1].op == "-" do
				i = i + 1; del_lines[#del_lines + 1] = edits[i].line
			end
			-- Check if followed by adds (change)
			local add_lines = {}
			while i + 1 <= #edits and edits[i + 1].op == "+" do
				i = i + 1; add_lines[#add_lines + 1] = edits[i].line
			end
			local end_a = start_a + #del_lines - 1
			if #add_lines > 0 then
				-- Change
				local start_b = edits[i].bi - #add_lines + 1
				local end_b = edits[i].bi
				if #del_lines == 1 and #add_lines == 1 then
					io.write(start_a .. "c" .. start_b .. "\n")
				else
					io.write(start_a .. "," .. end_a .. "c" .. start_b .. "," .. end_b .. "\n")
				end
				for _, l in ipairs(del_lines) do io.write("< " .. l .. "\n") end
				io.write("---\n")
				for _, l in ipairs(add_lines) do io.write("> " .. l .. "\n") end
			else
				-- Delete
				if #del_lines == 1 then
					io.write(start_a .. "d" .. (start_a - 1) .. "\n")
				else
					io.write(start_a .. "," .. end_a .. "d" .. (start_a - 1) .. "\n")
				end
				for _, l in ipairs(del_lines) do io.write("< " .. l .. "\n") end
			end
		elseif e.op == "+" then
			local start_b = e.bi
			local add_lines = { e.line }
			while i + 1 <= #edits and edits[i + 1].op == "+" do
				i = i + 1; add_lines[#add_lines + 1] = edits[i].line
			end
			local prev_a = e.ai and e.ai or (start_b - 1)
			-- Find the a-line before this insertion
			for k = i, 1, -1 do
				if edits[k].ai then prev_a = edits[k].ai; break end
			end
			local end_b = start_b + #add_lines - 1
			if #add_lines == 1 then
				io.write(prev_a .. "a" .. start_b .. "\n")
			else
				io.write(prev_a .. "a" .. start_b .. "," .. end_b .. "\n")
			end
			for _, l in ipairs(add_lines) do io.write("> " .. l .. "\n") end
		end
		i = i + 1
	end
end

os.exit(1) -- files differ
