-- tap: minimal TAP producer for boot tests. output goes to the
-- console (com1 serial); scripts/boottest.sh extracts it. done()
-- powers the vm off (via conio, the only task allowed to touch
-- platform power) so the harness sees a clean qemu exit.

local sys = require("los.sys")

local M = { n = 0, failed = 0 }

function M.plan(n)
	print(("1..%d"):format(n))
end

function M.ok(cond, name)
	M.n = M.n + 1
	if cond then
		print(("ok %d - %s"):format(M.n, name))
	else
		M.failed = M.failed + 1
		print(("not ok %d - %s"):format(M.n, name))
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
	print("# " .. tostring(s))
end

function M.done()
	print("# test complete, powering off")
	sys.send(sys.POWER, { op = "reset", mode = "shutdown" })
end

return M
