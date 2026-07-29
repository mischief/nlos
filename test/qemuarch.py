"""per-arch qemu invocation for the host-driven tests.

the shell half of this table is scripts/arch.sh; keep them in step.
meson sets LUAOS_ARCH from the arch it built for, which is the only
correct answer under a cross build; uname is the fallback for driving a
test by hand against a native build.
"""

import os
import platform

BUILD = platform.machine()
ARCH = os.environ.get("LUAOS_ARCH", BUILD)

def _pick(*paths):
    """first readable path wins -- see the same helper in scripts/arch.sh.

    falls back to the first candidate when none exist, so the error names
    something real.
    """
    for p in paths:
        if os.access(p, os.R_OK):
            return p
    return paths[0]


if ARCH == "x86_64":
    QEMU = "qemu-system-x86_64"
    FW_CODE = os.environ.get("OVMF_CODE", "/usr/share/edk2-ovmf/OVMF_CODE.fd")
    FW_VARS = os.environ.get("OVMF_VARS", "/usr/share/edk2-ovmf/OVMF_VARS.fd")
elif ARCH == "aarch64":
    QEMU = "qemu-system-aarch64"
    # AAVMF is debian and ubuntu's name for it; gentoo and arch ship
    # qemu's own blobs, where the aarch64 varstore is edk2-arm-vars.fd.
    FW_CODE = os.environ.get("OVMF_CODE", _pick(
        "/usr/share/AAVMF/AAVMF_CODE.fd",
        "/usr/share/qemu/edk2-aarch64-code.fd"))
    FW_VARS = os.environ.get("OVMF_VARS", _pick(
        "/usr/share/AAVMF/AAVMF_VARS.fd",
        "/usr/share/qemu/edk2-arm-vars.fd"))
elif ARCH == "riscv64":
    QEMU = "qemu-system-riscv64"
    # qemu's own firmware blobs; edk2's OvmfPkg/RiscVVirt has no
    # separate distro package the way OVMF and AAVMF each do.
    FW_CODE = os.environ.get("OVMF_CODE",
                             "/usr/share/qemu/edk2-riscv-code.fd")
    FW_VARS = os.environ.get("OVMF_VARS",
                             "/usr/share/qemu/edk2-riscv-vars.fd")
else:
    raise SystemExit(f"unsupported arch {ARCH}")

# kvm only ever applies when the guest arch is the host arch, which
# under a cross build it is not.
_KVM = ARCH == BUILD and os.access("/dev/kvm", os.R_OK | os.W_OK)


def qemu():
    """the launcher, pinned to one host cpu when kvm is in play.

    an unpinned vcpu thread that migrates between host cores can wedge
    OVMF in boot device selection, spinning until the timeout with the
    serial log stopping before "BdsDxe: loading" -- see the long note in
    scripts/arch.sh's caller, scripts/boottest.sh. it is kvm-specific, so
    tcg (which is every cross build) needs nothing.

    this exists separately from that shell fix because the host-driven
    tests launch qemu themselves rather than through boottest.sh, and so
    did not inherit it. that gap is exactly how 9p-protocol kept failing
    under a full-parallel run after the boot tests had stopped.
    """
    if not _KVM:
        return [QEMU]
    return ["taskset", "-c", str(os.getpid() % (os.cpu_count() or 1)), QEMU]


def machine():
    if ARCH == "x86_64":
        return ["-enable-kvm", "-cpu", "max"] if _KVM else ["-cpu", "max"]
    if ARCH == "riscv64":
        return ["-machine", "virt", "-cpu", "rv64"]
    if _KVM:
        return ["-machine", "virt,gic-version=max,accel=kvm", "-cpu", "host"]
    return ["-machine", "virt", "-cpu", "max"]


def disk(img):
    if ARCH == "x86_64":
        return ["-drive", f"format=raw,file={img}"]
    return ["-drive", f"if=virtio,format=raw,file={img}"]


def wire(path=None):
    """the 9p wire: com2 on x86_64, a pci-serial card on the virt
    machines.
    path=None attaches it to nothing.
    """
    if ARCH == "x86_64":
        return ["-serial", "null" if path is None else
                f"unix:{path},server,nowait"]
    spec = "null,id=wire" if path is None else \
        f"socket,id=wire,path={path},server=on,wait=off"
    return ["-chardev", spec, "-device", "pci-serial,chardev=wire"]
