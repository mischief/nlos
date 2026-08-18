-- tcp taken from the machine rather than built on frames: the hosted
-- platform's los.platform.tcp, through the same task and client every
-- other machine reaches lib/tcp4.lua by. The guest is both ends --
-- what is under test is the platform module, not the loopback.

local sys = require("los.sys")
local tcpc = require("client.tcp")
local tap = require("tap")

tap.plan(9)

local caps = sys.granted()

if not tap.ok(caps.tcp ~= nil, "a tcp capability was granted") then
	tap.diag("no tcp task; the rest cannot run")
	tap.done()
	return
end

local tcp = tcpc.new(caps.tcp)
local PORT = 17771

local lid = tcp.listen(PORT)

tap.ok(lid ~= nil, "listened on " .. PORT)

-- dial before accept, and one thread is enough: the handshake finishes
-- into the listen backlog, so the connection is waiting by the time
-- anyone asks for it. Accepting first would park this proc on a
-- connection it has not made yet.
local cid = tcp.dial(127, 0, 0, 1, PORT)

tap.ok(cid ~= nil, "dialled the listener")
tap.ok(tcp.send(cid, "ping"), "sent to it")

local accepted = tcp.accept(lid)

tap.ok(accepted ~= nil, "the listener accepted a connection")

local got = tcp.recv(accepted, 64)

tap.ok(got == "ping", "and read what was sent: " .. tostring(got))
tcp.send(accepted, "pong")

local back = tcp.recv(cid, 64)

tap.ok(back == "pong", "the dialler read the answer: " .. tostring(back))

-- a closed connection reads as end of stream, not as an error: that is
-- what every reader above this tells "done" from "nothing yet" by.
tcp.close(accepted)

local eof = tcp.recv(cid, 64)

tap.ok(eof == nil, "a closed peer reads as end of stream")

tcp.close(cid)
tcp.close(lid)

-- the port comes back, which says the listener really was closed rather
-- than merely forgotten.
local again = tcp.listen(PORT)

tap.ok(again ~= nil, "the port is free again once closed")
if again then
	tcp.close(again)
end

tap.done()
