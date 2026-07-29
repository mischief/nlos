-- log: stamped diagnostics, distinct from print.
--
-- print is a proc's OUTPUT and must stay verbatim -- `seq 5` emits
-- "1\n2\n..." and nothing else. log is the machine's transcript: what
-- attached, what died, what a task decided. linux keeps these apart as
-- printk and stdout, and that separation is the only reason stamping is
-- tolerable at all.
--
-- ---- the format is shared with the kernel ----
--
-- kernel.c's klog() produces the same "[%5llu.%03llu] " prefix. two
-- producers, one transcript, so it has to be agreed rather than
-- accreted: change one and change the other.
--
-- the stamp is taken when the line is EMITTED, not when it is displayed,
-- and that is load-bearing here rather than decorative. the kernel writes
-- the console synchronously while this goes through a port, so a lua log
-- line emitted before a kernel one can appear after it. the stamps are
-- what let the real order be recovered.
--
-- ---- where it goes ----
--
-- {op="log", data=} to the same cons task that takes {op="write"}, so a
-- proc needs no second capability to be able to report. a proc with no
-- log port logs nowhere, for the same reason lib/stdout.lua has no
-- fallback: a fallback is indistinguishable from a grant.

local sys = require("los.sys")

local M = {}

-- tag defaults to this proc's own name, which is what makes a line
-- attributable without every caller repeating it.
function M.set(port, tag)
	M.port = port
	M.tag = tag or sys.name(sys.self())
end

function M.write(s)
	if not M.port then
		return
	end

	local ms = sys.uptime_ms()
	local line = ("[%5d.%03d] %s: %s\n"):format(ms // 1000, ms % 1000,
	    M.tag or "?", s)

	pcall(sys.send, M.port, { op = "log", data = line })
end

-- log("dhcp bound %s", addr) -- format if given extra arguments, so a
-- caller never has to build the string when it might be discarded.
function M.log(fmt, ...)
	if not M.port then
		return
	end
	if select("#", ...) > 0 then
		M.write(fmt:format(...))
	else
		M.write(tostring(fmt))
	end
end

return M
