-- Formatting and parsing for the debugger. The kernel half is los.dbg;
-- this is what bin/dbg.lua prints and what it accepts.

local sys = require("los.sys")
local kdbg = require("los.dbg")

local M = {}

-- A described value as text. Scalars are the kernel's copy; anything
-- else is type and address, since rendering means the target's
-- __tostring.
function M.fmtvalue(d)
	if not d then return "?" end
	if d.t == "nil" or d.t == "none" then return "nil" end
	if d.t == "string" then
		local s = ("%q"):format(d.v or "")
		if d.trunc then s = s .. "..." end
		return s
	end
	if d.t == "number" or d.t == "boolean" then
		return tostring(d.v)
	end
	if d.t == "table" then
		return ("table: %s (#%d)"):format(d.addr or "?", d.n or 0)
	end
	return ("%s: %s"):format(d.t, d.addr or "?")
end

-- The keys of a table value, as a hint about where one can walk next.
function M.fmtkeys(d, max)
	if not d or not d.keys or #d.keys == 0 then return nil end

	local out = {}

	for i = 1, math.min(#d.keys, max or 8) do
		out[#out + 1] = M.fmtvalue(d.keys[i])
	end
	if #d.keys > (max or 8) then out[#out + 1] = "..." end
	return table.concat(out, " ")
end

-- Parse `name`, `name.k`, `name[3]`, `name["k"].j` into a root name
-- and literal keys. This is where "no expression evaluation" lives: a
-- grammar with no syntax for a call has no call to reject.
function M.parsepath(s)
	if type(s) ~= "string" then return nil, "not a path" end

	local name, rest = s:match("^%s*([%a_][%w_]*)(.*)$")

	if not name then
		return nil, "a path starts with a name"
	end

	-- one hop each, tried in order. A form that is not here cannot be
	-- written, which is how calls stay out.
	local hops = {
		{ "^%.([%a_][%w_]*)(.*)$", false },
		{ "^%[(%d+)%](.*)$", true },
		{ '^%["([^"]*)"%](.*)$', false },
		{ "^%['([^']*)'%](.*)$", false },
	}
	local path = {}

	while rest and rest ~= "" do
		local matched = false

		for _, h in ipairs(hops) do
			local k, r = rest:match(h[1])

			if k then
				path[#path + 1] = h[2] and tonumber(k) or k
				rest = r
				matched = true
				break
			end
		end
		if not matched then
			if rest:match("^%s*$") then break end
			return nil, "cannot read: " .. tostring(s)
		end
	end
	return name, path
end

-- A target, and the port its stops arrive on.
local Dbg = {}

Dbg.__index = Dbg

-- pid, plus the port its stops arrive on
function M.new(pid, port)
	local self = setmetatable({ pid = pid, port = port }, Dbg)

	return self
end

function Dbg:attach()
	return kdbg.attach(self.pid, self.port)
end

function Dbg:detach()
	self.stopped = nil
	return kdbg.detach(self.pid)
end

-- Record a stop notice. Returns false for a notice about another proc.
function Dbg:onstop(m)
	if type(m) ~= "table" or m.dbg ~= self.pid then return false end
	if m.exit then
		self.dead = true
		self.stopped = nil
		return true
	end
	self.stopped = true
	self.where = { file = m.file, line = m.line, co = m.co,
	    why = m.stop }
	self.co = m.co ~= 0 and m.co or 1
	self.level = 0
	return true
end

function Dbg:wheretext()
	if self.dead then return "the target is gone" end
	if not self.stopped then return "running" end

	local w = self.where or {}

	return ("stopped at %s:%s (%s, coroutine %s)"):format(
	    w.file or "?", tostring(w.line), w.why or "?", tostring(w.co))
end

-- A backtrace of the selected coroutine, innermost first.
function Dbg:backtrace()
	local out = {}

	for i, f in ipairs(kdbg.frames(self.pid, self.co or 1)) do
		out[#out + 1] = ("%s#%d %s:%d in %s (%s)"):format(
		    i - 1 == (self.level or 0) and "* " or "  ",
		    i - 1, f.source, f.line, f.name, f.what)
	end
	return out
end

function Dbg:slots(which)
	local f = which == "up" and kdbg.upvalues or kdbg.locals
	local out = {}

	for _, l in ipairs(f(self.pid, self.co or 1, self.level or 0)) do
		local line = ("  %s = %s"):format(l.name,
		    M.fmtvalue(l.value))
		local keys = M.fmtkeys(l.value)

		if keys then line = line .. "  { " .. keys .. " }" end
		if l.internal then line = line .. "   -- lua's own" end
		out[#out + 1] = line
	end
	return out
end

-- Print one value named by a literal path, trying it as a local, then
-- an upvalue, then a global -- which is the order lua itself resolves.
function Dbg:print(text)
	local name, path = M.parsepath(text)

	if not name then return nil, path end

	for _, root in ipairs({ "local", "upvalue", "global" }) do
		local ok, d = pcall(kdbg.get, self.pid, self.co or 1,
		    self.level or 0, root, name, path)

		if ok and d then
			local s = M.fmtvalue(d)
			local keys = M.fmtkeys(d)

			if keys then s = s .. "  { " .. keys .. " }" end
			return ("%s = %s   -- %s"):format(text, s, root)
		end
	end
	return nil, "no such value: " .. text
end

M.Dbg = Dbg
return M
