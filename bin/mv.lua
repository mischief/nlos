-- mv: give a file another name, or put it somewhere else.
--
--   > mv notes.txt notes.old
--   > mv a.lua b.lua /lib
--
-- rename first, and where the namespace refuses -- two mounts, or a
-- filesystem that cannot move between its own directories -- copy and
-- then remove, as mv(1) does when rename(2) answers EXDEV.

-- The fallback is not atomic. A copy that dies halfway leaves a short
-- file at the new name and the whole one at the old.

local unistd = require("posix.unistd")
local prog = require("prog")

local N = assert(prog.ns(), "mv: no namespace")

local function die(msg)
	unistd.write(2, "mv: " .. msg .. "\n")
	os.exit(1)
end

local function usage()
	unistd.write(2, "usage: mv file... target\n")
	os.exit(2)
end

local args = {}

for _, a in ipairs(arg) do
	if a == "--" then
		args = args
	elseif a:sub(1, 1) == "-" and #a > 1 then
		usage()
	else
		args[#args + 1] = a
	end
end

if #args < 2 then
	usage()
end

local target = table.remove(args)
local tst = N:stat(target)
local todir = tst and tst.dir

if #args > 1 and not todir then
	die(target .. ": not a directory")
end

local function basename(p)
	return (p:match("([^/]+)/*$")) or p
end

-- 16K a time, so a file larger than memory still moves. The read ends
-- the copy short only at end of file, which is the contract every
-- backend here is held to.
local function copy(from, to)
	local src, serr = N:open(from, "r")

	if not src then
		return nil, serr
	end

	local dst, derr = N:create(to, "w")

	if not dst then
		src:close()
		return nil, derr
	end

	while true do
		local chunk, rerr = src:read(16384)

		if not chunk then
			src:close()
			dst:close()
			return nil, rerr
		end
		if chunk == "" then
			break
		end

		local n, werr = dst:write(chunk)

		if not n or n < #chunk then
			src:close()
			dst:close()
			return nil, werr or "short write"
		end
	end
	src:close()
	dst:close()
	return true
end

local status = 0

for _, from in ipairs(args) do
	local to = todir and
	    ((target == "/" and "" or target) .. "/" .. basename(from)) or target
	local ok, err = N:rename(from, to)

	if not ok then
		-- what the namespace says it will not do, rather than what
		-- it could not do: a missing file must not be copied over.
		local st = N:stat(from)

		if not st then
			unistd.write(2, ("mv: %s: %s\n"):format(from,
			    tostring(err)))
			status = 1
			goto continue
		end
		if st.dir then
			unistd.write(2, ("mv: %s: cannot move a directory here"
			    .. " (%s)\n"):format(from, tostring(err)))
			status = 1
			goto continue
		end

		local copied, cerr = copy(from, to)

		if not copied then
			unistd.write(2, ("mv: %s: %s\n"):format(from,
			    tostring(cerr)))
			status = 1
			goto continue
		end

		local gone, rerr = N:remove(from)

		if not gone then
			unistd.write(2, ("mv: %s copied but not removed: %s\n")
			    :format(from, tostring(rerr)))
			status = 1
		end
	end
	::continue::
end

os.exit(status)
