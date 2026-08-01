-- qemuarch.lua: per-arch qemu invocation for the host-driven tests.
--
-- the shell/lua half of this table is scripts/arch.lua; keep them in
-- step. meson sets LUAOS_ARCH from the arch it built for, which is
-- the only correct answer under a cross build; uname is the fallback
-- for driving a test by hand against a native build.
--
-- unlike scripts/arch.lua (which builds os.execute shell strings),
-- everything here returns argv TABLES: hostutil.spawn() is a real
-- execvp, no shell involved, so there is nothing to quote.

local hostutil_path = os.getenv("HOSTUTIL_SO") or
    error("HOSTUTIL_SO not set (meson sets this; see meson.build)")
local hostutil = assert(package.loadlib(hostutil_path, "luaopen_hostutil"))()

local M = {}

local function uname_m()
	local f = assert(io.popen("uname -m"))
	local out = f:read("l")
	f:close()
	return out
end

local BUILD = uname_m()
local ARCH = os.getenv("LUAOS_ARCH") or BUILD

M.ARCH = ARCH

local function readable(path)
	local f = io.open(path, "rb")
	if f then
		f:close()
		return true
	end
	return false
end

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

if ARCH == "x86_64" then
	M.QEMU = "qemu-system-x86_64"
	M.FW_CODE = envor("OVMF_CODE", "/usr/share/edk2-ovmf/OVMF_CODE.fd")
	M.FW_VARS = envor("OVMF_VARS", "/usr/share/edk2-ovmf/OVMF_VARS.fd")
elseif ARCH == "aarch64" then
	M.QEMU = "qemu-system-aarch64"
	M.FW_CODE = os.getenv("OVMF_CODE") or
	    pick("/usr/share/AAVMF/AAVMF_CODE.fd",
	        "/usr/share/qemu/edk2-aarch64-code.fd")
	M.FW_VARS = os.getenv("OVMF_VARS") or
	    pick("/usr/share/AAVMF/AAVMF_VARS.fd",
	        "/usr/share/qemu/edk2-arm-vars.fd")
elseif ARCH == "riscv64" then
	M.QEMU = "qemu-system-riscv64"
	M.FW_CODE = envor("OVMF_CODE", "/usr/share/qemu/edk2-riscv-code.fd")
	M.FW_VARS = envor("OVMF_VARS", "/usr/share/qemu/edk2-riscv-vars.fd")
else
	error("unsupported arch " .. ARCH)
end

-- kvm only ever applies when the guest arch is the host arch, which
-- under a cross build it is not.
local function rw(path)
	local f = io.open(path, "r+b")
	if f then
		f:close()
		return true
	end
	return false
end

local KVM = (ARCH == BUILD) and rw("/dev/kvm")

-- the launcher, pinned to one host cpu when kvm is in play.
--
-- an unpinned vcpu thread that migrates between host cores can wedge
-- OVMF in boot device selection, spinning until the timeout with the
-- serial log stopping before "BdsDxe: loading" -- see the long note in
-- scripts/boottest.lua. it is kvm-specific, so tcg (every cross build)
-- needs nothing.
--
-- this exists separately from that fix because the host-driven tests
-- launch qemu themselves rather than through boottest.lua, and so did
-- not inherit it. that gap is exactly how 9p-protocol kept failing
-- under a full-parallel run after the boot tests had stopped.
function M.qemu()
	if not KVM then
		return { M.QEMU }
	end
	local nproc = tonumber(io.popen("nproc"):read("l")) or 1
	local pid = hostutil.getpid()

	return { "taskset", "-c", tostring(pid % nproc), M.QEMU }
end

function M.machine()
	if ARCH == "x86_64" then
		if KVM then
			return { "-enable-kvm", "-cpu", "max" }
		end
		return { "-cpu", "max" }
	end
	if ARCH == "riscv64" then
		return { "-machine", "virt", "-cpu", "rv64" }
	end
	if KVM then
		return { "-machine", "virt,gic-version=max,accel=kvm", "-cpu", "host" }
	end
	return { "-machine", "virt", "-cpu", "max" }
end

function M.disk(img)
	if ARCH == "x86_64" then
		return { "-drive", "format=raw,file=" .. img }
	end
	return { "-drive", "if=virtio,format=raw,file=" .. img }
end

-- the 9p wire: com2 on x86_64, a pci-serial card on the virt
-- machines. path=nil attaches it to nothing.
function M.wire(path)
	if ARCH == "x86_64" then
		if path == nil then
			return { "-serial", "null" }
		end
		return { "-serial", "unix:" .. path .. ",server,nowait" }
	end
	local spec = path == nil and "null,id=wire" or
	    ("socket,id=wire,path=" .. path .. ",server=on,wait=off")
	return { "-chardev", spec, "-device", "pci-serial,chardev=wire" }
end

M.hostutil = hostutil

return M
