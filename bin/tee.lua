-- SPDX-License-Identifier: ISC
local files = {}

for _, path in ipairs(arg) do
	local f, err = io.open(path, "w")

	if not f then
		io.stderr:write("tee: " .. path .. ": " ..
		    tostring(err) .. "\n")
		os.exit(1)
	end
	files[#files + 1] = f
end

-- "L" keeps the newline, so what goes out is what came in. A byte count
-- would fill to that count before answering, and tee is meant to pass
-- each line through as it arrives.
for data in io.stdin:lines("L") do
	io.write(data)
	for _, f in ipairs(files) do
		f:write(data)
	end
end

for _, f in ipairs(files) do
	f:close()
end
