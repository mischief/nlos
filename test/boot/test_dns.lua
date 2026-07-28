-- dns over the udp task, end to end against qemu slirp's built-in
-- resolver at 10.0.2.3. needs NET=1.
local sys = require("los.sys")
local thread = require("los.thread")
local caps = require("caps")
local tap = require("tap")

tap.plan(3)

local dnspid, dnsh = sys.spawn(io.open("/lib/dns.lua"):read("a"),
    { name = "dns" })
sys.send(dnsh, { udp = { __right = sys.UDP } })

local dns = caps.dns(dnsh)

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
