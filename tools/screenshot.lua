#!/usr/bin/env lua5.4
-- screenshot.lua IMG PAYLOAD [OUT.ppm] -- boot the image with a payload
-- that draws something, and capture what the screen actually looks like.
--
-- this exists because the framebuffer is the one part of this system
-- whose output cannot be read off a serial line. test/boot/test_fb.lua
-- proves the pixels are what we asked for by reading them back through
-- the same firmware that wrote them, which is a real test and still not
-- the same claim as "a person looking at the screen would see this" --
-- a mode with the wrong stride, or a Blt that lands in an off-screen
-- page, passes readback and shows nothing.
--
-- ---- how the timing works ----
--
-- the obvious version (boot, sleep, screendump) races: sleep too little
-- and you capture the firmware logo, too much and every run pays for
-- the worst case. so the guest says when it is done -- it prints a
-- marker on com1 after its last draw and then sits there -- and this
-- polls the serial log for that marker before capturing. the guest must
-- NOT power off: qemu exiting takes the framebuffer with it, and there
-- is nothing left to dump.
--
-- HMP over -monitor stdio rather than QMP, because QMP needs a socket
-- client and a json encoder to say one word, and this needs neither.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. package.path
local arch = require("arch")
local q = arch.quote

local img, payload, out = arg[1], arg[2], arg[3] or "screenshot.ppm"

if not img or not payload then
	io.stderr:write("usage: screenshot.lua IMG PAYLOAD [OUT.ppm]\n")
	os.exit(1)
end

-- the guest prints this and stops. keep it in step with
-- test/boot/fbdraw.lua, which is the payload this was written for.
local MARKER = os.getenv("MARKER") or "SCREENSHOT READY"
local TIMEOUT = tonumber(os.getenv("TIMEOUT") or "60")

local function popen_line(cmd)
	local f = io.popen(cmd)
	local line = f and f:read("l")

	if f then
		f:close()
	end
	return line
end

local tmp = assert(popen_line("mktemp -d"), "mktemp -d failed")
local serial = tmp .. "/serial.log"

arch.copyvars(tmp .. "/vars.fd")

-- no -display none: the display device has to exist for there to be
-- anything to dump. "none" here is the *host window*, not the guest's
-- video card -- qemu still models the card and screendump reads it.
local cmd = table.concat({
	arch.QEMU, arch.MACHINE, "-display none", "-net none",
	arch.VIDEO, arch.RNG,
	"-no-reboot -snapshot",
	"-serial file:" .. q(serial),
	arch.wire_args("null"),
	"-fw_cfg name=opt/org.luaos.test,file=" .. q(payload),
	"-drive if=pflash,format=raw,readonly=on,file=" .. q(arch.FW_CODE),
	"-drive if=pflash,format=raw,file=" .. q(tmp .. "/vars.fd"),
	"-drive " .. arch.BLK .. ",file=" .. q(img),
	"-monitor stdio",
	-- the monitor echoes every character we type back at its own
	-- stdout, so without this the transcript of one screendump command
	-- is several kilobytes of readline escape sequences. we only ever
	-- write to it; nothing reads its replies.
	">/dev/null 2>&1",
}, " ")

local mon = assert(io.popen(cmd, "w"), "cannot start qemu")

-- unbuffered, so a monitor command is not still sitting in a pipe
-- buffer while we wait for its effect.
mon:setvbuf("no")

local function readfile(path)
	local f = io.open(path, "rb")

	if not f then
		return ""
	end
	local d = f:read("a")

	f:close()
	return d
end

-- poll rather than block: there is no select here, and the guest's
-- serial output is a file the host can simply re-read. 100ms is well
-- under the cost of a boot and well over the cost of a stat.
local deadline = os.time() + TIMEOUT
local ready = false

while os.time() < deadline do
	if readfile(serial):find(MARKER, 1, true) then
		ready = true
		break
	end
	os.execute("sleep 0.1")
end

if not ready then
	io.stderr:write("guest never printed " .. q(MARKER) ..
	    "; serial log follows\n")
	io.stderr:write(readfile(serial))
	mon:write("quit\n")
	mon:close()
	os.execute("rm -rf " .. q(tmp))
	os.exit(1)
end

-- screendump writes a ppm. it is synchronous in the monitor, but the
-- monitor is a pipe: quitting immediately after can kill qemu before it
-- has finished writing. asking for the file size back is the cheap
-- handshake -- "info version" would do as well; anything that forces
-- the monitor to finish the previous command does.
mon:write("screendump " .. out .. "\n")
mon:write("info version\n")
os.execute("sleep 0.3")
mon:write("quit\n")
mon:close()

os.execute("rm -rf " .. q(tmp))

local ppm = readfile(out)

if #ppm == 0 then
	io.stderr:write("screendump produced nothing\n")
	os.exit(1)
end

-- a png if the host can make one, since a ppm is awkward to look at,
-- but never a failure if it cannot: the ppm is the artifact and the
-- conversion is a convenience.
local png = out:gsub("%.ppm$", "") .. ".png"

for _, conv in ipairs({ "magick", "convert" }) do
	if os.execute("command -v " .. conv .. " >/dev/null 2>&1") then
		if os.execute(conv .. " " .. q(out) .. " " .. q(png)) then
			print(png)
			os.exit(0)
		end
		break
	end
end

print(out)
