-- arch.lua: require()'d, not sourced -- everything that boots the
-- image needs the same per-arch qemu, firmware and device set, and
-- there are several callers. test/qemuarch.lua is the same table for
-- the host-driven tests.
--
-- returns {QEMU, MACHINE, VIDEO, FW_CODE, FW_VARS, NIC, BLK,
-- wire_args(kind, path)} -- wire_args is how the 9p wire gets attached.

local M = {}

-- meson sets LUAOS_ARCH from the arch it built for, which is the only
-- correct answer under a cross build. uname is the fallback for
-- running these scripts by hand against a native build.
local function uname_m()
	local f = assert(io.popen("uname -m"))
	local out = f:read("l")
	f:close()
	return out
end

local ARCH = os.getenv("LUAOS_ARCH") or uname_m()

M.ARCH = ARCH

-- true if path exists and is readable.
local function readable(path)
	local f = io.open(path, "rb")
	if f then
		f:close()
		return true
	end
	return false
end

-- true if path exists and is both readable and writable (same test
-- the shell version made of /dev/kvm).
local function rw(path)
	local f = io.open(path, "r+b")
	if f then
		f:close()
		return true
	end
	return false
end

-- first readable path wins, so one table serves distros that spell
-- the firmware differently. falls back to naming the first candidate
-- when none exist, so the error says something real rather than "".
local function pick(...)
	local candidates = { ... }
	for _, p in ipairs(candidates) do
		if readable(p) then
			return p
		end
	end
	return candidates[1]
end

local function envor(name, default)
	return os.getenv(name) or default
end

-- shell-quote a single argument for os.execute, which always goes
-- through /bin/sh -c: every path built into a command line (an image
-- path, a firmware blob, anything from an env var or a meson build
-- dir) goes through this rather than being trusted to contain no
-- spaces or shell metacharacters.
function M.quote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

if ARCH == "x86_64" then
	M.QEMU = "qemu-system-x86_64"
	M.MACHINE = "-cpu max"
	M.FW_CODE = envor("OVMF_CODE", "/usr/share/edk2-ovmf/OVMF_CODE.fd")
	M.FW_VARS = envor("OVMF_VARS", "/usr/share/edk2-ovmf/OVMF_VARS.fd")
	M.NIC = "virtio-net-pci"
	M.BLK = "format=raw"
	M.VIDEO = ""	-- qemu adds a vga to a pc by default
elseif ARCH == "aarch64" then
	M.QEMU = "qemu-system-aarch64"
	-- virt has no legacy anything: the disk has to be virtio, and
	-- the wire has to be a pci card because the one pl011 on the
	-- machine is already the firmware console.
	M.MACHINE = "-machine virt -cpu max"
	-- AAVMF is debian and ubuntu's name for it. gentoo and arch ship
	-- qemu's own blobs instead, where the aarch64 varstore is spelled
	-- edk2-arm-vars.fd -- arm and aarch64 differ in the code image,
	-- not in a blank 64MiB varstore.
	M.FW_CODE = os.getenv("OVMF_CODE") or
	    pick("/usr/share/AAVMF/AAVMF_CODE.fd",
	        "/usr/share/qemu/edk2-aarch64-code.fd")
	M.FW_VARS = os.getenv("OVMF_VARS") or
	    pick("/usr/share/AAVMF/AAVMF_VARS.fd",
	        "/usr/share/qemu/edk2-arm-vars.fd")
	M.NIC = "virtio-net-pci"
	M.BLK = "if=virtio,format=raw"
	-- virt has no display at all unless one is asked for, and with
	-- none the firmware publishes no GraphicsOutput -- which
	-- test_efiprobe checks for. ramfb is the cheapest thing that
	-- makes the guest see what a pc sees by default.
	M.VIDEO = "-device ramfb"
