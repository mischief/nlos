-- closing a tcp connection must wake a recv already parked on it.
--
-- The claim it defends is net_close's: it calls Cancel(0), which aborts
-- every token outstanding on that instance and signals their events, so
-- whichever poll function still owns one sees a normal (error)
-- completion on its next check. That is what lets lib/tcp.lua keep no
-- per-connection record of who is waiting -- checkpending answers them
-- from the token alone.
--
-- Worth a test because the failure mode is silent and remote from the
-- cause: a caller parked on a reply that never comes, in a task that
-- looks idle. It was reported as a real leak in this tree on nothing
-- but a benchmark timing out, and the timeout turned out to be
-- arithmetic (2055 reads at ~120ms). Assert it instead of assuming it
-- either way.
--
-- Needs NET=1 and a host that accepts a connection but sends nothing
-- unsolicited; a 9p server does, which is why it dials one.
local sys = require("los.sys")
local caps = require("caps")
local thread = require("los.thread")
local tap = require("tap")
tap.plan(3)
local g = sys.granted()
if not tap.ok(g.tcp ~= nil, "tcp capability") then tap.done() return end
local net = caps.tcp(g.tcp)
local dialed, woke, val = false, false, "unset"

thread.spawn(function()
	local id
	-- the firmware runs its own dhcp on its own clock, so the first
	-- dials after boot land before the guest has an address
	for _ = 1, 20 do
		id = net.dial(192, 168, 0, 150, 564)
		if id then
			dialed = true
			break
		end
		thread.sleep(500)
	end
	if not id then return end

	-- reader: the 9p server sends nothing unsolicited, so this parks
	thread.spawn(function()
		local d = net.recv(id, 4096)
		woke = true
		val = tostring(d)
	end)

	thread.sleep(1500)	-- let the recv be issued and park
	net.close(id)
	thread.sleep(2000)	-- give the wake a chance
end)
thread.run()

tap.ok(dialed, "dialed the 9p server")
tap.diag("woke=" .. tostring(woke) .. " val=" .. val)
tap.ok(woke, "a recv parked on a closed connection was woken")
tap.done()
