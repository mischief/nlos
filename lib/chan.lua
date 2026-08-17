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
local thread = require("los.thread")

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

-- n is a byte count, not a format: a chan is the layer below io, and
-- "a" or "l" belong to nsio's File. Saying so here keeps a format from
-- reaching a backend, where it surfaces as arithmetic on a string.
function Chan:read(n)
	n = n or 4096
	if type(n) ~= "number" then
		return nil, ("read: count must be a number, not %s (%s)")
		    :format(type(n), tostring(n))
	end
	n = math.tointeger(n) or math.floor(n)

	local ok, res = pcall(self.B.read, self.h, self.pos, n)

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


-- ---- reading a file with several requests in flight ----
--
-- Chan:read is one round trip, and the caller waits out every one of
-- them in turn. That is the right shape for a small file and the wrong
-- one for a large one over anything with latency: the transport can
-- hold a window of requests (los.platform.p9's slots, and lib/srv.lua's
-- worker pool behind them), and a single reader leaves all of it idle.
--
-- readparallel issues `window` reads at once, each in its own thread,
-- and hands the blocks back IN ORDER. The threads exist for the
-- duration of one group and retire with it -- there is no pool to own,
-- and a caller that stops iterating early leaves nothing running.
--
-- One fid, not one per thread. A 9P fid has no position and every Tread
-- carries its own offset, so concurrent reads on one open file are
-- ordinary -- which is why this takes no extra opens and clunks
-- nothing. self.pos is advanced as blocks are yielded, so an
-- interrupted iteration leaves the Chan where the caller stopped
-- reading rather than where the reads got to.
--
-- Groups rather than a sliding window: the group's threads all finish
-- before the next group starts, so the window drains and refills
-- instead of staying full. That costs a bubble every `window` blocks
-- and buys working in both contexts -- see runjoin -- and a shape where
-- "the coroutines retire at the end of the call" is literally true.
--
-- A short read is NOT eof and is retried for the remainder; only a
-- zero-length reply ends the file. This matters far more here than it
-- does serially: once replies can land out of order, "the last block
-- was short" says nothing about where the file ends.

local function readfull(B, h, off, n)
	local parts, got = {}, 0

	while got < n do
		local d = B.read(h, off + got, n - got)

		if d == nil or d == "" then
			break
		end
		parts[#parts + 1] = d
		got = got + #d
	end
	return table.concat(parts)
end

-- run `n` worker threads to completion, whichever side of the scheduler
-- we are on. Inside a thread we must park -- thread.run() is already
-- running above us and starting a second one would drive the same run
-- queue from two places. Outside one, nobody is driving it at all and
-- thread.run() is exactly what is needed.
local function runjoin(spawn, n)
	if not thread.inthread() then
		for i = 1, n do
			spawn(i, nil)
		end
		thread.run()
		return
	end

	local done = thread.chancreate(n)

	for i = 1, n do
		spawn(i, done)
	end
	for _ = 1, n do
		done:recv()
	end
end

-- for block, err in f:readparallel(32) do ... end
--
-- yields successive blocks of the file from the current position. Ends
-- at eof; on failure yields nil plus the error, which stops a `for ... in`
-- loop on the first value and leaves the message for the caller to
-- inspect.
function Chan:readparallel(window, blocksize)
	window = window or 16
	blocksize = blocksize or 4096

	local B, h = self.B, self.h
	local off = self.pos
	local buf, n, i = {}, 0, 0
	local eof, failed = false, nil

	return function()
		if failed then
			return nil
		end
		if i < n then
			i = i + 1
			off = off + #buf[i]
			self.pos = off
			return buf[i]
		end
		if eof then
			return nil
		end

		local res, errs = {}, {}
		local base = off

		runjoin(function(k, done)
			thread.spawn(function()
				local ok, d = pcall(readfull, B, h,
				    base + (k - 1) * blocksize, blocksize)

				if ok then
					res[k] = d
				else
					errs[k] = d
				end
				if done then
					done:send(true)
				end
			end)
		end, window)

		-- in order, and stop at the first hole: a short block is the
		-- end of the file, so whatever later threads read past it is
		-- not ours to hand back
		buf, n, i = {}, 0, 0
		for k = 1, window do
			if errs[k] then
				failed = errs[k]
				break
			end

			local d = res[k]

			if d == nil or d == "" then
				eof = true
				break
			end
			buf[#buf + 1] = d
			if #d < blocksize then
				eof = true
				break
			end
		end
		n = #buf

		if n == 0 then
			if failed then
				return nil, failed
			end
			return nil
		end
		i = 1
		off = off + #buf[1]
		self.pos = off
		return buf[1]
	end
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
