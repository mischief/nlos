-- a whole TCP connection to ourselves, over 127.0.0.1.
--
-- Every other test of this stack needs something on the far side: slirp,
-- a host harness through hostfwd, an nc on an OpenBSD box. This one
-- needs nothing at all. The listener, the client, the state machines at
-- both ends and the ip task carrying between them are all in this
-- machine, and no frame reaches the wire.
--
-- That makes it the cheapest end-to-end test there is, and it covers
-- the part hardest to arrange otherwise: listen, accept, both halves of
-- a conversation and an orderly close, in one file with no coordination.
--
-- It is also the first thing to exercise the loopback path with a
-- protocol served in another proc. The datagram case landed in
-- task/ip.lua's own drain loop; tcp lives in task/tcp4.lua and reaches
-- it through the raw demux, and the two arrived separately.
--
-- No address is needed and none is waited for. 127.0.0.1 is reachable
-- on a machine that dhcp has never answered, which is the whole point of
-- the address, and gating this on a lease would make a test of loopback
-- into a test of the network.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")
local captcp = require("caps.tcp")

tap.plan(17)

local granted = sys.granted()

if not tap.ok(granted.tcp ~= nil, "the tcp task is running") then
	tap.done()
	return
end
tap.ok(granted.ip ~= nil, "and the ip task under it")

local net = captcp.new(granted.tcp)
local PORT = 7654

-- Both ends run as threads under thread.run(), and that is a
-- requirement rather than a style.
--
-- At the top level, captcp's calls go through sys.call, which blocks
-- the whole PROC -- so a spawned thread never runs and an accept parked
-- behind a dial never happens. The first version of this test did
-- exactly that and hung: the client connected, wrote, and waited
-- forever for a server that had not been scheduled. A loopback
-- connection has both of its ends inside one proc, so the two of them
-- have to be able to take turns.

local l = net.listen(PORT)

if not tap.ok(l ~= nil, "a listener binds a port") then
	tap.done()
	return
end

local served, answered

thread.spawn(function()
	local c = net.accept(l)

	if not c then
		return
	end
	answered = c

	local got = net.recv(c, 4096)

	if got then
		served = got
		net.send(c, "re: " .. got)
	end
end)

thread.spawn(function()
	local conn = net.dial(127, 0, 0, 1, PORT)

	if not tap.ok(conn ~= nil, "and a dial to 127.0.0.1 connects to it") then
		tap.done()
		return
	end

	tap.ok(net.send(conn, "hello") == true, "the client writes")

	local reply = net.recv(conn, 4096)

	tap.ok(answered ~= nil, "the listener accepted a connection")
	tap.is(served, "hello", "and read what the client sent")
	tap.is(reply, "re: hello", "the client reads the answer back")

	-- ---- both connections exist, and they are different ----
	--
	-- Two endpoints of one loopback connection live in the same task,
	-- so a key that did not distinguish them would deliver a segment to
	-- whichever was found first and the conversation would talk to
	-- itself.
	local st = thread.rpc(granted.tcp, { op = "stats" })

	tap.diag(string.format("conns=%d seg_in=%d seg_out=%d seg_bad=%d " ..
	    "no_conn=%d", st.conns, st.seg_in, st.seg_out, st.seg_bad,
	    st.no_conn))

	tap.is(st.conns, 2, "both ends of the connection are held separately")
	tap.is(st.seg_bad, 0, "no segment failed to decode")
	tap.is(st.no_conn, 0,
	    "and none arrived for a connection that did not exist")

	-- and nothing went near the wire: the ip task counts every frame
	-- it reads from the eth task, and a loopback packet is never one.
	local ips = thread.rpc(granted.ip, { op = "stats" })

	tap.diag(string.format("ip frames_out_fail=%d unresolved=%d",
	    ips.frames_out_fail, ips.unresolved))
	tap.is(ips.frames_out_fail, 0, "and no send failed for want of a route")

	-- ---- a body larger than the window, written then closed ----
	--
	-- The case that was silently truncated. close() sent its FIN
	-- immediately after whatever the window allowed, so everything past
	-- the initial congestion window stayed stranded in the send queue
	-- and the peer saw a clean end of stream: every http response over
	-- about 4KB, on both platforms, with no error at either end.
	--
	-- Three sizes, because 4096 passed throughout -- one small case
	-- would have gone on passing.
	local sizes = { 4096, 8192, 65536 }

	for _, size in ipairs(sizes) do
		local srv = net.listen(PORT + 1)
		local payload = string.rep("z", size)
		local back = ""

		thread.spawn(function()
			local c = net.accept(srv)

			if c then
				-- in pieces, because one send is one message
				-- and MAXMSG is 64KB -- which is also how
				-- lib/http.lua writes a large body.
				local off = 1

				while off <= #payload do
					net.send(c, payload:sub(off, off + 16383))
					off = off + 16384
				end
				net.close(c)
			end
		end)

		local cl = net.dial(127, 0, 0, 1, PORT + 1)

		while cl do
			local d = net.recv(cl, 16384)

			if not d then
				break
			end
			back = back .. d
		end
		if cl then
			net.close(cl)
		end
		net.close(srv)

		tap.is(#back, size,
		    "a " .. size .. "-byte body written then closed arrives whole")
	end

	net.close(conn)
	net.close(answered)
	net.close(l)

	-- Both ends of this connection are in TIME-WAIT, in one task, and
	-- that is the arrangement that found a real bug: acknowledging any
	-- acceptable segment in TIME-WAIT means two such peers acknowledge
	-- each other forever, and over loopback that exchange never leaves
	-- the machine.
	--
	-- What it costs is worse than throughput. Two procs that keep each
	-- other runnable hold kernel_run inside one lap, and every timer on
	-- the machine is serviced between laps -- so this sleep did not
	-- return late, it did not return at all. That half is a scheduler
	-- bug rather than ours (/tmp/schedbug.md), but a stack that
	-- generates an endless exchange is what walks into it, and this
	-- sleep is the cheapest thing that notices.
	tap.ok(thread.sleep(300), "the machine still keeps time after both ends close")

	local after = thread.rpc(granted.tcp, { op = "stats" })

	tap.diag("got stats")

	tap.diag("after close: conns=" .. after.conns)
	tap.is(after.reset_sent, 0, "closing sent no reset")

	tap.done()
end)

thread.run()
