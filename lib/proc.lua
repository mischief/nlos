-- proc: spawn a proc that already has a namespace.
--
-- sys.spawn is the raw kernel primitive and stays that way: it takes a
-- chunk and an opaque arg and knows nothing about namespaces. this is
-- the policy on top, and it exists because the alternative was a line
-- of boilerplate at the top of every spawned chunk:
--
--	local N = assert(require("ns").adopt(...))
--
-- which is not merely tedious. it is OPTIONAL boilerplate, so a chunk
-- that omits it silently falls back to the ambient LUA_PATH searcher
-- and gets its modules from outside the namespace it was given -- the
-- exact failure the namespace exists to prevent, arrived at by
-- forgetting one line.
--
-- so the thing actually spawned is a fixed bootstrap, and the caller's
-- source travels in the arg as data. the bootstrap adopts, then loads
-- and runs the real chunk. the boilerplate exists once, here, and
-- cannot be forgotten.
--
-- this is what prog.lua already does for programs -- spawn
-- `require("prog").main()` and let it set up the environment --
-- generalised to anything.

local sys = require("los.sys")

local M = {}

-- adopt, then run the real chunk with the caller's own arg as its `...`.
-- load() gets an explicit chunkname so errors and tracebacks still name
-- the caller's source rather than this wrapper.
-- EVERYTHING THIS NEEDS IS REQUIRED BEFORE adopt(). adopting routes
-- require through the new namespace, and a confined namespace need not
-- contain /lib at all -- so a module pulled in afterwards is unfindable
-- and the child dies before its own first line.
local BOOT = [[
local a = ...
local stdout = require("stdout")
local log = require("log")

if a.ns then
	assert(require("ns").adopt(a.ns))
end
-- ALWAYS, even with no port: installing print/io.write over a nil port
-- is what makes "no stdout" mean nowhere. skipping the install leaves
-- the raw C print in place, so a child asked for silence writes to the
-- physical console instead.
stdout.set(a.out and a.out.__right or nil,
    a.err and a.err.__right or nil)
log.set(a.log and a.log.__right or nil)
return assert(load(a.src, a.name))(a.arg)
]]

-- spawn(src, opts) -> pid, handle
--
-- opts is sys.spawn's, plus:
--   ns    a namespace DESCRIPTION (ns:describe()), adopted before the
--         chunk runs. omitted means no namespace, and the chunk keeps
--         whatever the ambient searcher finds.
--   out   a port right for print/io.write. INHERITED from this proc by
--         default, since a child that silently stops printing is the
--         wrong default for debugging; pass `out = false` to mean
--         "genuinely nowhere". see lib/stdout.lua on why there is no
--         fallback to the raw console.
--   err   a separate port for io.stderr; defaults to `out`.
--   log   a port for stamped diagnostics (lib/log.lua), inherited like
--         `out`. `log = false` means nowhere.
--   arg   the caller's own value, delivered to the chunk as `...`.
function M.spawn(src, opts)
	opts = opts or {}

	local name = opts.name or "proc"

	-- inheritance is explicit at THIS layer rather than implicit at the
	-- bottom: the child is handed a right or it is handed nothing, and
	-- either way it is visible at the spawn site.
	local out = opts.out

	if out == nil then
		out = require("stdout").out
	end

	local logp = opts.log

	if logp == nil then
		logp = require("log").port
	end

	return sys.spawn(BOOT, {
		name = name,
		reductions = opts.reductions,
		mem = opts.mem,
		ports = opts.ports,
		arg = {
			ns = opts.ns,
			src = src,
			name = "=" .. name,
			arg = opts.arg,
			out = out and { __right = out } or nil,
			err = opts.err and { __right = opts.err } or nil,
			log = logp and { __right = logp } or nil,
		},
	})
end

return M
