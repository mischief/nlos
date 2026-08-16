-- blesrv: the one proc that owns the bluetooth controller.
--
-- A controller is a singleton with singleton state -- one advertising
-- configuration, one scan, one attribute database, one budget of
-- activities -- so something has to arbitrate. Clients hold a right to
-- this mailbox and are handed rights of their own for what they asked.

local sys = require("los.sys")
local thread = require("los.thread")
local hcilib = require("ble.hci")
local l2cap = require("ble.l2cap")
local att = require("ble.att")
local gatt = require("ble.gatt")
local gattc = require("ble.gattc")
local gap = require("ble.gap")
local ad = require("ble.ad")
local uuid = require("ble.uuid")

-- the spawn argument, where a service's capabilities arrive. Not
-- sys.granted(), which is the kernel's own table and holds only what it
-- spawned itself -- a service started from /etc/services.lua is handed
-- its rights here instead.
local a = ...
local hci = a and a.hci and a.hci.__right

if not hci then
	sys.log("blesrv: no bluetooth on this machine")
	return
end

-- the controller's own limit, and what it is spent on. Connections,
-- the scan and the advertising set all draw on the same budget, so a
-- node that advertises and scans has two gone before a peer attaches.
local MAXACT = 10

local codec = hcilib.new()
local chans = l2cap.new(27)
local db = gatt.new()

local conns = {}		-- handle -> connection
local nconn = 0
local advertising, scanning = false, false
-- what advertising the app asked for, so it can be put back after a
-- peer connects and the controller drops it.
local advwant

-- Links held at once. The controller's budget is MAXACT between links,
-- the scan and the advertising set, and a mesh node that took all of it
-- would leave nothing for a second program wanting the radio.
local MAXLINKS = 3

-- defined below, where the advertising commands are; the event loop
-- above reaches it when a link comes or goes.
local readvertise
local watchers = {}		-- send rights, by what they asked to see
local services = {}		-- registered services, in handle order

local evport = sys.newport("blesrv.hci")

do
	-- a port of its own for the acknowledgement: replying to SELF
	-- would put it in the queue a client's first request arrives on,
	-- and the wrong one would be taken for the other.
	local ack = sys.newport("blesrv.ack")
	local guard <close> = sys.owned(ack)

	sys.send(hci, { op = "listen", port = { __right = evport },
	    reply = { __right = ack } })
	if not thread.recvtimeout(ack, 2000) then
		sys.log("blesrv: the hci task would not register a listener")
		return
	end
end

-- ---- talking to the controller ----

local answers = {}

local function writeout()
	local pkt = codec:pull()

	while pkt do
		sys.send(hci, { op = "send", data = pkt })
		pkt = codec:pull()
	end
end

local function activities()
	return nconn + (advertising and 1 or 0) + (scanning and 1 or 0)
end

