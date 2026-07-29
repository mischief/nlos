-- print and io.write over a port (lib/stdout.lua).
--
-- the claim: a proc's output is a capability, so pointing it somewhere
-- else is granting a different right. that is what a browser terminal
-- needs and what it could not have while print was a C call straight to
-- console_write.
--
-- note what this test can do that was previously impossible: CAPTURE the
-- output of a child. before, a spawned proc's print went to the physical
-- console and nothing could observe it.

local sys = require("los.sys")
local thread = require("los.thread")
local proc = require("proc")
local stdout = require("stdout")
local tap = require("tap")

tap.plan(17)

-- a collector stands in for a terminal: drain everything queued and
-- return it, clearing as it goes.
local function collector()
	local port = sys.newport()
	local acc = {}

	return port, function()
		while true do
			local ok, m = sys.tryrecv(port)

			if not ok then
				local s = table.concat(acc)

				for i = #acc, 1, -1 do
					acc[i] = nil
				end
				return s
			end
			if m and m.op == "write" then
				acc[#acc + 1] = m.data
			end
		end
	end
end

-- ---- in this proc ----

local mine, drainmine = collector()

stdout.set(mine)

print("hello")
tap.is(drainmine(), "hello\n", "print goes to the port it was given")

print("a", "b", 3)
tap.is(drainmine(), "a\tb\t3\n", "tab separated, newline terminated, like lua")

io.write("no", "newline")
tap.is(drainmine(), "nonewline", "io.write concatenates and adds nothing")

io.stdout:write("via stdout")
tap.is(drainmine(), "via stdout", "io.stdout:write reaches the same port")

tap.ok(io.stdout:flush() ~= nil, "flush is a no-op, not an error")

-- ---- redirecting a RUNNING proc ----

local other, drainother = collector()

stdout.set(other)
print("moved")
tap.is(drainmine(), "", "the old port stops receiving")
tap.is(drainother(), "moved\n", "and the new one starts")

-- stderr follows stdout unless split
local errp, drainerr = collector()

stdout.set(other, errp)
io.stderr:write("bad")
tap.is(drainerr(), "bad", "io.stderr can be split from stdout")
tap.is(drainother(), "", "and stdout does not see it")

-- ---- a CHILD inherits it, which is the point ----

stdout.set(other)

local childdone = sys.newport()

proc.spawn([[
	print("from the child")
	io.write("and io.write too\n")
	require("los.sys").send((...).__right, { done = true })
]], { name = "talker", arg = { __right = childdone } })

tap.ok(thread.recvtimeout(childdone, 5000) ~= nil, "the child ran")
tap.is(drainother(), "from the child\nand io.write too\n",
    "a child's print was CAPTURED by its parent's port")

-- ---- a child pointed somewhere else ----

local elsewhere, drainelse = collector()
local done2 = sys.newport()

proc.spawn([[
	print("redirected")
	require("los.sys").send((...).__right, { done = true })
]], { name = "elsewhere", out = elsewhere, arg = { __right = done2 } })

tap.ok(thread.recvtimeout(done2, 5000) ~= nil, "the redirected child ran")
tap.is(drainelse(), "redirected\n", "its output went to the port it was given")
tap.is(drainother(), "", "and not to its parent's")

-- ---- out = false means nowhere, and must not crash ----

-- silence has to be REAL: the port-based print must be installed even
-- with no port, or the child keeps the raw C print and writes to the
-- physical console. the child reports whether it is installed, since a
-- test proc cannot observe the console it is printing to.
local done3 = sys.newport()

proc.spawn([[
	print("this must not reach the console")
	io.write("nor this")
	require("los.sys").send((...).__right, {
		done = true,
		installed = require("stdout").installed == true,
		out = require("stdout").out == nil,
	})
]], { name = "mute", out = false, arg = { __right = done3 } })

local m3 = thread.recvtimeout(done3, 5000)

tap.ok(m3 ~= nil,
    "a proc with no stdout still runs; printing is a no-op, not an error")
tap.ok(m3 and m3.installed and m3.out,
    "and its print is the port one over a nil port, not the raw console")
tap.is(drainother(), "", "nothing leaked to the parent's port either")

tap.done()
