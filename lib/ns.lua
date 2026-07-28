-- ns: per-proc namespaces. names to backends, which is the piece we were
-- actually missing.
--
-- our rights table already has exactly the shape of a plan 9 fd table:
-- a per-proc small integer indexing a kernel object. what a kport lacks
-- next to a Chan is any notion of "which file on which server" -- an fd
-- is a port plus that convention. and a namespace, in plan 9, is the
-- Pgrp: a map from names to Chans. we had the bundle of handles all
-- along and no name map, so this is the name map.
--
-- a namespace is a list of (prefix -> backend) mounts. resolving a path
-- picks the longest matching prefix and walks the remainder inside that
-- backend, so mounting is genuinely just naming and no backend ever
-- learns it was mounted somewhere.
--
-- ---- errors: this is the seam ----
--
-- backends RAISE (see lib/dev.lua -- plan 9's error() idiom, since
-- threading nil+err through a five-frame path resolution is exactly the
-- noise it exists to delete). this module's public calls are the entry
-- point, so each one pcalls exactly once and RETURNS nil plus the
-- message, which is lua's own convention for an expected failure and
-- what io.open, caps.lua, http and dns all already do here.
--
-- so: raise inward, return outward. a caller who prefers raising writes
--
--	local f = assert(ns:open(path))
--
-- which is idiomatic, rather than this module offering two APIs.
--
-- ---- unions ----
--
-- several backends may share a prefix, plan 9 style. mount() takes an
-- order -- "replace" (the default), "before" or "after", matching MREPL,
-- MBEFORE and MAFTER -- and lookups try each member in turn until one
-- succeeds. readdir merges them, first mount to claim a name wins.
--
-- the mount table is ALSO a contributor to readdir, and that is what
-- makes a mount point visible. mounting procfs at /proc creates nothing
-- on the filesystem serving /, so without this `ls /` would not show
-- proc even though `cd /proc` worked. plan 9 avoids the question by only
-- letting you mount onto a directory that already exists -- its root is
-- devroot, a real device with a built-in Dirtab listing proc, dev, net
-- and friends. ours is derived from the mount table instead of fixed,
-- so it needs no bootstrap step and dynamic mounts appear on their own.
--
-- note that unions alone would NOT have fixed that: even with them,
-- something still has to contribute the name at /. the win is that with
-- unions it stops being a special case in readdir and becomes one more
-- contributor.
--
-- ---- what is not here yet ----
--
-- remove(), which needs both a backend method and
-- EFI_FILE_PROTOCOL->Delete wrapped in src/fs.c. see
-- docs/shell-namespace-draft.md.

local dev = require("dev")

local M = {}

-- ---- paths ----

