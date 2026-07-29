-- stdout: print and io.write, over a port.
--
-- a proc's output is a capability. redirecting it means granting a
-- different right -- which is what a browser terminal serving lua-os
-- over http needs, and what is impossible while print is a C call to
-- console_write.
--
-- ---- no fallback ----
--
-- a proc with no stdout port writes nowhere. it does NOT quietly reach
-- the console: a fallback is indistinguishable from a grant right up
-- until you are debugging why output went to the wrong place.
--
-- kernel-spawned tasks are exempt by construction rather than by
-- fallback -- they keep the raw C path because a driver that cannot
-- report its own failure is worse than an ambient write, and
-- platform_abort keeps it because you cannot message your way out of a
-- panic.
--
-- ---- the protocol ----
--
-- {op="write", data=s}, fire and forget -- the same thing cons.lua,
-- wire.lua, prog.lua and dos.lua speak. no reply, so a print costs one
-- send and never a round trip.
--
-- lib/prog.lua does this for programs against its ABI streams, so that
-- a program in a pipeline does not bypass the pipe. it predates this and
-- should be folded into it.

local sys = require("los.sys")

local M = {}

-- write to a port, or discard if there is none. a dead port drops the
-- message (sys.send returns false); output is not worth raising over,
-- and the caller almost never checks a print.
local function emit(h, s)
	if h then
		pcall(sys.send, h, { op = "write", data = s })
	end
end

local function stream(get)
	return {
		write = function(self, ...)
			for _, v in ipairs({ ... }) do
				emit(get(), tostring(v))
			end
			return self
		end,
		-- there is nothing to flush: a send is already delivered to
		-- the port. present so `io.stdout:flush()` is not an error.
		flush = function(self)
			return self
		end,
		close = function()
			return true
		end,
	}
end

-- set(out [, err]) -> install print/io.write over these ports.
--
-- err defaults to out, matching every shell: diagnostics follow output
-- unless someone deliberately splits them.
--
-- the ports are read through a closure rather than captured, so calling
-- set() again redirects a proc that is already running -- which is what
-- makes this usable from a repl.
function M.set(out, err)
	M.out = out
	M.err = err or out

	if M.installed then
		return
	end
	M.installed = true

	local function getout()
		return M.out
	end
	local function geterr()
		return M.err
	end

	io.write = function(...)
		for _, v in ipairs({ ... }) do
			emit(M.out, tostring(v))
		end
		return io.stdout
	end
	io.stdout = stream(getout)
	io.stderr = stream(geterr)

	-- tab-separated, newline-terminated: lua's own print, minus the
	-- destination.
	_G.print = function(...)
		local n = select("#", ...)
		local parts = {}

		for i = 1, n do
			parts[i] = tostring((select(i, ...)))
		end
		emit(M.out, table.concat(parts, "\t") .. "\n")
	end
end

return M
