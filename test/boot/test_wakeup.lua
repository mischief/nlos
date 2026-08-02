-- one message must wake one thread, not all of them.
--
-- thread.run has a directed wakeup: sys.altblock returns a hint naming
-- the port that has something, and readyon wakes only the threads
-- parked on it. readyall -- wake everyone and let each find out for
-- itself -- is the fallback for a wake no port can account for.
--
-- that was the design. what the code did was
--
--     if hungupsince() or not (i and readyon(altset[i])) then
--
-- and `or` short-circuits, so whenever hungupsince() was true readyon
-- was never called at all. hungupsince() compares sys.hangups(), which
-- counts every port on the MACHINE losing a reference -- and a client
-- doing request/reply creates and drops a reply port per request, so on
-- any system with other procs doing ipc the counter had always moved.
-- the fallback was the only path that ever ran.
--
-- measured on the esp server before the fix, serving one file read:
-- readyon 0 calls, readyall 4, 32 coroutine resumes to deliver 4
-- messages, 1883 lines executed where 880 were needed.
--
-- the ports are made HERE and handed to the child in its spawn arg,
-- because the parent has to be able to poke one specific thread. a
-- right is a reference to the same port, so a send here is a delivery
-- to the thread parked there.

local tap = require("tap")
local sys = require("los.sys")
local thread = require("los.thread")

tap.plan(5)

-- 8 rights per message is the kernel limit (MAXMSGRIGHTS), and the
-- done port is one of them
local NTHREAD = 6
local NMSG = 6

local ports = {}

for i = 1, NTHREAD do
	ports[i] = sys.newport()
end

local done = sys.newport()

local pid = sys.spawn(([[
	local a = ...
	local sys = require("los.sys")
	local thread = require("los.thread")

	for i = 1, %d do
		thread.spawn(function()
			while true do
				thread.recv(a.ports[i].__right)
			end
		end)
	end
	sys.send(a.done.__right, "parked")
	thread.run()
]]):format(NTHREAD), {
	name = "herd",
	arg = { ports = (function()
		local t = {}
		for i = 1, NTHREAD do t[i] = { __right = ports[i] } end
		return t
	end)(), done = { __right = done } },
})

tap.ok(pid ~= nil, "the server proc started")
tap.ok(thread.recvtimeout(done, 5000) ~= nil, "and its threads parked")

-- let the last of them settle into altblock
thread.sleep(50)

sys.set_trace(pid, 6000)

-- poke one thread at a time, round robin. each send should wake exactly
-- the thread parked on that port.
for i = 1, NMSG do
	sys.send(ports[(i - 1) % NTHREAD + 1], "poke")
	thread.sleep(10)
end

local r = sys.trace(pid)

sys.set_trace(pid, 0)
tap.ok(#r > 0, "the server was traced (" .. #r .. " lines)")

-- readyall is the tell: it iterates thread._parked waking everything,
-- so its loop body runs once per parked thread per delivery. find the
-- line rather than hardcoding it, since this file should not have to be
-- edited every time lib/thread.lua moves.
local readyall_line, in_readyall
local f = io.open("/lib/thread.lua")
local n = 0

if f then
	for l in f:lines() do
		n = n + 1
		if l:find("^local function readyall") then
			in_readyall = true
		elseif in_readyall and l:find("thread%._ready%(co%)") then
			readyall_line = n
			in_readyall = false
		end
	end
	f:close()
end

tap.ok(readyall_line ~= nil, "found readyall's wake line in lib/thread.lua")

local herd, sched = 0, 0

for _, e in ipairs(r) do
	if e.source:find("thread%.lua") then
		sched = sched + 1
		if e.line == readyall_line then herd = herd + 1 end
	end
end

tap.diag(("%d lines, %d in the scheduler, %d readyall wakes"):format(
    #r, sched, herd))

-- stated as a ratio on purpose. the herd wakes NTHREAD threads per
-- message; the directed wakeup wakes about one. the two are far enough
-- apart that this threshold does not have to be delicate.
tap.ok(herd < NMSG * NTHREAD / 2,
    ("no thundering herd: %d readyall wakes, the herd would be ~%d")
    :format(herd, NMSG * NTHREAD))

for i = 1, NTHREAD do sys.close(ports[i]) end
sys.close(done)
tap.done()
