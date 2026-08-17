-- procfs: the process table as a filesystem, reached through ns.
local sys = require("los.sys")
local thread = require("los.thread")
local dev = require("dev")
local ns = require("ns")
local espfs = require("espfs")
local procfs = require("procfs")
local tap = require("tap")

tap.plan(17)

local N = ns.new()

N:mount("/", espfs.new("/"), "espfs", { root = "/" })
N:mount("/proc", procfs.new(), "procfs")

-- a proc wedged somewhere identifiable
local pid = sys.spawn([[
	local sys = require("los.sys")
	local thread = require("los.thread")

	local function inner(p)
		thread.recv(p)
	end

	inner(sys.newport("test_procfs"))
]], { name = "wedged" })

thread.sleep(200)

-- ---- it conforms to the same backend contract as everything else ----
tap.ok(pcall(dev.check, procfs.new(), "procfs"), "procfs satisfies dev.check")

-- ---- listing ----
local root = N:readdir("/proc")
local names = {}

for _, e in ipairs(root or {}) do
	names[e.name] = e
end
tap.ok(names[tostring(pid)] ~= nil, "/proc lists the spawned pid")
tap.ok(names[tostring(pid)].dir, "and it is a directory")
tap.ok(names["self"] ~= nil, "/proc has a self entry")

local files = N:readdir("/proc/" .. pid)
local fnames = {}

for _, e in ipairs(files or {}) do
	fnames[#fnames + 1] = e.name
end
table.sort(fnames)
tap.is(table.concat(fnames, ","), "mem,stack,status,trace",
    "a proc directory lists its files")

-- ---- reading, through the namespace like any other file ----
local status = N:readfile("/proc/" .. pid .. "/status")

tap.ok(status:find("name    wedged") ~= nil,
    "status names the proc: " .. (status:match("name%s+%S+") or "?"))
tap.ok(status:find("wchan   port#") ~= nil, "status carries wchan")

local stack = N:readfile("/proc/" .. pid .. "/stack")

tap.ok(stack:find("in inner") ~= nil,
    "stack shows the lua frame it is wedged in")
tap.ok(stack:find("(main)", 1, true) ~= nil, "and the frames below it")

-- NS:open answers a chan, whose read takes a byte count. A format is
-- io's word, and one passed here used to reach the backend and fail as
-- arithmetic on a string.
local sf = N:open("/proc/" .. pid .. "/stack", "r")
local whole = sf:read(65536)

tap.ok(whole:find("in inner") ~= nil, "a chan read takes a count")

local bad, baderr = sf:read("a")

tap.ok(bad == nil and tostring(baderr):find("count must be a number") ~= nil,
    "and says so for a format: " .. tostring(baderr))
sf:close()

local mem = N:readfile("/proc/" .. pid .. "/mem")

tap.ok(tonumber(mem:match("used%s+(%d+)")) > 0, "mem reports a live heap")

-- ---- self resolves to whoever reads ----
local myname = N:readfile("/proc/self/status"):match("name%s+(%S+)")

tap.is(myname, sys.name(sys.self()),
    "/proc/self is the reader, not the mounter (" .. tostring(myname) .. ")")

-- ---- stat is honest about size ----
local st = N:stat("/proc/" .. pid .. "/status")

tap.is(st.size, #status, "stat size matches what a read returns")

-- ---- read-only, structurally ----
tap.ok(N:writefile("/proc/" .. pid .. "/status", "nope") == nil,
    "writing to procfs fails")
tap.ok(N:create("/proc/newfile") == nil, "creating in procfs fails")

-- ---- a vanished proc reads as gone, not as garbage ----
local gone = sys.spawn("", { name = "brief" })

sys.monitor(gone)
local m

repeat
	m = thread.recv(sys.SELF)
until m.exit == gone

local dead, derr = N:readfile("/proc/" .. gone .. "/status")

tap.ok(dead == nil and tostring(derr):find(dev.Enonexist, 1, true) ~= nil,
    "an exited proc is Enonexist: " .. tostring(derr))

tap.done()
