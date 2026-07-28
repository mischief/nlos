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
-- ---- what is not here yet ----
--
-- union mounts (plan 9 allows several servers at one prefix; here a
-- second mount at the same prefix replaces the first), and remove(),
-- which needs both a backend method and EFI_FILE_PROTOCOL->Delete
-- wrapped in src/fs.c. both are named in docs/shell-namespace-draft.md.

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

-- mount(prefix, backend, kind, args)
--
-- kind/args are optional and only used by describe(): they record how to
-- rebuild this backend in another proc. a mount without them still
-- works, it just cannot be inherited.
function NS:mount(prefix, backend, kind, args)
	local ok, err = pcall(dev.check, backend, kind or "backend")

	if not ok then
		return nil, err
	end
	prefix = clean(prefix)

	-- a second mount at the same prefix replaces the first. plan 9
	-- would union them; that is a real feature and a real complication,
	-- and nothing here needs it yet.
	for i, m in ipairs(self.mounts) do
		if m.prefix == prefix then
			table.remove(self.mounts, i)
			break
		end
	end
	self.mounts[#self.mounts + 1] = {
		prefix = prefix, B = backend, kind = kind, args = args,
	}
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

-- longest matching prefix wins, so /mnt/host beats / for /mnt/host/x.
-- returns the mount and the path relative to it.
function NS:lookup(path)
	path = clean(path)

	local best, bestlen

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
			best, bestlen = m, #p
		end
	end
	if not best then
		return nil, "no mount for " .. path
	end
	local rest = best.prefix == "/" and path or path:sub(#best.prefix + 1)

	return best, rest
end

-- resolve to (backend, handle). raises, because it is called from the
-- inside of the other methods; the public wrappers are what pcall.
function NS:walk(path)
	local m, rest = self:lookup(path)

	if not m then
		dev.error(rest)
	end
	return m.B, dev.walkpath(m.B, m.B.attach(), rest)
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
		return nil, res
	end
	return res
end

function NS:readdir(path)
	local ok, res = pcall(function()
		local B, h = self:walk(path)
		local ents = B.readdir(h)

		B.clunk(h)
		return ents
	end)

	if not ok then
		return nil, res
	end
	return res
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
		local mok, merr = ns:mount(d.prefix, B, d.kind, d.args)

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