-- resolve "." and ".." LEXICALLY, before any backend sees the path.
-- that is deliberate and matters at mount boundaries: ".." out of a
-- mounted filesystem must land in the mounting namespace, not in
-- whatever the backend thinks its parent is. it also means ".." can
-- never escape a mount, because by the time a backend is involved the
-- path has already been flattened.
local function clean(path)
	local parts = {}

	for elem in tostring(path):gmatch("[^/]+") do
		if elem == ".." then
			if #parts > 0 then
				table.remove(parts)
			end
			-- ".." at the root stays at the root
		elseif elem ~= "." then
			parts[#parts + 1] = elem
		end
	end
	return "/" .. table.concat(parts, "/")
end

M.clean = clean

-- ---- the open file: our Chan ----
--
-- backends take explicit offsets and hold no position, matching 9P. a
-- position is a convenience, so it lives here once rather than in every
-- backend differently.

local File = {}

File.__index = File
File.__close = function(f)
	f:close()
end

function File:read(n)
	local ok, res = pcall(self.B.read, self.h, self.pos, n or 4096)

	if not ok then
		return nil, res
	end
	self.pos = self.pos + #res
	return res
end

function File:write(data)
	local ok, res = pcall(self.B.write, self.h, self.pos, data)

	if not ok then
		return nil, res
	end
	self.pos = self.pos + res
	return res
end

function File:seek(whence, off)
	off = off or 0
	if whence == "set" or whence == nil then
		self.pos = off
	elseif whence == "cur" then
		self.pos = self.pos + off
	elseif whence == "end" then
		local st, err = self:stat()

		if not st then
			return nil, err
		end
		self.pos = st.size + off
	else
		return nil, dev.Ebadarg
	end
	return self.pos
end

function File:stat()
	local ok, res = pcall(self.B.stat, self.h)

	if not ok then
		return nil, res
	end
	return res
end

function File:readdir()
	local ok, res = pcall(self.B.readdir, self.h)

	if not ok then
		return nil, res
	end
	return res
end

-- idempotent: closing twice is not an error, because __close will run
-- even on a path that already closed explicitly.
function File:close()
	if self.h then
		pcall(self.B.clunk, self.h)
		self.h = nil
	end
end

-- ---- the namespace ----

local NS = {}

NS.__index = NS

function M.new()
	return setmetatable({ mounts = {} }, NS)
end

-- mount(prefix, backend, kind, args, order)
--
-- order is "replace" (default), "before" or "after" -- plan 9's MREPL,
-- MBEFORE and MAFTER. before/after union with whatever is already there;
-- replace evicts it.
--
-- kind/args are optional and only used by describe(): they record how to
-- rebuild this backend in another proc. a mount without them still
-- works, it just cannot be inherited.
function NS:mount(prefix, backend, kind, args, order)
	local ok, err = pcall(dev.check, backend, kind or "backend")

	if not ok then
		return nil, err
	end
	prefix = clean(prefix)
	order = order or "replace"

	local entry = {
		prefix = prefix, B = backend, kind = kind, args = args,
	}

	if order == "replace" then
		for i = #self.mounts, 1, -1 do
			if self.mounts[i].prefix == prefix then
				table.remove(self.mounts, i)
			end
		end
		self.mounts[#self.mounts + 1] = entry
		return true
	end

	-- find the span already at this prefix; union order is list order
	local first, last

	for i, m in ipairs(self.mounts) do
		if m.prefix == prefix then
			first = first or i
			last = i
		end
	end
	if not first then
		self.mounts[#self.mounts + 1] = entry
	elseif order == "before" then
		table.insert(self.mounts, first, entry)
	elseif order == "after" then
		table.insert(self.mounts, last + 1, entry)
	else
		return nil, dev.Ebadarg
	end
	return true
end

function NS:unmount(prefix)
	prefix = clean(prefix)
	for i, m in ipairs(self.mounts) do
		if m.prefix == prefix then
			table.remove(self.mounts, i)
			return true
		end
	end
	return nil, "not mounted"
end

-- if `path` is a proper prefix of a mount, return the next component of
-- that mount below it. that is how a mount point becomes visible:
-- mounting procfs at /proc does not create anything on the filesystem
-- serving /, so nothing would list it, and `ls /` would not show proc
-- even though `cd /proc` worked.
--
-- plan 9 dodges this by only letting you mount onto a directory that
-- already exists, so the mount point is always already listed. we do not
-- want that rule -- it would mean creating an empty /proc on the ESP --
-- so the namespace, which is the thing that knows the mount exists,
-- synthesises the entry instead.
--
-- it returns the FIRST component, so /mnt/host mounted with nothing at
-- /mnt still makes "mnt" appear in /, and /mnt itself behaves as a
-- directory containing "host".
local function child_under(path, prefix)
	if prefix == path then
		return nil		-- the directory itself, not a child
	end

	local base = (path == "/") and "/" or (path .. "/")

	if prefix:sub(1, #base) ~= base then
		return nil
	end
	return prefix:sub(#base + 1):match("^[^/]+")
end

-- every mount point visible directly under `path`, as stat entries
function NS:mountpoints(path)
	local out, seen = {}, {}

	for _, m in ipairs(self.mounts) do
		local name = child_under(path, m.prefix)

		if name and not seen[name] then
			seen[name] = true
			out[#out + 1] = { name = name, dir = true, size = 0 }
		end
	end
	return out
end

-- longest matching prefix wins, so /mnt/host beats / for /mnt/host/x.
-- returns EVERY mount at that prefix, in union order, and the path
-- relative to them.
function NS:lookup(path)
	path = clean(path)

	local bestlen

	for _, m in ipairs(self.mounts) do
		local p = m.prefix
		local matches

		if p == "/" then
			matches = true
		elseif path == p then
			matches = true
		else
			matches = path:sub(1, #p) == p and
			    path:sub(#p + 1, #p + 1) == "/"
		end
		if matches and (not bestlen or #p > bestlen) then
			bestlen = #p
		end
	end
	if not bestlen then
		return nil, "no mount for " .. path
	end

	local group = {}
	local prefix

	for _, m in ipairs(self.mounts) do
		if #m.prefix == bestlen then
			local p = m.prefix
			local matches = (p == "/") or (path == p) or
			    (path:sub(1, #p) == p and
			     path:sub(#p + 1, #p + 1) == "/")

			if matches then
				group[#group + 1] = m
				prefix = p
			end
		end
	end
	local rest = prefix == "/" and path or path:sub(#prefix + 1)

	return group, rest
end

-- resolve to (backend, handle), trying each union member in order and
-- taking the first that resolves -- plan 9's semantics. raises, because
-- it is called from inside the other methods; the public wrappers pcall.
function NS:walk(path)
	local group, rest = self:lookup(path)

	if not group then
		dev.error(rest)
	end

	local lasterr = dev.Enonexist

	for _, m in ipairs(group) do
		local ok, res = pcall(function()
			return dev.walkpath(m.B, m.B.attach(), rest)
		end)

		if ok then
			return m.B, res
		end
		lasterr = res
	end
	dev.error(tostring(lasterr))
end

-- ---- public API: each of these pcalls exactly once ----

function NS:open(path, mode)
	mode = mode or "r"

	local ok, res, h = pcall(function()
		local B, hh = self:walk(path)

		return B, B.open(hh, mode)
	end)

	if not ok then
		return nil, res
	end
	return setmetatable({ B = res, h = h, pos = 0, path = clean(path) },
	    File)
end

-- create and open, like 9P's Tcreate and dev's create.
function NS:create(path, mode)
	local cleaned = clean(path)
	local dir, name = cleaned:match("^(.*)/([^/]+)$")

	if not name then
		return nil, dev.Ebadarg
	end
	if dir == "" then
		dir = "/"
	end

	local ok, res, h = pcall(function()
		local B, dh = self:walk(dir)

		return B, B.create(dh, name, mode or "rw")
	end)

	if not ok then
		return nil, res
	end
	return setmetatable({ B = res, h = h, pos = 0, path = cleaned }, File)
end

function NS:stat(path)
	local ok, res = pcall(function()
		local B, h = self:walk(path)
		local st = B.stat(h)

		B.clunk(h)
		return st
	end)

	if not ok then
		-- same reasoning as readdir: a path with mounts below it is a
		-- directory even if no backend serves it
		if #self:mountpoints(path) > 0 then
			local cleaned = clean(path)

			return { name = cleaned:match("[^/]+$") or "/",
			    dir = true, size = 0 }
		end
		return nil, res
	end
	return res
end

-- the union: every backend at this prefix in mount order, then the mount
-- points below it. first to claim a name wins, matching plan 9.
function NS:readdir(path)
	local group, rest = self:lookup(path)
	local out, seen = {}, {}
	local any = false
	local lasterr = dev.Enonexist

	for _, m in ipairs(group or {}) do
		local ok, ents = pcall(function()
			local h = dev.walkpath(m.B, m.B.attach(), rest)
			local e = m.B.readdir(h)

			m.B.clunk(h)
			return e
		end)

		if ok then
			any = true
			for _, e in ipairs(ents) do
				if not seen[e.name] then
					seen[e.name] = true
					out[#out + 1] = e
				end
			end
		else
			lasterr = ents
		end
	end

	-- a path with mounts below it IS a directory, even with nothing
	-- serving it: /mnt exists because /mnt/host does
	for _, e in ipairs(self:mountpoints(path)) do
		if not seen[e.name] then
			seen[e.name] = true
			out[#out + 1] = e
			any = true
		end
	end

	if not any then
		return nil, group and lasterr or rest
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

-- convenience: whole-file read and write, which is most of what a shell
-- and its utilities actually do.
function NS:readfile(path)
	local f, err = self:open(path, "r")

	if not f then
		return nil, err
	end
	local parts = {}

	while true do
		local chunk, rerr = f:read(4096)

		if not chunk then
			f:close()
			return nil, rerr
		end
		if chunk == "" then
			break
		end
		parts[#parts + 1] = chunk
	end
	f:close()
	return table.concat(parts)
end

function NS:writefile(path, data)
	local f, err = self:create(path, "w")

	if not f then
		return nil, err
	end
	local n, werr = f:write(data)

	f:close()
	if not n then
		return nil, werr
	end
	return n
end

-- ---- inheritance: a namespace is a capability, not a global ----
--
-- backends are tables of closures, so a namespace cannot be sent through
-- a port as-is. what travels is a DESCRIPTION -- for each mount, which
-- kind of backend and what it needs to be rebuilt -- which is precisely
-- what plan 9 sends too: not the Chan, but the channel to the server.
-- a local backend is the degenerate case where "the channel" is a
-- constructor argument.
--
-- register a kind before restoring one; the registry is per-proc, which
-- is itself the point. a proc that was never told how to build a "9p"
-- backend cannot be handed one.

M.kinds = {}

function M.register(kind, build)
	M.kinds[kind] = build
end

function NS:describe()
	local out = {}

	for _, m in ipairs(self.mounts) do
		if m.kind then
			-- list order IS union order, and restore replays it,
			-- so "after" reproduces the same sequence
			out[#out + 1] = {
				prefix = m.prefix, kind = m.kind, args = m.args,
			}
		end
		-- a mount with no kind is simply not inheritable, which is
		-- honest: we have no way to rebuild it elsewhere.
	end
	return out
end

function M.restore(desc)
	local ns = M.new()

	for _, d in ipairs(desc or {}) do
		local build = M.kinds[d.kind]

		if not build then
			return nil, "unknown backend kind: " .. tostring(d.kind)
		end
		local ok, B = pcall(build, d.args)

		if not ok then
			return nil, "cannot rebuild " .. d.kind .. ": " ..
			    tostring(B)
		end
		local mok, merr = ns:mount(d.prefix, B, d.kind, d.args, "after")

		if not mok then
			return nil, merr
		end
	end
	return ns
end

-- the two kinds that exist today. a 9p kind, built over a port right,
-- is what makes `mount /host` work and is the reason describe() carries
-- args at all.
M.register("espfs", function(args)
	return require("espfs").new((args and args.root) or "/")
end)

M.register("procfs", function()
	return require("procfs").new()
end)

M.register("mem", function(args)
	-- the tree is plain data, so it genuinely does survive the trip
	return dev.mem((args and args.tree) or {})
end)

return M
