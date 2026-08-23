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

local prog = require("prog")
local getopt = require("getopt")

-- Rooted where the shell is, so a relative name works: prog.ns()
-- resolves against the program's cwd (see lib/prog.lua).
local N = assert(prog.ns(), "rm: no namespace")

-- after "--" everything is a name, even if it starts with a dash
local flags, optind = getopt.parse(arg, "f")

if not flags then
	io.stderr:write("usage: rm [-f] file...\n")
	os.exit(2)
end

local force = flags.f
local paths = table.move(arg, optind, #arg, 1, {})

if #paths == 0 then
	io.stderr:write("usage: rm [-f] file...\n")
	os.exit(2)
end

local status = 0

for _, p in ipairs(paths) do
	local ok, err = N:remove(p)

	if not ok and not force then
		io.stderr:write(("rm: %s: %s\n"):format(p, tostring(err)))
		status = 1
	end
end

os.exit(status)
