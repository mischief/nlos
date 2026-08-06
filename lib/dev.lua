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
-- open() and create() must return a handle that OWNS ITS OWN LIFETIME:
-- never the handle passed in, and never one sharing mutable state with
-- it. clunking the result must not disturb anything the caller still
-- holds.
--
-- this is not style. lib/srv.lua gives the returned handle a second fid,
-- so a backend that mutates and returns its argument leaves two fids
-- aliasing one object, and clunking either guts the other -- which
-- espfs did, and which surfaced as Ebadusefd on a good read at whatever
-- moment the collector happened to clunk the walked handle. a local
-- caller can get away with it; a mounted one cannot.
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

local sys = require("los.sys")

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
	local names = M.elements(root or "/")

	if #names == 0 then
		return backend
	end

	local sub = {}

	for k, v in pairs(backend) do
		sub[k] = v
	end
	function sub.attach()
		return M.walknames(backend, backend.attach(), names)
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
-- walk an already-split path. split once and call this when the caller
-- has the elements in hand -- ns.lua does, and computing them twice
-- showed up as a measurable regression on local backends, where there
-- is no round trip to hide an allocation behind.
function M.walknames(backend, h, names)
	if #names == 0 then
		return h
	end
	if backend.walkmany then
		return backend.walkmany(h, names)
	end
	return M.walkall(backend, h, names)
end

function M.walkpath(backend, h, path)
	return M.walknames(backend, h, M.elements(path))
end

-- the most data one request or reply may carry across a port, and the
-- boundary the loops above align to.
--
-- One block. Everything under a mount is block-shaped -- gefs's is
-- 16384, a disk sector is 512 -- and a request that is exactly one
-- block, on a block boundary, is the one that costs the backend
-- nothing extra: gefs re-packs and re-writes the block a write lands
-- in, and reads the old one first if the write does not cover it
-- whole. Chunks that straddle turn one block-write into a
-- read-modify-write, and a block touched by three chunks is packed and
-- hashed three times.
--
-- It used to be sys.MAXMSG - 4096 = 61440, reasoning only about what
-- fits in one message. That is 94% of a port's whole queue
-- (sys.MAXQUEUE), so a second concurrent writer did not fit, the
-- kernel refused the send, and lib/mnt.lua reported the refusal as
-- dev.Eio -- a write that never happened, on a file left with length
-- 0. Three of these fit in a queue instead.
--
-- 9P says this per fid, in Ropen's iounit, which is the right shape
-- and what a backend advertising its own block size would grow into.
-- Until then one number, because both halves of the transport need the
-- same one: srv.lua clamps incoming requests to it precisely so that a
-- client which ignores it cannot make a server build a reply it can
-- never deliver.
M.IOUNIT = 16384

-- a message too big to send at all is the worse failure, so the message
-- bound stays as a ceiling over the block-shaped number above.
if M.IOUNIT > sys.MAXMSG - 4096 then
	M.IOUNIT = sys.MAXMSG - 4096
end

-- ---- transfers larger than one message ----
--
-- this is plan 9's mntrdwr (/sys/src/9/port/devmnt.c), and it belongs in
-- exactly the place plan 9 puts it: the MOUNT DRIVER, not the caller and
-- not the backend.
--
-- the rule that makes the whole stack work is that a transport's message
-- limit is the transport's business. a read syscall for a megabyte
-- succeeds on plan 9 even though msize is 8K, because devmnt quietly
-- issues however many Treads it takes. Nothing above it knows the number,
-- and no filesystem below it is written twice, once for small reads and
-- once for large.
--
-- we had it the other way round for a while and it cost us: every
-- backend grew its own ceiling, callers were expected to loop, and a
-- transfer that outgrew a port message did not fail -- lib/srv.lua could
-- not send the reply, so the client waited for an answer that was never
-- coming. A limit enforced by hanging is the worst kind. Now the mount
-- drivers (lib/mnt.lua, lib/p9fs.lua) each pass their own iounit here,
-- and a backend simply answers what it was asked.
--
-- `one` is a single round trip: one(off, n) -> data for reads,
-- one(off, chunk) -> count for writes. Raising propagates, as everywhere
-- else in this interface.

-- a short read ends the transfer, exactly as it does in mntrdwr. that is
-- the contract a backend is held to: return the full count unless there
-- is no more file, so "fewer bytes than I asked for" can mean end of
-- file and nothing else. A backend that returned short for its own
-- convenience would truncate every large read through a mount.
function M.readloop(iounit, one, off, n)
	local parts, got = {}, 0

	while got < n do
		local want = n - got
		-- aligned, for the reason writeloop gives
		local room = iounit - (off + got) % iounit

		if want > room then
			want = room
		end

		local d = one(off + got, want)

		if not d or d == "" then
			break			-- end of file
		end
		parts[#parts + 1] = d
		got = got + #d
		if #d < want then
			break
		end
	end

	return table.concat(parts)
end

-- writes stop short too, and for the same reason: a server that accepted
-- fewer bytes than offered has told us it will not take the rest now,
-- and the count we return is what the caller must believe.
function M.writeloop(iounit, one, off, data)
	local n, done = #data, 0

	while done < n do
		local want = n - done
		-- to the next multiple of iounit, not a flat iounit from
		-- wherever this started. Everything under a mount is
		-- block-shaped, and a chunk that straddles a block boundary
		-- makes the backend read the old block before writing it --
		-- gefs does exactly that (fsops.lua's `fo ~= 0 or n ~= blksz`).
		-- Only the first chunk is ever short; every one after it
		-- starts on a boundary.
		local room = iounit - (off + done) % iounit

		if want > room then
			want = room
		end

		local w = one(off + done, data:sub(done + 1, done + want))

		if not w or w <= 0 then
			break
		end
		done = done + w
		if w < want then
			break
		end
	end

	return done
end

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
		M.error(M.Eperm)
	end

	for k, v in pairs(B) do
		RO[k] = v
	end

	RO.write = refuse
	RO.create = refuse
	RO.remove = nil		-- absent, not a stub: see the note above

	function RO.open(h, mode)
		if mode ~= "r" then
			M.error(M.Eperm)
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

	function B.create(h, name, mode, dir)
		if type(h.node) ~= "table" then
			M.error(M.Enotdir)
		end
		if h.node[name] ~= nil then
			M.error(M.Eexist)
		end
		h.node[name] = dir and {} or ""
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
