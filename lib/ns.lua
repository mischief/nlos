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
local chan = require("chan")

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

-- the open file used to be a local File type here. it is lib/chan.lua
-- now, under the name plan 9 gives it, and it carries the name it was
-- opened by -- see that file for why the name earns its keep.

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
			-- the cached root is the namespace's own, so the
			-- namespace is what releases it. borrowed Chans do not
			-- close themselves, which is the point of the flag.
			if m.root then
				pcall(m.B.clunk, m.root.h)
				m.root = nil
			end
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

	-- the cleaned path comes back too: every caller wants it as the
	-- Chan's name, and cleaning it a second time is pure waste on a
	-- path that is already resolved.
	return group, rest, path
end

-- the mount's root, attached once and kept.
--
-- every lookup used to call attach(), which is free for a local backend
-- and a whole round trip through a mounted server -- on every single
-- operation. lexnames.ms is about the cost of re-evaluating from the
-- root; this is the cheapest end of that.
--
-- it is a BORROWED Chan and is only ever used as a walk origin.
-- dev.walkpath neither clunks nor mutates what it starts from, so
-- sharing it is safe. handing it to open() would not be: dev.mem and
-- espfs both return the SAME handle table from open() on a directory,
-- so a caller closing what it opened would clunk the namespace's root
-- out from under every later lookup. hence walkfrom() below attaches
-- fresh when there is nothing left to walk.
local function rootof(m)
	if not m.root then
		m.root = chan.borrowed(m.B, m.prefix, m.B.attach())
	end
	return m.root
end

-- resolve to a Chan, trying each union member in order and taking the
-- first that resolves -- plan 9's semantics. raises, because it is
-- called from inside the other methods; the public wrappers pcall.
--
-- the Chan's name is the cleaned path the CALLER asked for, not
-- anything the backend knows. a backend has no idea what prefix it was
-- mounted at, and must not be asked.
function NS:walk(path)
	local group, rest, cleaned = self:lookup(path)

	if not group then
		dev.error(rest)
	end

	local names = dev.elements(rest)
	local lasterr = dev.Enonexist

	for _, m in ipairs(group) do
		local ok, res = pcall(function()
			if #names == 0 then
				-- the mount point itself. fresh, because the
				-- caller owns whatever it gets back and may
				-- open or close it.
				return m.B.attach()
			end
			return dev.walknames(m.B, rootof(m).h, names)
		end)

		if ok then
			return chan.new(m.B, cleaned, res)
		end
		lasterr = res
	end
	dev.error(tostring(lasterr))
end

-- ---- public API: each of these pcalls exactly once ----

function NS:open(path, mode)
	mode = mode or "r"

	local ok, res = pcall(function()
		local c = self:walk(path)

		return chan.new(c.B, c.path, c.B.open(c.h, mode))
	end)

	if not ok then
		return nil, res
	end
	return res
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

	local ok, res = pcall(function()
		local d = self:walk(dir)

		return chan.new(d.B, cleaned, d.B.create(d.h, name, mode or "rw"))
	end)

	if not ok then
		return nil, res
	end
	return res
end

function NS:stat(path)
	local ok, res = pcall(function()
		local c <close> = self:walk(path)
		-- Chan methods return nil+err, so the raise has to be put
		-- back here: this is an entry point and the fallback below
		-- depends on knowing it failed.
		local st, serr = c:stat()

		if not st then
			dev.error(tostring(serr))
		end
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

	local names = dev.elements(rest)

	for _, m in ipairs(group or {}) do
		local ok, ents = pcall(function()
			-- reading the mount point itself needs no walk at all,
			-- and the cached root is exactly the right handle for
			-- it -- readdir does not consume what it reads, so
			-- unlike open() this one may borrow.
			if #names == 0 then
				return m.B.readdir(rootof(m).h)
			end

			local h = dev.walknames(m.B, rootof(m).h, names)
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

-- ---- the proc's own namespace, and require() through it ----
--
-- plan 9 calls this the Pgrp: one namespace per proc, which library code
-- consults rather than being handed. that is not ambient authority
-- creeping back -- a proc gets here only because something granted it a
-- description, and procs are isolated lua states, so "global" means
-- "this proc". it has to be reachable this way because io.open and
-- require() have nowhere to take a namespace argument.

local current = nil

function M.current()
	return current
end

-- the search path, mirroring LUA_PATH_DEFAULT ("/?.lua;/lib/?.lua" --
-- see meson.build). one list, so the two cannot drift.
M.searchpath = { "/?.lua", "/lib/?.lua" }

local installed = false

-- install a package.searchers entry that finds modules in whatever
-- namespace this proc currently has.
--
-- it goes at position 2: preload stays first, because los.sys and the
-- other C openers are not files and must always win. the stock LUA_PATH
-- searcher stays behind us as the fallback, which is what keeps
-- bootstrap working -- this module itself was found by it.
--
-- the point is that a program's CODE now comes from its own namespace.
-- mount a different /lib and require follows; mount one served by an srv
-- proc over a port and require follows there too. before this, a proc
-- could be handed any namespace you liked and require ignored it.
function M.searcher()
	if installed then
		return
	end
	installed = true
	table.insert(package.searchers, 2, function(name)
		if not current then
			return nil
		end

		local fname = name:gsub("%.", "/")
		local tried = {}

		for _, pat in ipairs(M.searchpath) do
			local path = pat:gsub("%?", fname)
			local src = current:readfile(path)

			if src then
				local chunk, err = load(src, "@" .. path)

				if not chunk then
					error("error loading module '" .. name ..
					    "' from " .. path .. ":\n\t" ..
					    tostring(err), 0)
				end
				return chunk, path
			end
			tried[#tried + 1] = "\n\tno file '" .. path ..
			    "' in namespace"
		end
		return table.concat(tried)
	end)
end

-- adopt(desc): rebuild a namespace description, make it this proc's, and
-- route require() through it. one line at the top of a spawned chunk:
--
--	local N = assert(require("ns").adopt(...))
--
-- `...` being sys.spawn's arg, which arrives BEFORE the chunk runs --
-- the whole reason that primitive exists. this cannot be a message,
-- because require() happens first.
function M.adopt(desc)
	local n, err = M.restore(desc)

	if not n then
		return nil, err
	end
	current = n
	M.searcher()
	return n
end

-- for a proc that built its namespace itself rather than inheriting one
-- (proc 0, and anything holding the raw ESP).
function M.setcurrent(n)
	current = n
	M.searcher()
	return n
end

-- "mnt" is the kind that makes the paragraph above true rather than
-- aspirational. every other kind here is rebuilt from a recipe, which
-- works only because each derives from something ambient -- espfs from
-- the ESP, procfs from sys.procs, mem from plain data. a backend whose
-- state lives in another proc has no recipe; what travels is a right to
-- that proc, and rights are copied on transfer, so a namespace holding
-- one can be described any number of times.
M.register("mnt", function(args)
	if type(args) ~= "table" or type(args.port) ~= "table" or
	    not args.port.__right then
		dev.error("mnt: no port right in args")
	end
	return require("mnt").new(args.port.__right)
end)

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
