-- devtree: building, mounting and serving a tree.
--
-- check() validates a backend at mount time, subtree() roots a mount
-- below a prefix, readonly() offers one backend at two authority
-- levels, and mem() makes a synthetic tree from nested tables.

local dev = require("dev")

local M = {}

-- the error codes and raise idiom belong to the interface, not to this
-- half of it.
local function error_(msg) return dev.error(msg) end


-- subtree(backend, root) -> a backend serving root and what is under it.
--
-- plan 9 binds a piece of a file server; this is that piece. It belongs
-- here rather than in each backend, because attaching somewhere other
-- than the top is a property of the mount and not of what is mounted --
-- so mem, romfs, mnt and anything written later gain it without being
-- told about it. lib/ns.lua applies it whenever a mount names a root.
--
-- Everything but attach passes through untouched: a handle is the
-- wrapped backend's own, and the subtree is decided once, when the
-- namespace attaches.
--
-- Not a permission. A namespace shows what its mounts show, and this
-- narrows one of them; a proc that also holds the right the mount was
-- built from can still talk to the whole server behind it. Attenuating
-- that is a proxy proc's job, not a namespace's.
function M.subtree(backend, root)
	local names = dev.elements(root or "/")

	if #names == 0 then
		return backend
	end

	local sub = {}

	for k, v in pairs(backend) do
		sub[k] = v
	end
	function sub.attach()
		return dev.walknames(backend, backend.attach(), names)
	end

	-- ".." is resolved lexically by lib/ns.lua before any backend sees
	-- a path, so a walk cannot climb out of here. A caller driving a
	-- backend directly, below the namespace, is on its own -- as it is
	-- for every other rule the namespace keeps.
	return sub
end

-- walk a list of names one at a time.
--
-- no error checking, which is the point of the idiom: a failing walk
-- raises from inside the backend and this function never sees it. the
-- element name is appended on the way past so the message says which
-- component was missing, since "file does not exist" without the name is
-- a poor error -- that is plan 9's own habit of adding context while
-- unwinding, minus the frame bookkeeping.
--
-- exposed because a server implementing walkmany() over a backend that
-- has none needs exactly this loop, and the error text has to match.

-- ---- attenuation: the same tree, read-only ----
--
-- a wrapper that forwards every read-shaped call and raises Eperm on
-- everything that could change the tree. it is a thin filter rather than
-- a reimplementation on purpose: there is nothing to keep in step with
-- the backend it wraps, and no second traversal to get subtly different.
--
-- open() is the interesting one. a mode other than "r" is refused, so a
-- caller cannot get a writable handle and then use it -- which matters
-- because create() and open("w") are the only ways a handle capable of
-- writing comes into existence. with those closed, write() is
-- unreachable anyway and refusing it too is belt and braces.
--
-- this is what makes one filesystem serveable at two authority levels
-- (see lib/srv.lua's readonly op): the difference between a client that
-- may write the ESP and one that may not becomes WHICH RIGHT IT HOLDS,
-- with no permission bit anywhere and nothing to check per call.
function M.readonly(B)
	local RO = {}

	local function refuse()
		error_(dev.Eperm)
	end

	for k, v in pairs(B) do
		RO[k] = v
	end

	RO.write = refuse
	RO.create = refuse
	-- absent, not stubs: a caller checks before calling, and a tree
	-- that cannot be changed says so by not offering the methods.
	RO.remove = nil
	RO.wstat = nil
	RO.rename = nil

	function RO.open(h, mode)
		if mode ~= "r" then
			error_(dev.Eperm)
		end
		return B.open(h, "r")
	end

	-- a backend offering walkmany keeps it: walking is a read.
	return RO
end

-- ---- the reference backend: an in-memory tree ----
--
-- doubles as the executable definition of the interface. a tree is
-- nested tables; a string leaf is a file's contents:
--
--   devtree.mem({ README = "hi\n", lib = { ["a.lua"] = "-- a" } })
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
			error_(dev.Enotdir)
		end
		if name == ".." then
			-- the mem tree keeps no parent links; ns.lua resolves
			-- ".." before it ever reaches a backend, and a 9P
			-- client walking ".." off the root should stay put.
			return h
		end
		local child = h.node[name]

		if child == nil then
			error_(dev.Enonexist)
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
			error_(dev.Eisdir)
		end
		return dev.closable(B, h)
	end

	function B.create(h, name, mode, dir)
		if type(h.node) ~= "table" then
			error_(dev.Enotdir)
		end
		if h.node[name] ~= nil then
			error_(dev.Eexist)
		end
		h.node[name] = dir and {} or ""
		return B.open(B.walk(h, name), mode or "rw")
	end

	function B.read(h, off, n)
		if type(h.node) == "table" then
			error_(dev.Eisdir)
		end
		return h.node:sub(off + 1, off + n)
	end

	function B.write(h, off, data)
		if type(h.node) == "table" then
			error_(dev.Eisdir)
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
			error_(dev.Eio)
		end
		local cur = parent[key]
		local head = cur:sub(1, off) .. string.rep("\0", off - #cur)

		parent[key] = head .. data .. cur:sub(off + #data + 1)
		h.node = parent[key]
		return #data
	end

	function B.readdir(h)
		if type(h.node) ~= "table" then
			error_(dev.Enotdir)
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

	-- the parent table holding this handle's entry, and the key in it.
	-- The root has no parent, so it answers nil and callers refuse.
	local function locate(h)
		local names = dev.elements(h.path)
		local parent = tree

		for i = 1, #names - 1 do
			parent = parent[names[i]]
			if type(parent) ~= "table" then
				error_(dev.Enotdir)
			end
		end
		return parent, names[#names]
	end

	function B.remove(h)
		local parent, key = locate(h)

		if not key then
			error_(dev.Eperm)
		end
		if parent[key] == nil then
			error_(dev.Enonexist)
		end
		parent[key] = nil
		return true
	end

	-- only the name, which is all 9P's Twstat carries that this tree
	-- has anywhere to keep. An occupied name is refused rather than
	-- replaced: unix's rename would overwrite, and no backend here can
	-- do that in one step, so all of them say so instead.
	function B.wstat(h, st)
		if not st or st.name == nil then
			return true
		end

		local parent, key = locate(h)

		if not key then
			error_(dev.Eperm)
		end
		if parent[key] == nil then
			error_(dev.Enonexist)
		end
		if st.name ~= key and parent[st.name] ~= nil then
			error_(dev.Eexist)
		end
		parent[key], parent[st.name] = nil, parent[key]
		return true
	end

	function B.rename(dsrc, name, ddst, newname)
		if type(dsrc.node) ~= "table" or type(ddst.node) ~= "table" then
			error_(dev.Enotdir)
		end
		if dsrc.node[name] == nil then
			error_(dev.Enonexist)
		end
		if ddst.node[newname] ~= nil then
			error_(dev.Eexist)
		end
		ddst.node[newname], dsrc.node[name] = dsrc.node[name], nil
		return true
	end

	function B.clunk(_)
	end

	return B
end

return M
