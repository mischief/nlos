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

if ARCH == "x86_64":
    QEMU = "qemu-system-x86_64"
    FW_CODE = os.environ.get("OVMF_CODE", "/usr/share/edk2-ovmf/OVMF_CODE.fd")
    FW_VARS = os.environ.get("OVMF_VARS", "/usr/share/edk2-ovmf/OVMF_VARS.fd")
elif ARCH == "aarch64":
    QEMU = "qemu-system-aarch64"
    FW_CODE = os.environ.get("OVMF_CODE", "/usr/share/AAVMF/AAVMF_CODE.fd")
    FW_VARS = os.environ.get("OVMF_VARS", "/usr/share/AAVMF/AAVMF_VARS.fd")
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
