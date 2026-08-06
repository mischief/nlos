-- rm: take a file away.
--
--   > rm /etc/wifi.lua
--   > rm -f /tmp/maybe
--
-- Through the namespace, which is the only path an unprivileged proc
-- has to a file: prog.ns() is what this program was handed, and
-- NS:remove is the call. A mount that has no remove -- lib/romfs.lua,
-- or anything mounted read-only -- refuses with "not implemented",
-- which is a different answer from "no such file" and is reported as
-- one.
--
-- No -r. Removing a tree means walking it, and a walk that deletes as
-- it goes is the kind of thing that should be written deliberately
-- rather than added to the first version of rm. A directory is refused
-- by the backend, not here, so it says so in the same words a
-- filesystem would.

local unistd = require("posix.unistd")
local prog = require("prog")

-- Rooted where the shell is, so a relative name works: prog.ns()
-- resolves against the program's cwd (see lib/prog.lua).
local N = assert(prog.ns(), "rm: no namespace")

local force = false
local paths = {}

for _, a in ipairs(arg) do
	if a == "-f" then
		force = true
	elseif a == "--" then
		-- everything after is a name, even if it starts with -
		force = force
	elseif a:sub(1, 1) == "-" and #a > 1 then
		unistd.write(2, "usage: rm [-f] file...\n")
		os.exit(2)
	else
		paths[#paths + 1] = a
	end
end

if #paths == 0 then
	unistd.write(2, "usage: rm [-f] file...\n")
	os.exit(2)
end

local status = 0

for _, p in ipairs(paths) do
	local ok, err = N:remove(p)

	if not ok and not force then
		unistd.write(2, ("rm: %s: %s\n"):format(p, tostring(err)))
		status = 1
	end
end

os.exit(status)
