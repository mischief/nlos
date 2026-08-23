-- parbench: whether two procs overlap, or take turns.
--
--   > parbench [rounds]
--
-- One proc reads files, one computes. Alone, then together: one cpu
-- takes the sum, and less than the sum is overlap.

local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")
local proc = require("proc")

local N = prog.ns()

if not N then
	io.stderr:write("parbench: no namespace\n")
	os.exit(1)
end

local nsdesc = N:describe()
local ROUNDS = tonumber(arg and arg[1]) or 6

-- Both wait for a message before starting, so a spawn that is slow to
-- get going does not land inside the interval being timed.
local WORK = [[
local sys = require("los.sys")
local thread = require("los.thread")
local m = thread.recv(sys.SELF)
local reply = m.reply.__right

if m.kind == "cpu" then
	local x = 0

	for i = 1, m.n * 200000 do
		x = (x + i * 7) % 1000003
	end
	sys.send(reply, { done = x })
else
	local n = 0

	for _ = 1, m.n do
		for _, f in ipairs(m.files) do
			local h = io.open(f, "rb")

			if h then
				n = n + #(h:read("a") or "")
				h:close()
			end
		end
	end
	sys.send(reply, { done = n })
end
sys.close(reply)
]]

-- enough files that the reads dominate, and ones every build has
local files = {}

for _, f in ipairs(N:readdir("/lib") or {}) do
	if f.name:match("%.lua$") and #files < 12 then
		files[#files + 1] = "/lib/" .. f.name
	end
end

if #files == 0 then
	io.stderr:write("parbench: no files in /lib to read\n")
	os.exit(1)
end

local function start(kind, port)
	local pid, h = proc.spawn(WORK, { name = "pb-" .. kind, ns = nsdesc,
	    out = false })

	if not pid then
		io.stderr:write("parbench: cannot spawn\n")
		os.exit(1)
	end
	sys.send(h, { kind = kind, n = ROUNDS, files = files,
	    reply = { __right = sys.sendright(port) } })
	sys.close(h)
end

-- The clock starts before the sends and stops when both have answered,
-- so a spawn is inside neither measurement or both.
local function run(kinds)
	local port = sys.newport("parbench")
	local t0 = sys.uptime_ms()

	for _, k in ipairs(kinds) do
		start(k, port)
	end
	for _ = 1, #kinds do
		if not thread.recvtimeout(port, 120 * 1000) then
			io.stderr:write("parbench: a worker did not answer\n")
			os.exit(1)
		end
	end

	local ms = sys.uptime_ms() - t0

	sys.close(port)
	return ms
end

io.write(("%d cpus, %d rounds over %d files\n"):format(
    sys.stats().cpus or 1, ROUNDS, #files))

local tcpu = run({ "cpu" })
local tio = run({ "io" })
local both = run({ "cpu", "io" })

io.write(("cpu alone   %6d ms\n"):format(tcpu))
io.write(("io alone    %6d ms\n"):format(tio))
io.write(("together    %6d ms  (sum %d)\n"):format(both, tcpu + tio))
io.write(("overlap     %6.2fx\n"):format((tcpu + tio) / both))
