-- xd: bytes, in hexadecimal.
--
--   > xd file
--   > xd < file
--   > dio read 0 512 | xd
--   > xd -n 64 file        the first 64 bytes
--
-- The pager reads text and stops at the first thing that is not; a disk
-- sector, a 9P message and a font are none of them text. This is what
-- to look at those with.
--
-- plan 9's xd, one format: offset, sixteen bytes, then the printable
-- ones. A repeated line is folded to a single * the way od does it,
-- because a sector of zeroes is one fact and 32 identical lines of it
-- are the same fact 32 times.

local function die(s)
	io.stderr:write("xd: " .. s .. "\n")
	os.exit(1)
end

local limit			-- nil is "all of it"
local paths = {}
local i = 1

while arg[i] do
	local a = arg[i]

	if a == "-n" then
		limit = tonumber(arg[i + 1])
		if not limit or limit < 0 then
			die("usage: xd [-n bytes] [file...]")
		end
		i = i + 2
	elseif a:sub(1, 1) == "-" and #a > 1 then
		die("usage: xd [-n bytes] [file...]")
	else
		paths[#paths + 1] = a
		i = i + 1
	end
end

-- one line of sixteen. The two halves are built together so a short
-- last line still lines its text up under the column it belongs to.
local function line(off, s)
	local hex = {}
	local txt = {}

	for n = 1, 16 do
		local c = s:sub(n, n)

		if c == "" then
			hex[n] = "  "
			txt[n] = ""
		else
			local b = c:byte()

			hex[n] = string.format("%02x", b)
			txt[n] = (b >= 32 and b < 127) and c or "."
		end
	end
	-- grouped in eights, which is what makes a 16-byte structure
	-- countable by eye.
	return string.format("%08x  %s  %s  |%s|\n", off,
	    table.concat(hex, " ", 1, 8), table.concat(hex, " ", 9, 16),
	    table.concat(txt))
end

local off = 0
local held			-- the last line's bytes, for folding
local folding = false

local function emit(s)
	if s == held then
		if not folding then
			io.write("*\n")
			folding = true
		end
	else
		io.write(line(off, s))
		held = s
		folding = false
	end
	off = off + #s
end

-- reading is buffered and emitting is by sixteens, so the two are kept
-- apart: whatever arrives is added to a carry and drained a line at a
-- time. A read that returns nine bytes must not print a nine-byte line.
local carry = ""

local function feed(data)
	carry = carry .. data
	while #carry >= 16 do
		emit(carry:sub(1, 16))
		carry = carry:sub(17)
	end
end

local done = false

local function dump(f, what)
	while not done do
		local want = 8192

		if limit then
			local left = limit - (off + #carry)

			if left <= 0 then
				done = true
				break
			end
			if left < want then
				want = left
			end
		end

		local data, err = f:read(want)

		-- nil is end of input; nil WITH a reason is a fault, and
		-- lua's io tells them apart that way rather than by the
		-- empty string a raw read answers with.
		if not data then
			if err then
				die((what or "stdin") .. ": " ..
				    tostring(err))
			end
			break
		end
		feed(data)
	end
end

if #paths == 0 then
	dump(io.stdin)
else
	for _, path in ipairs(paths) do
		local f, err = io.open(path, "r")

		if not f then
			die(path .. ": " .. tostring(err))
		end
		dump(f, path)
		f:close()
	end
end

-- the tail, and then the end offset on a line of its own: without it a
-- dump ending in a fold does not say how long the thing was.
if #carry > 0 then
	io.write(line(off, carry))
	off = off + #carry
end
io.write(string.format("%08x\n", off))
