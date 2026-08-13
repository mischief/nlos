-- eth: the sole task anywhere with los.platform.eth (raw virtio-net
-- frames). Every other proc holds, at most, a send-right to this task's
-- mailbox and talks by message:
--
--   {op="mac", reply={__right=}}              -> {mac=<6 bytes>}
--   {op="send", data=<frame>, reply=}         -> {ok=<bool>}
--   {op="listen", port={__right=}, reply=}    -> {ok=<bool>}
--   {op="irqs", reply=}                       -> {n=<count>}
--
-- listen is how frames are received: hand over a send right to a port
-- you own, and every frame from then on is pushed into it as
-- {data=<frame>}. Nothing is asked for and nothing is replied to.
--
-- Same shape as lib/tcp.lua and lib/udp.lua, and for the same reason:
-- one owner of the device, everyone else reaching it by right.
--
-- What is different is how far up it goes, which is not at all. tcp and
-- udp re-serve a stack the firmware already implements; there is no
-- such firmware here, so this task hands out frames and arp, ip, icmp
-- and udp are written above it in Lua. That is the deliberate shape --
-- C moves bytes between a queue and a string, and protocol is policy.
--
-- Pushing rather than answering is what makes receiving correct, and
-- the reason there is no recv op at all.
--
-- A request/reply recv can only deliver to a caller that is asking at
-- that instant, and a client is not always asking: between sending a
-- packet and waiting for the answer it is doing neither. slirp turns a
-- ping around in about 2us, comfortably inside that gap, so the reply
-- was handed to whichever other client happened to be parked and
-- thrown away -- microvm-ping failed about half its runs on exactly
-- that, with the reply plainly visible on the wire.
--
-- No amount of care in the client closes that window, because the
-- window is between two of its own operations. The frame has to be
-- queued somewhere the client is not required to be standing.
--
-- It is queued in a port, which is a queue the kernel already keeps,
-- with a bound (MAXQUEUE) and a hangup it already reports. Building a
-- second one here would be writing that again and worse. The machine
-- still halts between frames: the client blocks on its own port
-- instead of on a request parked in here.
--
-- Handle 1 is the wakeup, granted by the kernel at spawn: kernel.c's
-- pump_eth pushes into it when a virtio interrupt has been taken since
-- the last look. It carries no data -- the frames are still in the
-- device's queue -- so it means only "ask the device again".

local sys = require("los.sys")
local thread = require("los.thread")
local eth = require("los.platform.eth")
local buf = require("los.buf")

-- the radio, where the wire is one. Absent on a machine whose NIC has
-- nothing to associate with, and the "wifi" op below says so rather
-- than failing to load: every platform grants the module, and only one
-- of them puts anything in it.
local okwifi, wifi = pcall(require, "los.platform.wifi")

if not okwifi or type(wifi) ~= "table" or wifi.connect == nil then
	wifi = nil
end

local RAWETH = 1

-- send rights to the ports of everyone who asked to see frames. Held
-- for the life of the listener rather than closed after an answer, and
-- dropped when the far end hangs up.
local listeners = {}

local function reply(m, msg)
	local h = type(m.reply) == "table" and m.reply.__right or nil

	if h then
		sys.send(h, msg)
		sys.close(h)
	end
end

-- hand out whatever the device has. Every frame goes to EVERY parked
-- receiver, not to one of them.
--
-- A wire is not a queue with an owner. Several procs can have a
-- legitimate interest in the same frame -- the ip stack, a second
-- protocol family, a capture -- and handing each frame to whichever
-- happened to ask first means none of them sees a whole conversation.
-- That is not hypothetical: the moment kernel.c started the ip task at
-- boot, every test that drove the wire directly began losing frames to
-- it, which showed up as a ping that sometimes went unanswered.
--
-- This is the ethernet driver's job in plan 9 too: /net/ether0 hands a
-- copy to every connection whose type matches, rather than electing
-- one reader. There is no type filter here yet, so everyone sees
-- everything and filters for themselves -- ether.for_us and the
-- ethertype check in lib/inet.lua are already exactly that.
--
-- The cost is a copy per extra listener, and in an ordinary boot there
-- is one: the stack.
--
-- A listener whose port is full loses the frame and keeps its place.
-- That is what a nic does when a ring fills, and the alternative --
-- blocking here -- would let one slow reader stop the wire for
-- everyone. The drop is counted by the kernel against the port it was
-- refused by, which is the only place that can see it: from in here a
-- full queue and a fast reader look identical.
--
-- Nothing is drained while no one is listening. Frames stay in the
-- device's own queue instead, so a listener that registers a moment
-- after boot still finds what arrived before it -- and the device ring
-- bounds that on its own.
local function drain()
	while #listeners > 0 do
		local frame = eth.recv()

		if not frame then
			return
		end

		local msg = { data = frame }
		local live = {}

		for _, h in ipairs(listeners) do
			local ok, why = sys.send(h, msg)

			if ok or why == "full" then
				live[#live + 1] = h
			else
				sys.close(h)	-- hung up; stop copying to it
			end
		end
		listeners = live
	end
end

while true do
	local which, m = thread.alt({
		{ port = sys.SELF },
		{ port = RAWETH },
	})

	if which == 2 then
		-- the device signalled. It says nothing about how many
		-- frames are queued, so drain until the queue or the
		-- waiters run out.
		drain()
	elseif m.op == "mac" then
		reply(m, { mac = eth.mac() })
	elseif m.op == "send" then
		reply(m, { ok = (type(m.data) == "string" or
		    buf.is(m.data)) and eth.send(m.data) or false })
	elseif m.op == "listen" then
		local h = type(m.port) == "table" and m.port.__right or nil

		if h then
			listeners[#listeners + 1] = h
			reply(m, { ok = true })
			-- whatever the device already holds is this
			-- listener's too: nothing drained while the list was
			-- empty, and there may be no further interrupt to
			-- come back on.
			drain()
		else
			reply(m, { ok = false, err = "listen needs a port right" })
		end
	elseif m.op == "irqs" then
		reply(m, { n = eth.irqs() })
	elseif m.op == "wifi" then
		-- which network this wire is on.
		--
		-- Here rather than in a task of its own because the radio
		-- is one device and this proc owns it: nothing else holds
		-- los.platform.wifi, so nothing else could associate even
		-- if it wanted to. A machine whose NIC has no network to
		-- pick answers that it has none, which is what every
		-- platform but esp32 does.
		if not wifi then
			reply(m, { err = "no radio on this machine" })
		elseif m.how == "connect" then
			reply(m, { ok = wifi.connect(m.ssid, m.psk) })
		elseif m.how == "disconnect" then
			reply(m, { ok = wifi.disconnect() })
		-- a scan is seconds long, so it is started and collected
		-- separately: this proc pumps frames and must not sit in
		-- the radio waiting for one to finish.
		elseif m.how == "scan_begin" then
			reply(m, { ok = wifi.scan_begin ~= nil and
			    wifi.scan_begin() or false })
		elseif m.how == "scan_take" then
			reply(m, { aps = wifi.scan_take and wifi.scan_take() })
		else
			reply(m, { ok = wifi.status() })
		end
	else
		reply(m, { err = "unknown op" })
	end
end
