-- SPDX-License-Identifier: ISC

local args = arg
local pos = 1

local function peek() return args[pos] end
local function advance() local v = args[pos]; pos = pos + 1; return v end

-- forward declarations
local parse_or

local function parse_primary()
	local tok = advance()
	if tok == "(" then
		local val = parse_or()
		advance() -- consume ")"
		return val
	elseif tok == "length" then
		return tostring(#(advance() or ""))
	end
	return tok or ""
end

local function parse_mul()
	local val = parse_primary()
	local op = peek()
	while op == "*" or op == "/" or op == "%" do
		advance()
		local right = parse_primary()
		local a, b = tonumber(val) or 0, tonumber(right) or 0
		if op == "*" then val = tostring(math.floor(a * b))
		elseif op == "/" then val = tostring(math.floor(a / b))
		else val = tostring(math.floor(a % b)) end
		op = peek()
	end
	return val
end

local function parse_add()
	local val = parse_mul()
	local op = peek()
	while op == "+" or op == "-" do
		advance()
		local right = parse_mul()
		local a, b = tonumber(val) or 0, tonumber(right) or 0
		if op == "+" then val = tostring(math.floor(a + b))
		else val = tostring(math.floor(a - b)) end
		op = peek()
	end
	return val
end

local function parse_compare()
	local val = parse_add()
	local op = peek()
	while op == "=" or op == "!=" or op == "<" or op == "<=" or op == ">" or op == ">=" do
		advance()
		local right = parse_add()
		local a, b = tonumber(val), tonumber(right)
		local result
		if a and b then
			if     op == "="  then result = a == b
			elseif op == "!=" then result = a ~= b
			elseif op == "<"  then result = a < b
			elseif op == "<=" then result = a <= b
			elseif op == ">"  then result = a > b
			else result = a >= b end
		else
			if     op == "="  then result = val == right
			elseif op == "!=" then result = val ~= right
			elseif op == "<"  then result = val < right
			elseif op == "<=" then result = val <= right
			elseif op == ">"  then result = val > right
			else result = val >= right end
		end
		val = result and "1" or "0"
		op = peek()
	end
	return val
end

local function parse_and()
	local val = parse_compare()
	while peek() == "&" do
		advance()
		local right = parse_compare()
		if val == "0" or val == "" or right == "0" or right == "" then val = "0" end
	end
	return val
end

parse_or = function()
	local val = parse_and()
	while peek() == "|" do
		advance()
		local right = parse_and()
		if val == "0" or val == "" then val = right end
	end
	return val
end

local result = parse_or()
io.write(result .. "\n")
if result == "" or result == "0" then os.exit(1) end
os.exit(0)
