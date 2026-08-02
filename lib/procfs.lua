-- procfs: the process table as a filesystem.
--
--   /proc/4/status    name, state, scheduling
--   /proc/4/stack     a live cross-proc traceback
--   /proc/4/mem       lua heap used/peak/limit
--   /proc/self/...    whoever is reading
--
-- this is plan 9's devproc, and the reason to build it is the reason
-- plan 9 built it: a debugger stops being a program and becomes
-- `cat /proc/4/stack`. it is also the first service here that could have
-- been a port protocol and is a dev backend instead, and that is the
-- right call for the reason lib/srv.lua sets out: everything procfs
-- reports is ambient kernel state, readable from any proc, so serving it
-- over a port would buy nothing and cost a round trip per read.
--
-- READ-ONLY, and that is a decision rather than an omission. everything
-- here is structure: what the machine is doing, not what any proc's data
-- is. that is why it needs no capability, exactly as sys.procs, sys.name
-- and sys.wchan need none. locals would be values rather than structure,
-- and a /proc/n/ctl that could stop or kill a proc would be authority --
-- both want a capability, and neither is here.
--
-- content is generated per open() and cached in the handle, so a read
-- sees one consistent snapshot rather than a file that changes shape
-- underneath a partial read. a proc that exits between walk and read
-- raises Enonexist, like any other vanished file.

local sys = require("los.sys")
local dev = require("dev")

local M = {}

-- ---- content generators ----

local function fmt_status(pid)
	local wt, pri, cpu = sys.priority(pid)

	return table.concat({
		"name    " .. sys.name(pid),
		"pid     " .. pid,
		"wchan   " .. sys.wchan(pid),
		"weight  " .. wt,
		"pri     " .. pri,
		"cpu     " .. cpu,
	}, "\n") .. "\n"
end

-- sys.stack returns one entry per COROUTINE, not a flat frame list: a
-- proc built on lib/thread keeps its threads inside its own state, and
-- reporting only the main one showed the scheduler whether the proc was
-- idle or wedged. See src/debug.c.
local function fmt_stack(pid)
	local coros = sys.stack(pid)
	local out = {}

	for _, co in ipairs(coros) do
		out[#out + 1] = string.format("[%s] %s", co.label, co.status)
		for i, f in ipairs(co.frames) do
			out[#out + 1] = string.format("  %2d %s:%d in %s (%s)",
			    i, f.source, f.line, f.name, f.what)
		end
		if #co.frames == 0 then
			out[#out + 1] = "  (no frames)"
		end
	end
	if #out == 0 then
		out[1] = "(no coroutines)"
	end
	return table.concat(out, "\n") .. "\n"
end

local function fmt_mem(pid)
	local used, peak, limit = sys.meminfo(pid)

	return table.concat({
		"used    " .. used,
		"peak    " .. peak,
		"limit   " .. limit,
	}, "\n") .. "\n"
end

local FILES = {
	status = fmt_status,
	stack = fmt_stack,
	mem = fmt_mem,
}

local FILENAMES = { "mem", "stack", "status" }	-- sorted

-- ---- the backend ----

local function live(pid)
	for _, p in ipairs(sys.procs()) do
		if p == pid then
			return true
		end
	end
	return false
end

function M.new()
	local B = {}

	-- a handle is { kind = "root"|"proc"|"file", pid =, file =, data = }
	local function h_of(kind, pid, file)
		return { kind = kind, pid = pid, file = file }
	end

	function B.attach()
		return h_of("root")
	end

	function B.walk(h, name)
		if h.kind == "root" then
			-- "self" is resolved by whoever is READING, which is
			-- the point: the backend runs in the reader's proc.
			local pid = (name == "self") and sys.self()
			    or tonumber(name)

			if not pid or not live(pid) then
				dev.error(dev.Enonexist)
			end
			return h_of("proc", pid)
		end
		if h.kind == "proc" then
			if not FILES[name] then
				dev.error(dev.Enonexist)
			end
			return h_of("file", h.pid, name)
		end
		dev.error(dev.Enotdir)
	end

	function B.stat(h)
		if h.kind == "root" then
			return { name = "proc", dir = true, size = 0 }
		end
		if h.kind == "proc" then
			return { name = tostring(h.pid), dir = true, size = 0 }
		end
		-- generating to measure is fine at these sizes, and is what
		-- keeps size honest rather than a lie like 0
		local ok, data = pcall(FILES[h.file], h.pid)

		return { name = h.file, dir = false,
		    size = ok and #data or 0 }
	end

	function B.open(h, mode)
		if mode ~= "r" then
			dev.error(dev.Eperm)		-- read-only, on purpose
		end
		if h.kind == "file" then
			if not live(h.pid) then
				dev.error(dev.Enonexist)
			end
			-- snapshot now: a read served in pieces must not see
			-- the file change shape between them
			local ok, data = pcall(FILES[h.file], h.pid)

			if not ok then
				dev.error(dev.Enonexist)
			end
			h.data = data
		end
		return dev.closable(B, h)
	end

	function B.create(_, _, _)
		dev.error(dev.Eperm)
	end

	function B.read(h, off, n)
		if h.kind ~= "file" then
			dev.error(dev.Eisdir)
		end
		if not h.data then
			dev.error(dev.Ebadusefd)
		end
		return h.data:sub(off + 1, off + n)
	end

	function B.write(_, _, _)
		dev.error(dev.Eperm)
	end

	function B.readdir(h)
		local out = {}

		if h.kind == "root" then
			local pids = sys.procs()

			table.sort(pids)
			for _, pid in ipairs(pids) do
				out[#out + 1] = { name = tostring(pid),
				    dir = true, size = 0 }
			end
			out[#out + 1] = { name = "self", dir = true, size = 0 }
			return out
		end
		if h.kind == "proc" then
			for _, name in ipairs(FILENAMES) do
				local ok, data = pcall(FILES[name], h.pid)

				out[#out + 1] = { name = name, dir = false,
				    size = ok and #data or 0 }
			end
			return out
		end
		dev.error(dev.Enotdir)
	end

	function B.clunk(h)
		h.data = nil
	end

	return B
end

return M
