-- dev: the backend interface every filesystem here implements.
--
-- this is Plan 9's Dev/devtab, and it is the load-bearing abstraction --
-- NOT 9P. a Chan is (backend, handle); a namespace maps names to Chans;
-- and 9P is one backend that happens to forward over a byte channel,
-- rather than the thing everything else is built on. that ordering is
-- what lets a local filesystem work with no wire protocol involved, and
-- lets a remote one appear later as just another backend.
--
-- the consumers that have to agree on this shape:
--   ns.lua        resolves a path to (backend, handle) and reads/writes
--   srv.lua       serves a backend to other procs, over a port
--   mnt.lua       IS a backend, forwarding to such a server
--   the backends  espfs, procfs, a synthetic tree
--
-- srv/mnt are the reason the interface has to be exactly this and not
-- merely something like it: they marshal these calls one for one, so a
-- method added here is a message added there. note that they carry the
-- calls as tables rather than as 9P bytes -- 9P's framing is for byte
-- streams, and a port is not one. ninep.lua remains the encoding at a
-- real boundary (com2, TCP), where the bytes are unavoidable.
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
-- OPTIONAL, and used when present: walkmany(h, names) -> h, which walks
-- a whole path in one call. see M.walkpath below for why it is optional
-- rather than required.
--
-- NOT required, and deliberately: remove() and wstat(). a shell wants
-- `rm`, so remove() is the next thing this interface should grow -- but
-- espfs cannot implement it yet (EFI_FILE_PROTOCOL has Delete and
-- src/fs.c does not wrap it), and requiring a method no real backend can
-- provide would just mean every backend stubbing it. backends MAY
-- provide either; dev.check does not demand them, so check before
-- calling.
--
-- ---- errors are raised, plan 9 style ----
--
-- backends call dev.error(dev.Enonexist) rather than returning nil plus
-- a message. that is 9front's error() idiom, and it is the same
-- mechanism rather than an analogy: lua_error longjmps to the nearest
-- pcall frame exactly as error() longjmps to the nearest waserror().
--
-- the reason is depth. resolving one path runs ns.resolve -> walkpath ->
-- walk (once per element) -> the backend's own stat, and threading
-- nil+err back through all of it is precisely the noise plan 9 invented
-- error() to delete. it is also easier to get wrong: a caller that
-- forgets to check gets "attempt to index a nil value" several frames
-- from the actual fault, which is how the first version of the dev test
-- failed.
--
-- catch at entry points, one pcall each, mirroring the syscall
-- entrypoint: ns.lua's public calls, a 9P server's per-message dispatch
-- (where the caught string becomes Rerror directly), a shell running a
-- command. INSIDE the stack, nothing checks.
--
-- messages are bare strings with no position prefix -- dev.error passes
-- level 0 -- because an Rerror carrying "espfs.lua:88:" would be
-- nonsense to a 9P client. the constants below are 9front's, from
-- /sys/src/9/port/error.h, so a client sees what it would see from a
-- real plan 9 box.
--
-- cleanup is where we beat the C kernel. plan 9 needs explicit
-- waserror/nexterror frames to close a Chan while unwinding, because C
-- has no destructors. lua 5.4 has to-be-closed variables, so
--
--	local h <close> = ns.open(path)
--
-- clunks on the way out whether the scope ends normally or an error
-- blows through it. backends mark their open handles closable via
-- dev.closable, so this works without any per-backend effort.
--
-- offsets are explicit and handles carry no position, matching 9P. a
-- stream with a position is a convenience ns.lua can layer on top; it is
-- not something backends should each reinvent differently.

local M = {}

-- 9front's error strings (/sys/src/9/port/error.h), the subset a
-- filesystem backend actually raises.
M.Enonexist  = "file does not exist"
M.Eexist     = "file already exists"
M.Enotdir    = "not a directory"
M.Eisdir     = "file is a directory"
M.Eperm      = "permission denied"
M.Ebadarg    = "bad arg in system call"
M.Eio        = "i/o error"
M.Ebadusefd  = "inappropriate use of fd"
M.Enotimpl   = "not implemented"
-- not from error.h: this is the string plan 9's own 9P servers send for
-- a fid they do not know, and lib/srv.lua raises it for the same reason.
M.Ebadfid    = "unknown fid"

-- raise without a position prefix: these cross a protocol boundary, and
-- "espfs.lua:88: file does not exist" is not an Rerror.
function M.error(msg)
	error(msg, 0)
end

