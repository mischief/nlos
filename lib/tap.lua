-- tap: minimal TAP producer for boot tests. output goes to the
-- console (com1 serial); tools/boottest.sh extracts it. done()
-- powers the vm off (via conio, the only task allowed to touch
-- platform power) so the harness sees a clean qemu exit.

local sys = require("los.sys")

-- TAP goes to the console directly, captured at load time, so it cannot
-- be redirected by lib/stdout.lua. a test that redirects its own print
-- must still be able to report the result.
local emit = io.write

local M = { n = 0, failed = 0 }

-- how many ports this proc held when the test started, so done() can
-- say what it left behind. A leak is otherwise invisible until a
-- machine runs out of them weeks later, which is a long way from the
-- change that caused it.
local function myports()
	local ok, all = pcall(sys.ports)

	if not ok or type(all) ~= "table" then
		return nil
	end

	local me = sys.self and sys.self() or nil
	local n = 0

	for _, port in ipairs(all) do
		if not me or port.owner == me then
			n = n + 1
		end
	end
	return n
end

function M.plan(n)
	M.ports0 = myports()
	emit(("1..%d"):format(n) .. "\n")
	-- arm the power-off for when the payload's main chunk returns, so a
	-- test that runs off the end without calling done() still exits
	-- cleanly instead of leaving the guest to the harness timeout. done()
	-- is idempotent, so a test that still calls it explicitly is fine.
	sys.atexit(M.done)
end

-- assert this proc gave back every port it took. For a test whose
-- whole point is that something is released -- open a session, close
-- it, and say so -- rather than for one that leaves a server up.
function M.noleaks(name)
	local now = myports()

	if not M.ports0 or not now then
		return M.ok(true, (name or "ports") .. " (cannot count here)")
	end
	if not M.ok(now <= M.ports0,
	    name or "every port taken was given back") then
		emit(("# %d at start, %d now, %d leaked\n")
		    :format(M.ports0, now, now - M.ports0))
	end
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
	-- idempotent: plan() arms this via sys.atexit, and a test may also
	-- call it by hand. The first one powers off; the second is a no-op
	-- rather than a second reset message to the power task.
	if M.finished then
		return
	end
	M.finished = true

	-- what this proc is still holding. Reported rather than failed:
	-- a test that leaves a server running leaves its ports too, and
	-- that is the test working. A number that grows when nothing else
	-- changed is the signal, and tap.noleaks() below is for a test
	-- that means to end clean.
	local now = myports()

	if M.ports0 and now and now ~= M.ports0 then
		emit(("# ports: %d at start, %d at end (%+d)\n")
		    :format(M.ports0, now, now - M.ports0))
	end
	emit("# test complete, powering off\n")

	local power = sys.granted().power
	local cons = sys.granted().cons

	if power and cons then
		-- through the console, so the machine does not go down with
		-- output still queued: the two are different procs, and a
		-- reset sent straight to power overtakes the plan line that
		-- says whether the test passed. Waiting here instead is not
		-- open to us -- plan() arms this through sys.atexit, and a
		-- proc on its way out never sees the reply.
		sys.send(cons, { op = "poweroff", mode = "shutdown",
		    power = { __right = power } })
	elseif power then
		sys.send(power, { op = "reset", mode = "shutdown" })
	else
		emit("# no power capability; cannot power off\n")
	end
end

return M
