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
local BOOT = [[
local a = ...

if a.ns then
	assert(require("ns").adopt(a.ns))
end
return assert(load(a.src, a.name))(a.arg)
]]

-- spawn(src, opts) -> pid, handle
--
-- opts is sys.spawn's, plus:
--   ns    a namespace DESCRIPTION (ns:describe()), adopted before the
--         chunk runs. omitted means no namespace, and the chunk keeps
--         whatever the ambient searcher finds.
--   arg   the caller's own value, delivered to the chunk as `...`.
function M.spawn(src, opts)
	opts = opts or {}

	local name = opts.name or "proc"

	return sys.spawn(BOOT, {
		name = name,
		reductions = opts.reductions,
		mem = opts.mem,
		arg = {
			ns = opts.ns,
			src = src,
			name = "=" .. name,
			arg = opts.arg,
		},
	})
end

return M