-- run fn(...) as an entry point: the one pcall that mirrors plan 9's
-- syscall boundary. returns ok plus either results or the bare message.
function M.protect(fn, ...)
	return pcall(fn, ...)
end

-- mark an open handle to-be-closed, so `local h <close> = ...` clunks it
-- on the way out of scope, including while an error unwinds. this is
-- what plan 9 spells waserror/cclose/nexterror.
--
-- an existing metatable is PRESERVED rather than replaced. a plain
-- setmetatable here would silently delete a backend's own __index,
-- __tostring or __eq -- neither backend has one today, but this is a
-- shared helper every future backend will call, and losing a metatable
-- is the kind of bug that shows up far from its cause.
--
-- the copy means a handle's metatable is its own, so a backend cannot
-- rely on getmetatable(h) == its shared table for identity. no backend
-- does, and per-handle metatables cost one table each, which is what a
-- closable handle costs anyway.
function M.closable(B, h)
	local old = getmetatable(h)
	local mt = { __close = function(x) B.clunk(x) end }

	if old then
		for k, v in pairs(old) do
			if k ~= "__close" then
				mt[k] = v
			end
		end
	end
	return setmetatable(h, mt)
end

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
		M.error(name .. ": not a table")
	end
	for _, m in ipairs(REQUIRED) do
		if type(backend[m]) ~= "function" then
			M.error(name .. ": missing " .. m .. "()")
		end
	end
	return backend
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
function M.walkall(backend, h, names)
	for _, elem in ipairs(names) do
		local ok, res = pcall(backend.walk, h, elem)

		if not ok then
			M.error(tostring(res) .. ": '" .. elem .. "'")
		end
		h = res
	end
	return h
end

-- split a path into the elements a walk actually visits. empty elements
-- and "." are skipped, so "/a//b/./c" walks a, b, c.
function M.elements(path)
	local names = {}

	for elem in tostring(path):gmatch("[^/]+") do
		if elem ~= "." then
			names[#names + 1] = elem
		end
	end
	return names
end

-- walk a whole path, which every consumer needs and none should write
-- twice.
--
-- a backend MAY offer walkmany(h, names) and gets the entire path in one
-- call if it does. that is 9P's Twalk, which carries up to sixteen names
-- for exactly this reason, and it is optional for exactly the reason 9P
-- has both: a local backend gains nothing from batching, since its
-- walkmany could only be this same loop. it is lib/mnt.lua that gains,
-- where each element was otherwise a round trip to another proc.
--
-- the contract is narrower than Twalk's on purpose. 9P answers a partial
-- walk with a short Rwalk and leaves the client to decide; every caller
-- here wants the whole path or an error, so walkmany raises on the first
-- failure and names the element that failed, exactly as the loop does.
-- nothing needs the probing form, and supporting it would put a second
-- shape into every backend that implements this.
--
-- no cap on the name count. 9P's sixteen is an msize concern and a port
-- has no equivalent -- a thousand-element path is one flat array well
-- inside the serializer's own limits, and past those it raises cleanly.
function M.walkpath(backend, h, path)
	local names = M.elements(path)

	if #names == 0 then
		return h
	end
	if backend.walkmany then
		return backend.walkmany(h, names)
	end
	return M.walkall(backend, h, names)
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
			M.error(M.Enotdir)
		end
		if name == ".." then
			-- the mem tree keeps no parent links; ns.lua resolves
			-- ".." before it ever reaches a backend, and a 9P
			-- client walking ".." off the root should stay put.
			return h
		end
		local child = h.node[name]

		if child == nil then
			M.error(M.Enonexist)
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
			M.error(M.Eisdir)
		end
		return M.closable(B, h)
	end

	function B.create(h, name, mode)
		if type(h.node) ~= "table" then
			M.error(M.Enotdir)
		end
		if h.node[name] ~= nil then
			M.error(M.Eexist)
		end
		h.node[name] = ""
		return B.open(B.walk(h, name), mode or "rw")
	end

	function B.read(h, off, n)
		if type(h.node) == "table" then
			M.error(M.Eisdir)
		end
		return h.node:sub(off + 1, off + n)
	end

	function B.write(h, off, data)
		if type(h.node) == "table" then
			M.error(M.Eisdir)
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
			M.error(M.Eio)
		end
		local cur = parent[key]
		local head = cur:sub(1, off) .. string.rep("\0", off - #cur)

		parent[key] = head .. data .. cur:sub(off + #data + 1)
		h.node = parent[key]
		return #data
	end

	function B.readdir(h)
		if type(h.node) ~= "table" then
			M.error(M.Enotdir)
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
