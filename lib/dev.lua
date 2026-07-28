-- dev: the backend interface every filesystem here implements.
--
-- this is Plan 9's Dev/devtab, and it is the load-bearing abstraction --
-- NOT 9P. a Chan is (backend, handle); a namespace maps names to Chans;
-- and 9P is one backend that happens to forward over a byte channel,
-- rather than the thing everything else is built on. that ordering is
-- what lets a local filesystem work with no wire protocol involved, and
-- lets a remote one appear later as just another backend.
--
-- three consumers have to agree on this shape:
--   ns.lua        resolves a path to (backend, handle) and reads/writes
--   ninep.lua     serves a backend out to real 9P clients
--   the backends  espfs, a synthetic tree, eventually procfs/consfs
--
-- the interface is fid-shaped rather than path-shaped (walk returns a
-- handle; read takes an explicit offset) because that is what the 9P
-- server needs, and a path-based backend can satisfy it trivially by
-- making its handle a path. going the other way -- deriving fids from a
-- path-only interface -- needs state the backend does not have.
--
-- ---- the interface ----
--
--   attach()              -> h, err        root handle
--   walk(h, name)         -> h, err        one element; "." and ".." legal
--   stat(h)               -> st, err       {name=, size=, dir=}
--   open(h, mode)         -> h, err        mode "r" | "w" | "rw"
--   create(h, name, mode) -> h, err        in directory h; returns it OPEN
--   read(h, off, n)       -> data, err     "" means end of file
--   write(h, off, data)   -> n, err
--   readdir(h)            -> {st, ...}, err
--   clunk(h)                               release; never fails
--
-- create both makes and opens, like 9P's Tcreate, because every backend
-- that can do one can do the other and splitting them invites a window
-- where the file exists but nothing holds it. it was missing from the
-- first draft of this interface, and the omission showed up immediately:
-- with only open(), a caller wanting a new file has to fabricate a
-- handle out of a backend's private representation. there is no `>
-- newfile` without this.
--
-- NOT required, and deliberately: remove() and wstat(). a shell wants
-- `rm`, so remove() is the next thing this interface should grow -- but
-- espfs cannot implement it yet (EFI_FILE_PROTOCOL has Delete and
-- src/fs.c does not wrap it), and requiring a method no real backend can
-- provide would just mean every backend stubbing it. backends MAY
-- provide either; dev.check does not demand them, so check before
-- calling.
--
-- every call returns nil plus a message on failure, never raises. a
-- backend that raises is a bug, because ns.lua resolves paths on behalf
-- of whoever asked and must not inherit their error handling.
--
-- offsets are explicit and handles carry no position, matching 9P. a
-- stream with a position is a convenience ns.lua can layer on top; it is
-- not something backends should each reinvent differently.

local M = {}

local REQUIRED = {
	"attach", "walk", "stat", "open", "create", "read", "write",
	"readdir", "clunk",
}

-- validate at mount time rather than at first use. a missing method
-- otherwise surfaces as "attempt to call a nil value" three layers deep,
-- in whichever unlucky operation happened to need it first.
function M.check(backend, name)
	name = name or "backend"
	if type(backend) ~= "table" then
		return nil, name .. ": not a table"
	end
	for _, m in ipairs(REQUIRED) do
		if type(backend[m]) ~= "function" then
			return nil, name .. ": missing " .. m .. "()"
		end
	end
	return backend
end

-- walk several elements, which every consumer needs and none should
-- write twice. empty elements and "." are skipped, so "/a//b/./c" walks
-- a, b, c. stops at the first failure and reports which element failed,
-- since "no such file" without the name is a poor error.
function M.walkpath(backend, h, path)
	for elem in tostring(path):gmatch("[^/]+") do
		if elem ~= "." then
			local nh, err = backend.walk(h, elem)

			if not nh then
				return nil, (err or "walk failed") ..
				    " at '" .. elem .. "'"
			end
			h = nh
		end
	end
	return h
end

-- ---- the reference backend: an in-memory tree ----
--
-- doubles as the executable definition of the interface. a tree is
-- nested tables; a string leaf is a file's contents:
--
--   dev.mem({ README = "hi\n", lib = { ["a.lua"] = "-- a" } })
--
-- writes go to the in-memory copy and are lost on exit, which is the
-- point: it is for tests, for synthetic trees, and for proving the
-- interface is not accidentally shaped around one real filesystem.

function M.mem(tree)
	local B = {}

	-- a handle is { node = <table|string>, name = , path = }
	local function h_of(node, name, path)
		return { node = node, name = name, path = path }
	end

	function B.attach()
		return h_of(tree, "/", "/")
	end

	function B.walk(h, name)
		if type(h.node) ~= "table" then
			return nil, "not a directory"
		end
		if name == ".." then
			-- the mem tree keeps no parent links; ns.lua resolves
			-- ".." before it ever reaches a backend, and a 9P
			-- client walking ".." off the root should stay put.
			return h
		end
		local child = h.node[name]

		if child == nil then
			return nil, "no such file"
		end
		return h_of(child, name,
		    (h.path == "/" and "/" or h.path .. "/") .. name)
	end

	function B.stat(h)
		local isdir = type(h.node) == "table"

		return {
			name = h.name,
			dir = isdir,
			size = isdir and 0 or #h.node,
		}
	end

	function B.open(h, mode)
		if mode ~= "r" and type(h.node) == "table" then
			return nil, "is a directory"
		end
		return h
	end

	function B.create(h, name, mode)
		if type(h.node) ~= "table" then
			return nil, "not a directory"
		end
		if h.node[name] ~= nil then
			return nil, "already exists"
		end
		h.node[name] = ""
		return B.open(B.walk(h, name), mode or "rw")
	end

	function B.read(h, off, n)
		if type(h.node) == "table" then
			return nil, "is a directory"
		end
		return h.node:sub(off + 1, off + n)
	end

	function B.write(h, off, data)
		if type(h.node) == "table" then
			return nil, "is a directory"
		end
		-- find our slot in the parent so the tree, not just this
		-- handle, sees the change
		local parent, key = tree, nil

		for elem in h.path:gmatch("[^/]+") do
			if type(parent[elem]) == "table" then
				parent = parent[elem]
			else
				key = elem
			end
		end
		if not key then
			return nil, "cannot locate file in tree"
		end
		local cur = parent[key]
		local head = cur:sub(1, off) .. string.rep("\0", off - #cur)

		parent[key] = head .. data .. cur:sub(off + #data + 1)
		h.node = parent[key]
		return #data
	end

	function B.readdir(h)
		if type(h.node) ~= "table" then
			return nil, "not a directory"
		end
		local out = {}

		for name, child in pairs(h.node) do
			local isdir = type(child) == "table"

			out[#out + 1] = {
				name = name,
				dir = isdir,
				size = isdir and 0 or #child,
			}
		end
		table.sort(out, function(a, b) return a.name < b.name end)
		return out
	end

	function B.clunk(_)
	end

	return B
end

return M