elseif ARCH == "riscv64" then
	M.QEMU = "qemu-system-riscv64"
	-- same shape as arm virt -- virtio disk, pci-serial wire -- and
	-- for the same reason: the machine's one ns16550a is already the
	-- firmware console. -cpu rv64 is rv64gc, which is what we build.
	M.MACHINE = "-machine virt -cpu rv64"
	-- from qemu's own firmware blobs (edk2's OvmfPkg/RiscVVirt).
	-- there is no separate distro package the way OVMF and AAVMF
	-- each have one.
	M.FW_CODE = envor("OVMF_CODE", "/usr/share/qemu/edk2-riscv-code.fd")
	M.FW_VARS = envor("OVMF_VARS", "/usr/share/qemu/edk2-riscv-vars.fd")
	M.NIC = "virtio-net-pci"
	M.BLK = "if=virtio,format=raw"
	M.VIDEO = "-device ramfb"
else
	io.stderr:write("unsupported arch " .. ARCH .. "\n")
	os.exit(1)
end

-- every guest gets an entropy source, on every arch. edk2's own
-- networking wants one, so this is not only for the guest's benefit --
-- a machine without it changes how the firmware behaves before our
-- binary is even loaded. All three efi machines are pci; microvm has
-- its own launchers and uses the virtio-mmio spelling instead.
M.RNG = "-device virtio-rng-pci"

-- kvm only ever applies when the guest arch is the host arch, which
-- under a cross build it is not.
if ARCH == uname_m() and rw("/dev/kvm") then
	if ARCH == "x86_64" then
		M.MACHINE = "-enable-kvm -cpu max"
	elseif ARCH == "aarch64" then
		M.MACHINE = "-machine virt,gic-version=max,accel=kvm -cpu host"
	end
end

-- the -display argument for a run that should open a WINDOW, or nil
-- plus a reason when there is nowhere to open one.
--
-- the framebuffer is the only output here a terminal cannot carry, so
-- every launcher that wants to show it needs this same choice made the
-- same way; it lives here for the reason everything else in this file
-- does. `want` forces a backend (LUAOS_DISPLAY does the same from the
-- environment) and is checked against qemu rather than assumed, since a
-- qemu built without gtk fails obscurely otherwise.
function M.display(want)
	want = want or os.getenv("LUAOS_DISPLAY")

	local function usable(kind)
		return os.execute(M.QEMU .. " -display " .. kind ..
		    " -version >/dev/null 2>&1")
	end

	-- no desktop at all is the common headless/ssh case and deserves a
	-- sentence rather than qemu's "gtk initialization failed": the
	-- screenshot target is what that machine wants. checked even when a
	-- backend was named, because naming one does not conjure a display
	-- -- and note that `usable` cannot catch this, since qemu accepts
	-- `-display gtk` at the command line and only fails when it tries
	-- to open the window.
	--
	-- backends that need no desktop are exempt: asking for `none` is a
	-- reasonable thing to do headlessly, and refusing it would be
	-- wrong.
	local headless = { none = true, curses = true, ["egl-headless"] = true }

	if not headless[want] and not os.getenv("DISPLAY") and
	    not os.getenv("WAYLAND_DISPLAY") then
		return nil, "no DISPLAY or WAYLAND_DISPLAY: nowhere to open " ..
		    "a window (try the screenshot target, or set LUAOS_DISPLAY)"
	end

	if want then
		if not usable(want) then
			return nil, M.QEMU .. " has no " .. want .. " display"
		end
		return "-display " .. want
	end

	for _, kind in ipairs({ "gtk", "sdl" }) do
		if usable(kind) then
			return "-display " .. kind
		end
	end
	return nil, M.QEMU .. " has neither a gtk nor an sdl display"
end

-- wire_args("null") | wire_args("socket", path)
-- the second serial port, which carries 9p. on x86_64 the machine
-- already has com2 and it is simply the second -serial; on the virt
-- machines there is no second uart, so it is a pci-serial with a
-- named chardev.
function M.wire_args(kind, path)
	if kind == "null" then
		if ARCH == "x86_64" then
			return "-serial null"
		end
		return "-chardev null,id=wire -device pci-serial,chardev=wire"
	end
	if ARCH == "x86_64" then
		return "-serial unix:" .. path .. ",server,nowait"
	end
	return "-chardev socket,id=wire,path=" .. path ..
	    ",server=on,wait=off -device pci-serial,chardev=wire"
end

return M
