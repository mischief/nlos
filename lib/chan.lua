-- chan: the result of evaluating a name. this is plan 9's Chan, and the
-- name is deliberate rather than decorative.
--
-- a Chan is (backend, handle, NAME). the first two are what lib/dev.lua
-- needs to do anything at all. the third is Rob Pike's, from
-- /sys/doc/lexnames.ms -- "Lexical File Names in Plan 9, or Getting
-- Dot-Dot Right" -- where every Channel carries its absolute rooted
-- path, its Cname, so that ".." can be evaluated lexically and so that
-- an ambiguous mount point can be resolved by asking which name was
-- actually used to arrive here.
--
-- ---- why we carry the name before we need it ----
--
-- we get the lexical property more cheaply than plan 9 does, and it is
-- worth being exact about why rather than feeling clever. ns.lua folds
-- ".." out of a path before any backend sees it, and then evaluates
-- forward from the root every single time. the paper names that
-- implementation, calls it "obvious (and correct)", and rejects it as
-- "expensive and unappealing".
--
-- it was cheap here while every backend was local. through a mount it
-- is a round trip per operation, which is measurable and measured.
-- the fix is to RETAIN Chans and evaluate relative to one -- and the
-- moment we do, ".." stops being free, because a retained Chan can sit
-- at a mount point and "the parent" is then ambiguous exactly as the
-- paper describes. the Cname is what resolves it.
--
-- so the name is here from the start. it costs a string per Chan now
-- and makes that step an addition rather than a rewrite.
--
-- ---- the position is ours, not plan 9's ----
--
-- a 9P fid has no position, and lib/dev.lua takes explicit offsets for
-- that reason. a position is a convenience, so it lives here once
-- rather than in every backend differently. that is also why read() and
-- write() below are the only methods that touch pos: stat, readdir and
-- walk are position-free, like their 9P messages.

local dev = require("dev")

local M = {}

local Chan = {}

Chan.__index = Chan

-- <close> is our cclose: the handle is released on the way out of scope
-- whether by return or by an error unwinding through it. plan 9 needs
-- explicit waserror/nexterror frames for this; lua 5.4 does not.
Chan.__close = function(c)
	c:close()
end

-- new(B, path, h) -> Chan. `path` is the Cname: the rooted, cleaned
-- name the caller used to get here, not anything the backend reported.
-- a backend has no idea what it was mounted as and must never be asked.
function M.new(B, path, h)
	return setmetatable({ B = B, h = h, path = path, pos = 0 }, Chan)
end

-- borrowed(B, path, h) -> a Chan someone else owns.
--
-- close() is a no-op on it. that is not laziness: ns.lua caches one
-- Chan per mount to walk from, and dev.mem and espfs both return the
-- SAME handle table from open() on a directory, so a caller closing
-- what it opened would otherwise clunk the namespace's own root.
function M.borrowed(B, path, h)
	local c = M.new(B, path, h)

	c.borrow = true
	return c
end

function M.is(x)
	return getmetatable(x) == Chan
end

-- ---- walking, where the name is maintained ----

-- walk(names) -> a new Chan, deeper by those elements.
--
-- the Cname is extended LEXICALLY -- appended, never asked of the
-- backend -- which is the whole mechanism the paper describes. a
-- backend knows where a file is, not what it is called from here, and
-- those differ the moment anything is mounted.
--
-- names must already be clean: ns.lua folds "." and ".." out before a
-- path ever reaches a backend, so neither appears here.
function Chan:walk(names)
	if #names == 0 then
		return self
	end

	local h = dev.walkpath(self.B, self.h, table.concat(names, "/"))
	local base = self.path == "/" and "" or self.path

	return M.new(self.B, base .. "/" .. table.concat(names, "/"), h)
end

-- ---- the dev interface, at a position ----

function Chan:read(n)
	local ok, res = pcall(self.B.read, self.h, self.pos, n or 4096)

	if not ok then
		return nil, res
	end
	self.pos = self.pos + #res
	return res
end

function Chan:write(data)
	local ok, res = pcall(self.B.write, self.h, self.pos, data)

	if not ok then
		return nil, res
	end
	self.pos = self.pos + res
	return res
end

function Chan:seek(whence, off)
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

function Chan:stat()
	local ok, res = pcall(self.B.stat, self.h)

	if not ok then
		return nil, res
	end
	return res
end

function Chan:readdir()
	local ok, res = pcall(self.B.readdir, self.h)

	if not ok then
		return nil, res
	end
	return res
end

-- idempotent, because __close runs even on a path that already closed
-- explicitly. a borrowed Chan never releases anything.
function Chan:close()
	if self.h and not self.borrow then
		pcall(self.B.clunk, self.h)
	end
	self.h = nil
end

return M