-- a client that has gone takes its services with it. sys.hungup says
-- nobody else holds the port, which for a right this proc was handed
-- means the program that gave it has exited.
local function reap()
	local kept = {}

	for _, s in ipairs(services) do
		if s.owner and sys.hungup(s.owner) then
			db:remove(s)
			sys.close(s.owner)
			sys.log("blesrv: took back handles %d-%d",
			    s.decl.handle, s.decl.last)
		else
			kept[#kept + 1] = s
		end
	end
	services = kept
end

-- tell everyone who asked to hear about this kind of thing. A right
-- that has hung up is dropped rather than retried.
local function tell(kind, msg)
	local live = {}

	msg.kind = kind
	for _, w in ipairs(watchers) do
		if w.want == kind or w.want == "all" then
			local ok, why = sys.send(w.port, msg)

			if ok or why == "full" then
				live[#live + 1] = w
			else
				sys.close(w.port)
			end
		else
			live[#live + 1] = w
		end
	end
	watchers = live
end

local function sendatt(handle, pdu)
	local c = conns[handle]

	if not c then
		return false
	end
	for _, f in ipairs(chans:frame(handle, l2cap.CID_ATT, pdu)) do
		codec:acl(f.handle, f.data, f.pb)
	end
	writeout()
	return true
end

-- an ATT pdu from a peer. Both roles live on one link: a response
-- answers what this asked, a request is the peer asking us, and a
-- notification is neither.
local function onatt(handle, pdu)
	local c = conns[handle]

	if not c then
		return
	end

	local kind = att.kind(pdu:byte(1) or 0)

	if kind == "response" then
		if c.waiting then
			local w = c.waiting

			c.waiting = nil
			sys.send(w, { kind = "reply", handle = handle,
			    pdu = pdu })
			sys.close(w)
		end
	elseif kind == "request" then
		local m = att.decode(pdu)

		if m and m.op == att.OP_MTU_REQ then
			c.mtu = math.min(m.mtu, 185)
			sendatt(handle, att.mtursp(185))
		else
			local rsp = db:request(pdu, c.mtu)

			if rsp then
				sendatt(handle, rsp)
			end
			-- a write reaches whoever registered the service
			if m and (m.op == att.OP_WRITE_REQ or
			    m.op == att.OP_WRITE_CMD) then
				tell("write", { handle = handle,
				    attr = m.handle, value = m.value })
			end
		end
	elseif kind == "command" then
		-- a write with no response, which is what a peer sending
		-- data rather than asking a question uses. Nothing is owed
		-- back, but the write still has to reach whoever serves it.
		local m = att.decode(pdu)

		db:request(pdu, c.mtu)
		if m and m.handle then
			tell("write", { handle = handle, attr = m.handle,
			    value = m.value })
		end
	elseif kind == "notify" or kind == "indicate" then
		local h, v = gattc.update(pdu)

		tell("notify", { handle = handle, attr = h, value = v })
		if kind == "indicate" then
			sendatt(handle, att.confirm())
		end
	end
end

local function drain()
	local ev = codec:next()

	while ev do
		if ev.kind == "acl" then
			local h, cid, payload = chans:acl(ev.handle, ev.pb,
			    ev.data)

			if h and cid == l2cap.CID_ATT then
				onatt(h, payload)
			end
		elseif ev.kind == "complete" or ev.kind == "status" then
			answers[ev.opcode] = ev
		elseif ev.kind == "le" and
		    ev.subevent == gap.SUB_ADV_REPORT then
			for _, r in ipairs(gap.advreports(ev.params)) do
				local f = ad.parse(r.data)

				tell("adv", { addr = gap.addrstr(r.addr),
				    raw = r.addr, addrtype = r.addrtype,
				    rssi = r.rssi, name = f.name,
				    uuids = f.uuids, data = r.data })
			end
		elseif ev.kind == "le" and
		    (ev.subevent == gap.SUB_CONN_COMPLETE or
		     ev.subevent == gap.SUB_ENHANCED_CONN_COMPLETE) then
			local r = gap.connreport(ev.params)

			if r and r.status == 0 then
				conns[r.handle] = { addr = r.addr,
				    role = r.role, mtu = att.DEFAULT_MTU }
				nconn = nconn + 1
				-- advertising stops when a peer connects,
				-- so the budget frees and the state is stale.
				if r.role == 1 then
					advertising = false
				end
				readvertise()
				tell("link", { handle = r.handle,
				    addr = gap.addrstr(r.addr),
				    role = r.role, up = true })
			end
			answers[gap.CREATE_CONN] = { kind = "conn",
			    status = r and r.status or 0xff,
			    handle = r and r.handle }
		elseif ev.kind == "event" and
		    ev.code == gap.EVT_DISCONN_COMPLETE then
			local _, h, why = string.unpack("<BI2B", ev.params)

			if conns[h] then
				conns[h] = nil
				nconn = nconn - 1
			end
			chans:closed(h)
			readvertise()
			tell("link", { handle = h, up = false, reason = why })
		end
		ev = codec:next()
	end
end

local function command(opcode, params, ms)
	answers[opcode] = nil
	codec:command(opcode, params)
	writeout()

	local deadline = sys.uptime_ms() + (ms or 3000)

	while sys.uptime_ms() < deadline do
		local m = thread.recvtimeout(evport,
		    math.min(200, deadline - sys.uptime_ms()))

		if m and m.data then
			codec:feed(m.data)
		end
		drain()

		if answers[opcode] then
			local e = answers[opcode]

			answers[opcode] = nil
			writeout()
			return e
		end
	end
	return nil
end

-- ---- what clients ask for ----

local function reply(m, msg)
	local h = type(m.reply) == "table" and m.reply.__right or nil

	if h then
		sys.send(h, msg)
		sys.close(h)
	end
end

local ops = {}

-- watch: a right to hear about advertisements, links, writes or
-- notifications. The one call that hands out no capability of its own,
-- because what it gives is already the client's port.
function ops.watch(m)
	local h = type(m.port) == "table" and m.port.__right or nil

	if not h then
		return reply(m, { err = "watch needs a port right" })
	end
	watchers[#watchers + 1] = { port = h, want = m.want or "all" }
	reply(m, { ok = true })
end

-- advertise again after a link changed, while there is room for
-- another. Declared before ops so the event loop can reach it.
function readvertise()
	if not advwant or advertising or nconn >= MAXLINKS then
		return
	end
	if activities() >= MAXACT then
		return
	end

	local body = ad.simple(advwant.name, advwant.service)

	if not body then
		return
	end
	command(gap.advenable(false))

	local st = command(gap.advparams({}))

	if not st or st.status ~= 0 then
		return
	end
	command(gap.advdata(body))
	st = command(gap.advenable(true))
	advertising = st and st.status == 0
end

function ops.advertise(m)
	if m.on == false then
		advwant = nil
		command(gap.advenable(false))
		advertising = false
		return reply(m, { ok = true })
	end
	-- kept, because advertising is not a state that stays put: the
	-- controller drops it the moment a peer connects, and a mesh node
	-- wants to be found again by the next one.
	advwant = { name = m.name, service = m.service }
	if not advertising and activities() >= MAXACT then
		return reply(m, { err = "no activities left" })
	end
	-- asked for and remembered, but not started: readvertise puts it
	-- up as soon as a link drops below the cap.
	if nconn >= MAXLINKS then
		return reply(m, { ok = false, err = "links full" })
	end

	local body, aerr = ad.simple(m.name, m.service)

	if not body then
		return reply(m, { err = aerr })
	end

	command(gap.advenable(false))
	local st = command(gap.advparams({}))

	if not st or st.status ~= 0 then
		return reply(m, { err = "advertising parameters refused" })
	end
	command(gap.advdata(body))
	st = command(gap.advenable(true))
	advertising = st and st.status == 0
	reply(m, { ok = advertising })
end

function ops.scan(m)
	if m.on == false then
		command(gap.scanenable(false, false))
		scanning = false
		return reply(m, { ok = true })
	end
	if not scanning and activities() >= MAXACT then
		return reply(m, { err = "no activities left" })
	end

	command(gap.scanenable(false, false))
	command(gap.scanparams({ active = m.active }))
	local st = command(gap.scanenable(true, m.dedup))

	scanning = st and st.status == 0
	reply(m, { ok = scanning })
end

function ops.connect(m)
	if activities() >= MAXACT then
		return reply(m, { err = "no activities left" })
	end

	local addr = m.raw or (m.addr and gap.parseaddr(m.addr))

	if not addr then
		return reply(m, { err = "connect needs an address" })
	end

	local st = command(gap.connect(addr, {
	    addr_type = m.random and gap.ADDR_RANDOM or gap.ADDR_PUBLIC }))

	if not st or st.status ~= 0 then
		return reply(m, { err = "the controller refused to connect" })
	end

	-- the completion is an event, not the command's answer, so this
	-- waits for the link rather than for the command.
	local deadline = sys.uptime_ms() + (m.timeout_ms or 10000)

	while sys.uptime_ms() < deadline do
		local got = thread.recvtimeout(evport, 200)

		if got and got.data then
			codec:feed(got.data)
		end
		drain()

		local a = answers[gap.CREATE_CONN]

		if a and a.kind == "conn" then
			answers[gap.CREATE_CONN] = nil
			if a.status == 0 then
				return reply(m, { ok = true,
				    handle = a.handle })
			end
			return reply(m, { err = string.format(
			    "connection failed, status 0x%02x", a.status) })
		end
	end
	command(gap.CREATE_CONN_CANCEL)
	reply(m, { err = "the peer never answered" })
end

function ops.disconnect(m)
	if not conns[m.handle] then
		return reply(m, { err = "no such connection" })
	end
	command(gap.disconnect(m.handle))
	reply(m, { ok = true })
end

-- an ATT pdu out on a link, with the answer sent to the reply right
-- when one comes. One request is outstanding per connection, which is
-- ATT's own rule and not a simplification.
function ops.att(m)
	local c = conns[m.handle]

	if not c then
		return reply(m, { err = "no such connection" })
	end
	if c.waiting then
		return reply(m, { err = "a request is already outstanding" })
	end

	local h = type(m.reply) == "table" and m.reply.__right or nil

	if att.kind(m.pdu:byte(1) or 0) == "request" and h then
		c.waiting = h
		sendatt(m.handle, m.pdu)
		return		-- answered when the peer answers
	end
	sendatt(m.handle, m.pdu)
	reply(m, { ok = true })
end

-- register a service in the one database this controller has. The
-- handles are the database's to allocate, so they come back with it.
function ops.serve(m)
	if type(m.service) ~= "string" or type(m.chars) ~= "table" then
		return reply(m, { err = "serve needs a service and chars" })
	end

	-- a service belongs to the client that registered it. Without an
	-- owner to outlive, every run of a program would add another copy
	-- at new handles while a peer kept writing to the old ones.
	local owner = type(m.port) == "table" and m.port.__right or nil

	if not owner then
		return reply(m, { err = "serve needs the port to own it" })
	end

	local svc = db:service(m.service, m.chars)

	svc.owner = owner
	local out = { start = svc.decl.handle, last = svc.decl.last,
	    chars = {} }

	for i, c in ipairs(svc.chars) do
		out.chars[i] = { value = c.value.handle,
		    cccd = c.cccd and c.cccd.handle }
	end
	services[#services + 1] = svc
	reply(m, { ok = true, handles = out })
end

-- notify subscribers of a characteristic this machine serves.
function ops.notify(m)
	for _, svc in ipairs(services) do
		for _, c in ipairs(svc.chars) do
			if c.value.handle == m.attr then
				local pdu = gatt.notify(c, m.value)

				if not pdu then
					return reply(m, { ok = false,
					    err = "nobody subscribed" })
				end
				-- `except` is the link a relayed packet
				-- arrived on: sending it back where it
				-- came from is the loop a mesh has to
				-- avoid.
				for h in pairs(conns) do
					if h ~= m.except then
						sendatt(h, pdu)
					end
				end
				return reply(m, { ok = true })
			end
		end
	end
	reply(m, { err = "no such characteristic" })
end

function ops.status(m)
	local links = {}

	for h, c in pairs(conns) do
		links[#links + 1] = { handle = h, addr = gap.addrstr(c.addr),
		    role = c.role, mtu = c.mtu }
	end
	reply(m, { ok = true, advertising = advertising, scanning = scanning,
	    activities = activities(), max = MAXACT, links = links })
end

-- ---- the loop ----

local bufs = command(gap.READ_BUFFER_SIZE)

if bufs and bufs.status == 0 and #bufs.params >= 4 then
	local aclmtu, count = string.unpack("<I2B", bufs.params:sub(2))

	if aclmtu > 0 then
		chans:aclmtu(aclmtu)
		codec:aclbuffers(count)
	end
end

sys.log("blesrv: ready, %d activities", MAXACT)

while true do
	local which, m = thread.alt({
		{ port = sys.SELF },
		{ port = evport },
	})

	if which == 2 then
		-- a quiet moment is when a departed client's handles come
		-- back, which is cheap and needs no timer of its own.
		reap()
		if m and m.data then
			codec:feed(m.data)
		end
		drain()
	elseif type(m) == "table" and ops[m.op] then
		local ok, err = pcall(ops[m.op], m)

		if not ok then
			sys.log("blesrv: %s: %s", tostring(m.op), tostring(err))
			reply(m, { err = tostring(err) })
		end
	else
		reply(m, { err = "unknown op" })
	end
end
