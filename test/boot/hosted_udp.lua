-- udp taken from the machine, on the same terms as hosted_tcp.lua:
-- los.platform.udp behind task/udp.lua, reached through the same
-- client every other machine reaches lib/udp4.lua by.

local sys = require("los.sys")
local udpc = require("client.udp")
local tap = require("tap")

tap.plan(7)

local caps = sys.granted()

if not tap.ok(caps.udp ~= nil, "a udp capability was granted") then
	tap.diag("no udp task; the rest cannot run")
	tap.done()
	return
end

local udp = udpc.new(caps.udp)
local APORT, BPORT = 17781, 17782

local a = udp.open(APORT)
local b = udp.open(BPORT)

tap.ok(a ~= nil, "opened a socket on " .. APORT)
tap.ok(b ~= nil, "opened a second on " .. BPORT)

tap.ok(udp.send(a, 127, 0, 0, 1, BPORT, "datagram"), "sent a datagram")

local got = udp.recv(b, 64)

tap.ok(got ~= nil and got.data == "datagram",
    "the other socket read it: " .. tostring(got and got.data))

-- a datagram reports where it came from, which is the whole difference
-- from a stream: there is no connection to remember it.
tap.ok(got ~= nil and got.port == APORT,
    "and the sender's port: " .. tostring(got and got.port))
tap.ok(got ~= nil and got.a == 127 and got.d == 1,
    "and the sender's address: " ..
    tostring(got and (got.a .. "." .. got.b .. "." .. got.c .. "." .. got.d)))

udp.close(a)
udp.close(b)
tap.done()
