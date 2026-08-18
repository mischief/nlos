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
--   stat(h)               -> st, err       {name=, size=, dir=, mtime=}
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
-- OPTIONAL: hangup(), called by srv once no client can send again. A
-- backend whose read parks needs it -- what it waits for comes from the
-- client that has gone, so the reader would park forever.
--
-- OPTIONAL: remove(h) and wstat(h, st). wstat changes a file's name
-- within its own directory, which is all 9P's Twstat can carry.

-- OPTIONAL: rename(dsrc, name, ddst, newname), moving an entry between
-- two directories of the SAME backend. 9P has no message for it, so a
-- p9fs mount cannot offer it; srv/mnt carry calls rather than 9P bytes
-- and do.

-- dev.check demands none of the three. check before calling.
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
local buf = require("los.buf")

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
-- not from error.h: unix's EXDEV, which plan 9 has no name for because
-- wstat cannot express the move that fails this way. a rename whose two
-- ends sit on different mounts raises it, and `mv` is what falls back to
-- copying. the guarantee rename makes -- one name or the other, never
-- neither -- is exactly what no two backends can jointly keep.
M.Exdev      = "cross-device link"
-- not from error.h: this is the string plan 9's own 9P servers send for
-- a fid they do not know, and lib/srv.lua raises it for the same reason.
M.Ebadfid    = "unknown fid"
-- what a parked read raises when hangup releases it. The reply goes
-- nowhere: the client it was owed to is why this is being raised.
M.Ehungup    = "hungup"

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
-- `raw` asks for whatever the one round trip produced -- a buffer,
-- where the server had one to give away. Only when a single round trip
-- answered the whole read, since joining two means copying both and a
-- string is what that produces. Callers that want bytes to work on
-- rather than a string to hold ask for it; everything else gets the
-- string it always did.
function M.readloop(iounit, one, off, n, raw)
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

	-- one piece is the answer. Concatenating a single part copies the
	-- whole of it to produce what it already is.
	if #parts == 1 then
		if raw or not buf.is(parts[1]) then
			return parts[1]
		end
		-- a buffer where a string was asked for
		return parts[1]:str()
	end
	for i = 1, #parts do
		if buf.is(parts[i]) then
			parts[i] = parts[i]:str()
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

		local chunk = buf.is(data) and data:view(done + 1, done + want) or
		    data:sub(done + 1, done + want)
		local w = one(off + done, chunk)

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

-- ---- building, mounting and serving a tree ----
--
-- check() at mount time, subtree() for a mount that names a root,
-- readonly() for one backend served at two authority levels, and mem()
-- for a synthetic one. A program that opens a file calls none of them,
-- so they live in lib/devtree.lua and load on first call.
--
-- Forwarded by hand rather than through lib/lazy.lua: requiring a module
-- to defer four names costs every client the module.
local function fwd(name)
	return function(...)
		return require("devtree")[name](...)
	end
end

M.subtree = fwd("subtree")
M.readonly = fwd("readonly")
M.mem = fwd("mem")

return M
