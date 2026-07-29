-- tap: minimal TAP producer for boot tests. output goes to the
-- console (com1 serial); scripts/boottest.sh extracts it. done()
-- powers the vm off (via conio, the only task allowed to touch
-- platform power) so the harness sees a clean qemu exit.

local sys = require("los.sys")

-- TAP goes to the console directly, captured at load time, so it cannot
-- be redirected by lib/stdout.lua. a test that redirects its own print
-- must still be able to report the result.
local emit = io.write

local M = { n = 0, failed = 0 }

function M.plan(n)
	emit(("1..%d"):format(n) .. "\n")
end

function M.ok(cond, name)
	M.n = M.n + 1
	if cond then
		emit(("ok %d - %s"):format(M.n, name) .. "\n")
	else
		M.failed = M.failed + 1
		emit(("not ok %d - %s"):format(M.n, name) .. "\n")
	end
	return cond
end

function M.is(got, want, name)
	local same = got == want
	if not same then
		M.diag(("%s: got %s, want %s"):format(name, tostring(got),
		    tostring(want)))
	end
	return M.ok(same, name)
end

function M.diag(s)
	emit("# " .. tostring(s) .. "\n")
end

function M.done()
	emit("# test complete, powering off\n")
	-- a tap payload is always the boot payload (injected via fw_cfg in
	-- place of init.lua), so the power capability is in its own grant
	-- table. there is no well-known handle number to use instead.
	local power = sys.granted().power

	if power then
		sys.send(power, { op = "reset", mode = "shutdown" })
	else
		emit("# no power capability; cannot power off\n")
	end
end

return M
