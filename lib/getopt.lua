-- POSIX option parsing, in lua.
--
-- getopt.parse(argv, spec) -> flags, optind, for programs written here.
-- getopt.opts(argv, spec) iterates (opt, optarg, optind), which is
-- luaposix's contract and what the utilities ported from the host tree
-- already call. A letter in spec followed by ":" takes an argument.
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

-- Every option in argv, and where the operands start. Done in one pass
-- rather than lazily so that "--" can report the index it consumed: an
-- iterator that answers nil there cannot say it moved.
local function scan(argv, spec)
	local takes = parsespec(spec)
	local out = {}
	local i, j = 1, 2	-- argv element, and the letter within it

	while true do
		local a = argv[i]

		if a == nil or a == "-" or a:sub(1, 1) ~= "-" then
			break
		end
		if a == "--" then
			i = i + 1
			break
		end
		if j > #a then
			i, j = i + 1, 2
			goto continue
		end

		local c = a:sub(j, j)
		local optarg, why

		j = j + 1
		if takes[c] == nil then
			optarg, why, c = c, "unknown", "?"
		elseif takes[c] then
			if j <= #a then
				-- the rest of this element is the argument,
				-- so the cluster ends here
				optarg = a:sub(j)
				j = #a + 1
			else
				optarg = argv[i + 1]
				if optarg == nil then
					optarg, why, c = c, "missing", "?"
				else
					i, j = i + 1, #optarg + 1
				end
			end
		end
		if j > #(argv[i] or "") then
			i, j = i + 1, 2
		end
		out[#out + 1] = { opt = c, arg = optarg, why = why, next = i }
		::continue::
	end
	return out, i
end

-- luaposix's iterator. optind is the index of the first argv element not
-- yet consumed, so a caller that keeps the last one sees where the
-- operands start. An unknown letter and a missing argument both answer
-- "?" with the letter as optarg.
function M.opts(argv, spec)
	local items = scan(argv, spec)
	local n = 0

	return function()
		n = n + 1

		local it = items[n]

		if not it then
			return nil
		end
		return it.opt, it.arg, it.next
	end
end

-- flags[letter] is true for a flag and the string for one that took an
-- argument; optind is where the operands start. Right for "--", which
-- the iterator cannot report. A repeated option keeps the last, so a
-- program collecting them all wants opts instead.
function M.parse(argv, spec)
	local items, optind = scan(argv, spec)
	local flags = {}

	for _, it in ipairs(items) do
		if it.opt == "?" then
			return nil, (it.why == "missing" and
			    "option -" .. it.arg .. " wants an argument" or
			    "unknown option -" .. it.arg)
		end
		flags[it.opt] = it.arg or true
	end
	return flags, optind
end

return M
