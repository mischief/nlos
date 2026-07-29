"""per-arch qemu invocation for the host-driven tests.

the shell half of this table is scripts/arch.sh; keep them in step.
guest arch is always host arch -- the build detects the host -- so kvm
applies whenever /dev/kvm is usable.
"""

import os
import platform

ARCH = platform.machine()

if ARCH == "x86_64":
    QEMU = "qemu-system-x86_64"
    FW_CODE = os.environ.get("OVMF_CODE", "/usr/share/edk2-ovmf/OVMF_CODE.fd")
    FW_VARS = os.environ.get("OVMF_VARS", "/usr/share/edk2-ovmf/OVMF_VARS.fd")
elif ARCH == "aarch64":
    QEMU = "qemu-system-aarch64"
    FW_CODE = os.environ.get("OVMF_CODE", "/usr/share/AAVMF/AAVMF_CODE.fd")
    FW_VARS = os.environ.get("OVMF_VARS", "/usr/share/AAVMF/AAVMF_VARS.fd")
else:
    raise SystemExit(f"unsupported host arch {ARCH}")

_KVM = os.access("/dev/kvm", os.R_OK | os.W_OK)


def machine():
    if ARCH == "x86_64":
        return ["-enable-kvm", "-cpu", "max"] if _KVM else ["-cpu", "max"]
    if _KVM:
        return ["-machine", "virt,gic-version=max,accel=kvm", "-cpu", "host"]
    return ["-machine", "virt", "-cpu", "max"]


def disk(img):
    if ARCH == "x86_64":
        return ["-drive", f"format=raw,file={img}"]
    return ["-drive", f"if=virtio,format=raw,file={img}"]


def wire(path=None):
    """the 9p wire: com2 on x86_64, a pci-serial card on aarch64.
    path=None attaches it to nothing.
    """
    if ARCH == "x86_64":
        return ["-serial", "null" if path is None else
                f"unix:{path},server,nowait"]
    spec = "null,id=wire" if path is None else \
        f"socket,id=wire,path={path},server=on,wait=off"
    return ["-chardev", spec, "-device", "pci-serial,chardev=wire"]
