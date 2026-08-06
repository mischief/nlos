-- romfs: the embedded image as a filesystem, read-only.
--
--   /lib/dos.lua      the modules the kernel was built with
--   /bin/smiley.lua   the programs
--   /task/fb.lua      the driver tasks
--
-- A local dev backend, like lib/procfs.lua and for the same reason: it
-- serves data every proc can already reach, so putting a server and a
-- port in front of it would buy nothing and cost a round trip per read.
-- Mounted with ns:mount("/", romfs.new(), "romfs") in whoever wants it.
--
-- An unprivileged proc has no io.open: kernel_strip_io removes it, so
-- files arrive through a mount rather than through ambient authority.
-- Where the files live in the app image, this is the mount. require()
-- reads the same bytes in C, below that stripping, so without this a
-- proc can execute a module it knows the name of but cannot list a
-- directory or read a program it means to spawn.
--
-- Read-only, because the image is in flash and fixed at build time.
-- create() and write() refuse rather than failing late, so a caller
-- learns at the mount what it is dealing with.

local dev = require("dev")
local rom = require("los.rom")

local M = {}

-- the flat path list becomes a tree once, at mount: 28 files today, and
-- a walk per path element would otherwise rescan the whole list.
local function index()
	local dirs, files = { ["/"] = {} }, {}

	for _, path in ipairs(rom.list()) do
		files[path] = true

		local parent = "/"

		for part in path:gmatch("[^/]+") do
			local child = (parent == "/") and ("/" .. part) or
			    (parent .. "/" .. part)

			dirs[parent] = dirs[parent] or {}
			dirs[parent][part] = true
			if child ~= path then
				parent = child
				dirs[parent] = dirs[parent] or {}
			end
		end
	end
	return dirs, files
end

function M.new()
	local dirs, files = index()
	local B = {}

	local function isdir(p)
		return dirs[p] ~= nil and not files[p]
	end

	function B.attach()
		return { path = "/" }
	end

	function B.walk(h, name)
		if name == "." then
			return { path = h.path }
		end
		if name == ".." then
			local up = h.path:match("^(.*)/[^/]*$")

			return { path = (up == "" or up == nil) and "/" or up }
		end
		if not isdir(h.path) then
			dev.error(dev.Enotdir)
		end

		local p = (h.path == "/") and ("/" .. name) or
		    (h.path .. "/" .. name)

		if not files[p] and not dirs[p] then
			dev.error(dev.Enonexist)
		end
		return { path = p }
	end

	function B.stat(h)
		local name = h.path:match("[^/]+$") or "/"

		if isdir(h.path) then
			return { name = name, size = 0, dir = true }
		end
		return { name = name, size = rom.size(h.path) or 0,
		    dir = false }
	end

	-- the contents are taken at open and held in the handle, so the
	-- handle owns its own lifetime as lib/dev.lua requires. The data
	-- is in flash and does not change.
	function B.open(h, mode)
		if mode and mode ~= "r" then
			dev.error(dev.Eperm)
		end
		if isdir(h.path) then
			return { path = h.path }
		end

		local d = rom.read(h.path)

		if not d then
			dev.error(dev.Enonexist)
		end
		return { path = h.path, data = d }
	end

	function B.read(h, off, n)
		if not h.data then
			dev.error(dev.Ebadusefd)
		end
		return h.data:sub(off + 1, off + n)
	end

	-- refused rather than absent: lib/dev.lua checks the whole set at
	-- mount, so a backend missing these cannot be mounted at all.
	function B.create()
		dev.error(dev.Eperm)
	end

	function B.write()
		dev.error(dev.Eperm)
	end

	-- nothing to release: a handle is a path and, once open, a string
	-- the collector owns.
	function B.clunk()
	end

	function B.readdir(h)
		if not isdir(h.path) then
			dev.error(dev.Enotdir)
		end

		local out = {}

		for name in pairs(dirs[h.path] or {}) do
			local p = (h.path == "/") and ("/" .. name) or
			    (h.path .. "/" .. name)

			out[#out + 1] = { name = name,
			    size = files[p] and (rom.size(p) or 0) or 0,
			    dir = not files[p] }
		end
		table.sort(out, function(a, b)
			return a.name < b.name
		end)
		return out
	end

	return B
end

return M
