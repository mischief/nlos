-- POSIX option parsing, in lua.
--
-- getopt.opts(argv, spec) iterates (opt, optarg, optind). A letter in
-- spec followed by ":" takes an argument, attached or separate. An
-- unknown letter and a missing argument both answer "?" with the letter
-- as optarg, which is what the utilities check for.
local M = {}

local function parsespec(spec)
	local takes = {}
	local i = 1

	while i <= #spec do
		local c = spec:sub(i, i)

		if spec:sub(i + 1, i + 1) == ":" then
			takes[c] = true
			i = i + 2
		else
			takes[c] = false
			i = i + 1
		end
	end
	return takes
end

-- optind is the index of the first argv element not yet consumed, so a
-- caller that keeps the last one sees where the operands start. "--"
-- ends the options and is itself consumed; a lone "-" is an operand.
function M.opts(argv, spec)
	local takes = parsespec(spec)
	local i, j = 1, 2	-- argv element, and the letter within it

	return function()
		while true do
			local a = argv[i]

			if a == nil or a == "-" or a:sub(1, 1) ~= "-" then
				return nil
			end
			if a == "--" then
				i = i + 1
				return nil
			end
			if j <= #a then
				break
			end
			i, j = i + 1, 2
		end

		local a = argv[i]
		local c = a:sub(j, j)
		local optarg

		j = j + 1
		if takes[c] == nil then
			optarg, c = c, "?"
		elseif takes[c] then
			if j <= #a then
				-- the rest of this element is the argument,
				-- so the cluster ends here
				optarg = a:sub(j)
				j = #a + 1
			else
				optarg = argv[i + 1]
				if optarg == nil then
					optarg, c = c, "?"
				else
					i, j = i + 1, #optarg + 1
				end
			end
		end
		if j > #(argv[i] or "") then
			i, j = i + 1, 2
		end
		return c, optarg, i
	end
end

return M
