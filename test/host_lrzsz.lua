#!/usr/bin/env lua5.4
-- lib/zmodem.lua against lrzsz: sz sends us a file, we send one to rz.
--
-- Every other test drives our machine against itself, which proves
-- consistency and not correctness -- two ends sharing a misreading of
-- Forsberg agree perfectly. This is the only one that asks something
-- that has never seen our code, and it is where a field read the wrong
-- way round or a check computed by the other convention stops being
-- invisible. It found one immediately: ESCCTL is a promise about what
-- you send, and a peer in that mode *discards* the control characters
-- you leave raw.
--
-- Three rounds, because the two ends do not negotiate the same way in
-- each: escape-everything with crc32, minimal escaping with crc32, and
-- minimal escaping with crc16.
--
-- Optional by construction. meson registers this only where sz, rz and
-- socat are on the host, and nothing in the guest depends on any of
-- them -- socat is here because lrzsz wants its stdio on a pipe pair
-- and hostutil hands out sockets.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local hostutil = assert(package.loadlib(os.getenv("HOSTUTIL_SO") or
    "./hostutil.so", "luaopen_hostutil"))()
local zmodem = require("zmodem")

local SIZE = 512 * 1024

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
	return cond
end

local function diag(s)
	io.write("# " .. tostring(s) .. "\n")
end

io.write("1..9\n")

local function popen_line(cmd)
	local f = io.popen(cmd)

	if not f then
		return nil
	end

	local l = f:read("l")

	f:close()
	return l
end

local tmp = assert(popen_line("mktemp -d"), "mktemp -d failed")

-- every byte value appears, so the escaper and the unescaper both have
-- work to do whichever set is in force
local function gen(off, n)
	local b = {}

	for i = 1, n do
		b[i] = string.char(((off + i) * 37 + 11) & 0xff)
	end
	return table.concat(b)
end

local payload = {}

for off = 0, SIZE - 1, 8192 do
	payload[#payload + 1] = gen(off, math.min(8192, SIZE - off))
end
payload = table.concat(payload)

local src = tmp .. "/payload.bin"
local pf = assert(io.open(src, "wb"))

pf:write(payload)
pf:close()

-- run one lrzsz process with its stdin and stdout on a socket we hold,
-- and drive `m` against it. socat's EXEC splits the command on spaces
-- itself, so nothing here goes through a shell unless the address says
-- SYSTEM.
local function against(addr, m)
	local lfd, port = hostutil.listen_tcp()

	if not lfd then
		return nil, "listen: " .. tostring(port)
	end

	local pid = hostutil.spawn({ "socat", "TCP:127.0.0.1:" .. port, addr })

	if not pid then
		hostutil.close(lfd)
		return nil, "socat did not start"
	end

	local fd, err = hostutil.accept(lfd, 10)

	hostutil.close(lfd)
	if not fd then
		hostutil.kill(pid)
		hostutil.wait(pid)
		return nil, "accept: " .. tostring(err)
	end

	local line = {
		-- monotonic, NOT os.clock: that is cpu time, so a driver
		-- starved of cpu never notices time passing and measures a
		-- protocol deadline against its own busyness.
		now = hostutil.now,
		-- hostutil.send writes the whole string or fails
		write = function(s)
			assert(hostutil.send(fd, s), "send failed")
		end,
		read = function(ms)
			return hostutil.recv(fd, 65536,
			    ms > 0 and ms / 1000 or 0.05)
		end,
	}

	local res, rerr = zmodem.drive(m, line)

	hostutil.close(fd)
	hostutil.wait(pid)
	return res, rerr
end

-- ---- sz sends, we receive ----
--
-- -b is binary. -e is escape every control character, which is the mode
-- that obliges us to do the same; the round without it takes the other
-- path.
local function fromsz(what, szargs, opts)
	local bytes, bad = 0, nil

	opts.timeout = 5000
	opts.sink = function()
		return { write = function(off, s)
			if off ~= bytes then
				bad = bad or ("out of order at " .. off)
			elseif s ~= payload:sub(off + 1, off + #s) then
				bad = bad or ("wrong bytes at " .. off)
			end
			bytes = bytes + #s
		end }
	end

	local rx = zmodem.receiver(opts)
	local files, err = against("EXEC:lsz " .. szargs .. " " .. src, rx)

	if ok(files ~= nil, what .. ": sz completed a transfer to us") then
		ok(files[1] and files[1].name == "payload.bin",
		    what .. ": the name sz sent came through as " ..
		    tostring(files[1] and files[1].name))
		if not ok(bytes == SIZE and bad == nil,
		    ("%s: all %d bytes, unaltered"):format(what, SIZE)) then
			diag(("got %d bytes, %s"):format(bytes, tostring(bad)))
		end
	else
		diag(tostring(err))
		ok(false, what .. ": the name sz sent came through")
		ok(false, what .. ": all bytes, unaltered")
	end
end

-- ---- we send, rz receives ----
--
-- -y overwrites instead of asking. The cd has to happen in the child,
-- so this one does go through a shell.
local function torz(what, opts)
	local dst = tmp .. "/" .. what

	os.execute("mkdir -p '" .. dst .. "'")
	opts.timeout = 5000
	opts.blocksize = 8192

	local tx = zmodem.sender({ name = "ours.bin", size = SIZE,
	    read = gen }, opts)
	local sent, err = against("SYSTEM:cd " .. dst .. " && exec lrz -y -b",
	    tx)

	if ok(sent ~= nil, what .. ": we completed a transfer to rz") then
		local g = io.open(dst .. "/ours.bin", "rb")
		local got = g and g:read("a") or ""

		if g then
			g:close()
		end
		if not ok(#got == SIZE,
		    ("%s: rz wrote %d bytes"):format(what, #got)) then
			diag("expected " .. SIZE)
		end
		ok(got == payload, what .. ": and they are the bytes we sent")
	else
		diag(tostring(err))
		ok(false, what .. ": rz wrote the file")
		ok(false, what .. ": and they are the bytes we sent")
	end
end

fromsz("escctl", "-b -e", {})
torz("plain", { escctl = false })
fromsz("crc16", "-b", { escctl = false, crc32 = false })

os.execute("rm -rf '" .. tmp .. "'")
os.exit(failed > 0 and 1 or 0)
