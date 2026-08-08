-- dns over our own ipv4 stack, end to end against qemu slirp's built-in
-- resolver at 10.0.2.3. needs NET=1.
local sys = require("los.sys")
local thread = require("los.thread")
local dnsc = require("client.dns")
local udpc = require("client.udp")
local tap = require("tap")
local caps_of = sys.granted()

tap.plan(3)

local dnspid, dnsh = sys.spawn(io.open("/task/dns.lua"):read("a"),
    { name = "dns" })
-- the ip task speaks the udp protocol: there is no separate udp
-- capability on any platform, and one name for it is the point.
sys.send(dnsh, { ip = { __right = caps_of.ip } })

local dns = dnsc.new(dnsh)

-- localhost is answered by slirp itself, with no upstream involved,
-- so this half of the test works on a machine with no internet.
local ip = dns.resolve("localhost")
tap.ok(ip ~= nil, "resolved localhost -> " .. tostring(ip))
tap.ok(ip == nil or ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil,
    "reply parses as dotted quad")

-- a name that cannot resolve must come back nil rather than hanging
-- or killing the task: udp is lossy, and try_once has a real deadline.
local bad = dns.resolve("no-such-host.invalid")
tap.ok(bad == nil, "unresolvable name returns nil, task survives")

tap.done()
