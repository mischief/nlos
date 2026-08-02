#!/usr/bin/env lua5.4
-- smiley.lua IMG [PAYLOAD] -- boot the image with a drawing payload and
-- open a real qemu window to look at it in.
--
-- the difference from scripts/screenshot.lua is only the display: that
-- one runs headless and captures a file, this one puts a window on your
-- desktop. everything else about the boot is the same.
--
-- serial goes to stdio, so the guest's own log still lands in the
-- terminal you started this from -- which is where "no framebuffer on
-- this machine" would appear if the display device were missing.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. package.path
local arch = require("arch")
local q = arch.quote

local img = arg[1]
local payload = arg[2] or (scriptdir .. "/../test/boot/fbsmiley.lua")

if not img then
	io.stderr:write("usage: smiley.lua IMG [PAYLOAD]\n")
	os.exit(1)
end

-- gtk first, sdl second, and say something useful rather than letting
-- qemu fail obscurely if this is a machine with no desktop at all --
-- over ssh with no X or wayland, the screenshot target is what you
-- want instead.
local function have_display(kind)
	return os.execute(arch.QEMU .. " -display " .. kind ..
	    " -version >/dev/null 2>&1")
end

local display = os.getenv("DISPLAY_BACKEND")

if not display then
	if os.getenv("WAYLAND_DISPLAY") or os.getenv("DISPLAY") then
		display = have_display("gtk") and "gtk" or "sdl"
	else
		io.stderr:write(
		    "no DISPLAY or WAYLAND_DISPLAY: there is no desktop to " ..
		    "open a window on.\n" ..
		    "use `ninja screenshot` for a png instead, or set " ..
		    "DISPLAY_BACKEND to force one.\n")
		os.exit(1)
	end
end

if not io.open("OVMF_VARS.fd", "rb") then
	os.execute("cp " .. q(arch.FW_VARS) .. " OVMF_VARS.fd")
end

local cmd = table.concat({
	arch.QEMU, arch.MACHINE, "-display " .. display,
	"-net none", arch.VIDEO, arch.RNG,
	"-no-reboot -snapshot",
	"-serial mon:stdio",
	arch.wire_args("null"),
	"-fw_cfg name=opt/org.luaos.test,file=" .. q(payload),
	"-drive if=pflash,format=raw,readonly=on,file=" .. q(arch.FW_CODE),
	"-drive if=pflash,format=raw,file=OVMF_VARS.fd",
	"-drive " .. arch.BLK .. ",file=" .. q(img),
}, " ")

os.exit(os.execute(cmd) and 0 or 1)
