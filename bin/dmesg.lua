-- dmesg: the kernel's transcript. -f follows it, -s sizes it.
--
-- No capability and no server: sys.dmesg reads the ring the kernel
-- writes, so this works on a machine with nothing else running.

local unistd = require("posix.unistd")
local sys = require("los.sys")

local function die(s)
	unistd.write(2, "dmesg: " .. s .. "\n")
	os.exit(1)
end

local follow, statonly = false, false

for _, a in ipairs(arg) do
	if a == "-f" then
		follow = true
	elseif a == "-s" then
		statonly = true
	else
		die("usage: dmesg [-f|-s]")
	end
end

if statonly then
	local seq, size, oldest, dropped = sys.loginfo()

	unistd.write(1, ("%d bytes held of %d, %d..%d, %d dropped\n"):format(
	    seq - oldest, size, oldest, seq, dropped))
	os.exit(0)
end

-- one call copies a chunk, so drain to the end before saying anything
-- about following.
local function drain(from)
	local cur = from

	while true do
		local data, next, dropped = sys.dmesg(cur)

		if dropped > 0 then
			unistd.write(1, ("[%d bytes lost]\n"):format(dropped))
		end
		if data == "" then
			return next
		end
		unistd.write(1, data)
		cur = next
	end
end

local cur = drain(nil)

-- nothing wakes a reader: the ring is memory, not a port. So a follower
-- polls, at a rate nobody notices at a console.
while follow do
	local t = sys.timer(200)

	if t then
		sys.block(t)
		sys.close(t)
	end
	cur = drain(cur)
end
