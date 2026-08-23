-- mkdir: make a directory, and the path down to it.
--
--	mkdir DIR...

local prog = require("prog")

local N = prog.ns() or os.exit(1)

local function die(s)
	io.stderr:write("mkdir: " .. s .. "\n")
	os.exit(1)
end

if not arg[1] then
	die("usage: mkdir DIR...")
end

for _, path in ipairs(arg) do
	local at = ""

	-- every component, so a path arrives whole rather than needing
	-- its parents made one at a time.
	for part in path:gmatch("[^/]+") do
		at = at .. "/" .. part

		local st = N:stat(at)

		if not st then
			local f, err = N:create(at, "rw", true)

			if not f then
				die(at .. ": " .. tostring(err))
			end
			f:close()
		elseif not st.dir then
			die(at .. ": exists, and is not a directory")
		end
	end
end
