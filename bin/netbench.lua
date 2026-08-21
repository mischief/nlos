-- netbench: what a download costs.
--
--   > netbench http://192.168.0.12:8090/ [/sd/out.bin]
--
-- Bare, the body goes to a counter: the network alone. Named a file,
-- the same transfer with the storage put back in.

local unistd = require("posix.unistd")
local sys = require("los.sys")
local prog = require("prog")
local http = require("http")

local function die(s)
	unistd.write(2, "netbench: " .. s .. "\n")
	os.exit(1)
end

local url = arg[1]

if not url then
	unistd.write(2, "usage: netbench url\n")
	os.exit(2)
end
if not url:match("^%a+://") then
	url = "http://" .. url
end

local net = prog.net()

if not net then
	die("no network capability: this shell was lent none")
end

local out

if arg[2] then
	local err

	out, err = io.open(arg[2], "wb")
	if not out then
		die(tostring(err))
	end
end

-- cycles per proc, so the transfer is attributed rather than guessed
-- at. What the wall clock has that the sum does not is the kernel's.
local function cputimes()
	local t = {}

	for _, pid in ipairs(sys.procs()) do
		local st = sys.pidstat(pid)

		t[pid] = { name = st.name, cpu = st.cputime,
		    resumes = st.resumes, calls = sys.syscalls(pid) }
	end
	return t
end

-- the body is summed as it goes past, so a run says whether the bytes
-- were right as well as how fast they came. Compare with cksum on the
-- host, which is the same polynomial and seed.
local crc = require("los.crc")
local sum = 0xffffffff
local before = cputimes()
local total = 0
local parts = 0
local t0 = sys.uptime_ms()
local last = t0
local lastn = 0

local res, err = http.get(net, prog.dns(), url, {
	rand = prog.rand(),
	sink = function(part)
		total = total + #part
		parts = parts + 1
		sum = crc.crc32(part, sum)
		if out then
			out:write(part)
		end

		local now = sys.uptime_ms()

		if now - last >= 2000 then
			print(string.format("%8d KB  %7.1f KB/s",
			    total // 1024,
			    (total - lastn) * 1000 / (now - last) / 1024))
			last, lastn = now, total
		end
		return true
	end,
})

if not res then
	die(tostring(err))
end

if out then
	out:close()
end

local after = cputimes()
local dt = sys.uptime_ms() - t0
local s = net.stats and net.stats() or nil

print(string.format("%d bytes in %d ms = %.1f KB/s, %d parts (%.0f B each)",
    total, dt, total * 1000 / dt / 1024, parts, total / math.max(parts, 1)))
print(string.format("crc32 %08x", (~sum) & 0xffffffff))

if s then
	print(string.format("segments: in %d out %d bad %d",
	    s.seg_in or 0, s.seg_out or 0, s.seg_bad or 0))
end
if s and s.prof then
	local out = {}

	for k, v in pairs(s.prof) do
		out[#out + 1] = string.format("%s %d", k, v // 1000)
	end
	table.sort(out)
	print("tcp4 ms: " .. table.concat(out, "  "))
end
if s and s.ip and s.ip.eth and s.ip.eth.prof then
	local out = {}

	for k, v in pairs(s.ip.eth.prof) do
		out[#out + 1] = string.format("%s %d", k, v // 1000)
	end
	table.sort(out)
	print("eth ms:  " .. table.concat(out, "  "))
end

local cpms = sys.stats().cycles_per_ms
local rows = {}
local sum = 0

for pid, a in pairs(after) do
	local b = before[pid]
	local d = a.cpu - (b and b.cpu or 0)

	if d > 0 then
		local calls = {}

		for k, v in pairs(a.calls) do
			local was = b and b.calls[k] or 0

			if v - was > 0 then
				calls[#calls + 1] = k .. " " .. (v - was)
			end
		end
		table.sort(calls)
		rows[#rows + 1] = { name = a.name, ms = d // cpms,
		    resumes = a.resumes - (b and b.resumes or 0),
		    calls = table.concat(calls, " ") }
		sum = sum + d
	end
end
table.sort(rows, function(x, y) return x.ms > y.ms end)

print(string.format("cpu: %d ms of %d wall (%d%%), kernel %d ms",
    sum // cpms, dt, sum // cpms * 100 // dt, dt - sum // cpms))
for _, r in ipairs(rows) do
	if r.ms > 0 then
		print(string.format("  %-10s %6d ms %3d%% %6d resumes %6.2f ms each",
		    r.name, r.ms, r.ms * 100 // dt, r.resumes,
		    r.ms / math.max(r.resumes, 1)))
		print("      " .. r.calls)
	end
end
